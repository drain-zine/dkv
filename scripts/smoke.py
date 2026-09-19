#!/usr/bin/env python3
"""End-to-end smoke test for the dkv server.

Starts the built binary in a temporary directory (so its WAL never lands in the
repo), talks to it over TCP and with redis-cli, then stops it.

Usage:
    zig build && python3 scripts/smoke.py [path/to/dkv]

Exit code is 0 when every check passes. Known limits are reported separately
and do not affect the exit code.
"""

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HOST = "127.0.0.1"
PORT = 6379
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BINARY = os.path.join(REPO_ROOT, "zig-out", "bin", "dkv")

results = []
known_limits = []


def shown(value):
    if isinstance(value, bytes) and len(value) > 200:
        return value[:60] + b"...(" + str(len(value)).encode() + b" bytes)"
    return value


def check(label, actual, expected):
    ok = actual == expected
    results.append((label, ok))
    line = ("PASS " if ok else "FAIL ") + label
    if not ok:
        line += f"\n     expected {shown(expected)!r}\n     actual   {shown(actual)!r}"
    print(line, flush=True)


def known_limit(label, ok, detail):
    known_limits.append((label, ok, detail))


def port_in_use():
    try:
        socket.create_connection((HOST, PORT), timeout=0.2).close()
        return True
    except OSError:
        return False


class Server:
    def __init__(self, binary, workdir):
        self.binary = binary
        self.workdir = workdir
        self.log_path = os.path.join(workdir, "server.log")
        self.process = None

    def start(self):
        log = open(self.log_path, "ab")
        self.process = subprocess.Popen([self.binary], cwd=self.workdir, stdout=log, stderr=log)
        for _ in range(100):
            if self.process.poll() is not None:
                raise SystemExit(f"server exited early with code {self.process.returncode}")
            try:
                socket.create_connection((HOST, PORT), timeout=0.1).close()
                return
            except OSError:
                time.sleep(0.05)
        raise SystemExit("server did not start listening")

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)


def cli(*arguments):
    completed = subprocess.run(
        ["redis-cli", "-h", HOST, "-p", str(PORT), *arguments],
        capture_output=True,
        text=True,
        timeout=5,
    )
    return completed.stdout.strip()


def bulk(*arguments):
    out = b"*" + str(len(arguments)).encode() + b"\r\n"
    for argument in arguments:
        out += b"$" + str(len(argument)).encode() + b"\r\n" + argument + b"\r\n"
    return out


def recv_exact(connection, size):
    received = b""
    while len(received) < size:
        data = connection.recv(65536)
        if not data:
            break
        received += data
    return received


def exchange(chunks, expected_size, pause=0.0):
    connection = socket.create_connection((HOST, PORT), timeout=5)
    for chunk in chunks:
        connection.sendall(chunk)
        if pause:
            time.sleep(pause)
    received = recv_exact(connection, expected_size)
    connection.close()
    return received


def read_until_closed(payload):
    connection = socket.create_connection((HOST, PORT), timeout=5)
    try:
        if payload:
            connection.sendall(payload)
    except (BrokenPipeError, ConnectionResetError):
        pass
    received = b""
    while True:
        try:
            data = connection.recv(65536)
        except (ConnectionResetError, socket.timeout):
            break
        if not data:
            break
        received += data
    connection.close()
    return received


def check_commands():
    check("redis-cli PING", cli("PING"), "PONG")
    check("redis-cli SET", cli("SET", "name", "tom"), "OK")
    check("redis-cli GET", cli("GET", "name"), "tom")
    check("redis-cli GET missing", cli("GET", "missing"), "")
    check("redis-cli DEL counts removed keys", cli("DEL", "name", "missing"), "1")
    check("redis-cli SET again", cli("SET", "name", "tom"), "OK")
    check("redis-cli unknown command", cli("NOPE", "x"), "ERR unknown command 'NOPE'")
    check("redis-cli arity error", cli("GET"), "ERR wrong number of arguments for 'get' command")


def check_framing():
    pipelined = bulk(b"PING") + bulk(b"SET", b"a", b"1") + bulk(b"GET", b"a")
    expected = b"+PONG\r\n+OK\r\n$1\r\n1\r\n"
    check("pipelined batch in one write", exchange([pipelined], len(expected)), expected)

    request = bulk(b"GET", b"a")
    expected = b"$1\r\n1\r\n"
    chunks = [request[i:i + 1] for i in range(len(request))]
    check("command split byte by byte", exchange(chunks, len(expected), pause=0.003), expected)

    expected = b"+PONG\r\n+OK\r\n$5\r\nworld\r\n"
    inline = b"PING\r\n\r\nSET hello world\r\nGET hello\r\n"
    check("inline commands with empty line", exchange([inline], len(expected)), expected)

    expected = b"+OK\r\n$4\r\na\r\nb\r\n"
    binary = bulk(b"SET", b"bin", b"a\r\nb") + bulk(b"GET", b"bin")
    check("binary safe value", exchange([binary], len(expected)), expected)


def check_large_values():
    value = b"v" * (1024 * 1024)
    connection = socket.create_connection((HOST, PORT), timeout=10)
    connection.sendall(bulk(b"SET", b"big", value))
    check("SET 1 MiB value", recv_exact(connection, 5), b"+OK\r\n")

    expected = b"$" + str(len(value)).encode() + b"\r\n" + value + b"\r\n"
    for round_number in range(3):
        connection.sendall(bulk(b"GET", b"big"))
        time.sleep(0.05)
        received = recv_exact(connection, len(expected))
        check(f"GET 1 MiB with slow reader, round {round_number + 1}", received, expected)

    connection.sendall(b"PING\r\n")
    check("small reply after large partial writes", recv_exact(connection, 7), b"+PONG\r\n")
    connection.close()

    connection = socket.create_connection((HOST, PORT), timeout=5)
    expected = b"+OK\r\n$" + str(len(value)).encode() + b"\r\n" + value + b"\r\n"
    connection.sendall(bulk(b"SET", b"big2", value) + bulk(b"GET", b"big2"))
    received = recv_exact(connection, len(expected))
    connection.close()
    check("SET + GET of 1 MiB pipelined in one write", received, expected)


def check_broken_clients():
    payload = b"*1\r\n+OK\r\n" + bulk(b"PING")
    check("protocol error replies then closes", read_until_closed(payload), b"-ERR Protocol error\r\n")
    check("slot reused after a protocol-error close", cli("PING"), "PONG")

    abrupt = socket.create_connection((HOST, PORT), timeout=2)
    abrupt.sendall(b"*2\r\n$3\r\nGET\r\n$5\r\nhal")
    abrupt.close()
    time.sleep(0.1)
    check("client disconnecting mid-command does not disturb the server", cli("PING"), "PONG")


def check_concurrency():
    holder = socket.create_connection((HOST, PORT), timeout=2)
    holder.sendall(b"PING\r\n")
    recv_exact(holder, 7)
    other = socket.create_connection((HOST, PORT), timeout=2)
    other.sendall(b"PING\r\n")
    try:
        immediate = recv_exact(other, 7)
    except socket.timeout:
        immediate = b"(timed out)"
    check("second client served while first stays connected", immediate, b"+PONG\r\n")
    other.close()
    holder.close()

    failures = []

    def client_worker(worker):
        try:
            connection = socket.create_connection((HOST, PORT), timeout=10)
            batch, want = b"", b""
            for i in range(50):
                key = f"w{worker}k{i}".encode()
                value = f"value-{worker}-{i}".encode()
                batch += bulk(b"SET", key, value) + bulk(b"GET", key)
                want += b"+OK\r\n$" + str(len(value)).encode() + b"\r\n" + value + b"\r\n"
            connection.sendall(batch)
            if recv_exact(connection, len(want)) != want:
                failures.append(worker)
            connection.close()
        except Exception as error:
            failures.append((worker, repr(error)))

    threads = [threading.Thread(target=client_worker, args=(worker,)) for worker in range(20)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    check("20 concurrent clients pipelining 100 commands each", failures, [])


def check_connection_limit():
    holders = []
    for _ in range(64):
        connection = socket.create_connection((HOST, PORT), timeout=5)
        connection.sendall(b"PING\r\n")
        holders.append((connection, recv_exact(connection, 7)))
    all_accepted = all(reply == b"+PONG\r\n" for _, reply in holders)
    check("64 simultaneous connections all accepted", all_accepted, True)

    rejected = read_until_closed(b"")
    check("65th connection rejected with max clients error", rejected, b"-ERR max number of clients reached\r\n")

    order = [5, 60, 0, 33, 12, 63] + [i for i in range(64) if i not in (5, 60, 0, 33, 12, 63)]
    for index in order:
        holders[index][0].close()
    time.sleep(0.2)
    check("slots freed after 64 clients disconnect in mixed order", cli("PING"), "PONG")


def check_restart(server):
    server.stop()
    server.start()
    check("SET survives restart via WAL replay", cli("GET", "name"), "tom")
    check("DEL survives restart via WAL replay", cli("GET", "missing"), "")


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BINARY
    if not os.path.isfile(binary):
        raise SystemExit(f"binary not found: {binary} (run `zig build` first)")
    if shutil.which("redis-cli") is None:
        raise SystemExit("redis-cli not found on PATH")
    if port_in_use():
        raise SystemExit(f"something is already listening on {HOST}:{PORT}")

    workdir = tempfile.mkdtemp(prefix="dkv-smoke-")
    server = Server(binary, workdir)
    try:
        server.start()
        check_commands()
        check_framing()
        check_large_values()
        check_broken_clients()
        check_concurrency()
        check_connection_limit()
        check_restart(server)
    finally:
        server.stop()

    passed = sum(1 for _, ok in results if ok)
    print(f"\n{passed}/{len(results)} passed")
    for label, ok, detail in known_limits:
        status = "now passes" if ok else "still fails"
        print(f"KNOWN LIMIT {status}: {label} ({detail})")
    print(f"server log: {server.log_path}")

    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
