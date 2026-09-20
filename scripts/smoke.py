#!/usr/bin/env python3
"""Binary-level checks for dkv.

`zig build test` covers the protocol, framing, backpressure, connection limits
and restart-by-reopen in process. This script covers only what those cannot
reach: the shipped binary, its command line, a real client, and whether an
acknowledged write survives the process being killed outright.

Usage:
    zig build && python3 scripts/smoke.py [path/to/dkv]
"""

import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

HOST = "127.0.0.1"
PORT = 6399
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BINARY = os.path.join(REPO_ROOT, "zig-out", "bin", "dkv")

results = []


def check(label, actual, expected):
    ok = actual == expected
    results.append(ok)
    line = ("PASS " if ok else "FAIL ") + label
    if not ok:
        line += f"\n     expected {expected!r}\n     actual   {actual!r}"
    print(line, flush=True)


def listening(port, process=None, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if process is not None and process.poll() is not None:
            return False
        try:
            socket.create_connection((HOST, port), 0.1).close()
            return True
        except OSError:
            time.sleep(0.02)
    return False


def start(binary, workdir, *flags):
    log = open(os.path.join(workdir, "server.log"), "ab")
    process = subprocess.Popen(
        [binary, f"--port={PORT}", f"--dir={workdir}", *flags],
        cwd=workdir, stdout=log, stderr=log,
    )
    if not listening(PORT, process):
        raise SystemExit(f"server did not start: see {workdir}/server.log")
    return process


def stop(process, kill=False):
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGKILL if kill else signal.SIGTERM)
    process.wait(timeout=5)
    # The port is only free once the kernel has reaped the listener.
    deadline = time.time() + 5
    while time.time() < deadline and listening(PORT, timeout=0.05):
        time.sleep(0.02)


def talk(*arguments):
    """One command on a fresh connection. Returns the raw reply."""
    out = b"*" + str(len(arguments)).encode() + b"\r\n"
    for argument in arguments:
        out += b"$" + str(len(argument)).encode() + b"\r\n" + argument + b"\r\n"

    connection = socket.create_connection((HOST, PORT), timeout=5)
    try:
        connection.sendall(out)
        return connection.recv(65536)
    finally:
        connection.close()


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BINARY
    if not os.path.isfile(binary):
        raise SystemExit(f"binary not found: {binary} (run `zig build` first)")
    if listening(PORT, timeout=0.2):
        raise SystemExit(f"something is already listening on {HOST}:{PORT}")

    durable = tempfile.mkdtemp(prefix="dkv-smoke-durable-")
    buffered = tempfile.mkdtemp(prefix="dkv-smoke-buffered-")

    # The shipped binary, its flags, and a real client.
    server = start(binary, durable, "--durability=always")
    try:
        check("binary serves on the port it was given", talk(b"PING"), b"+PONG\r\n")
        check("--dir holds the log", os.path.isfile(os.path.join(durable, "dkv.wal")), True)

        talk(b"SET", b"survives", b"yes")
        check("write is acknowledged", talk(b"GET", b"survives"), b"$3\r\nyes\r\n")

        if shutil.which("redis-cli"):
            reply = subprocess.run(
                ["redis-cli", "-h", HOST, "-p", str(PORT), "GET", "survives"],
                capture_output=True, text=True, timeout=5,
            ).stdout.strip()
            check("redis-cli reads it back", reply, "yes")
        else:
            print("SKIP redis-cli not on PATH", flush=True)
    finally:
        stop(server, kill=True)

    # An acknowledged write is durable, so SIGKILL cannot take it back.
    server = start(binary, durable, "--durability=always")
    try:
        check("acknowledged write survives SIGKILL",
              talk(b"GET", b"survives"), b"$3\r\nyes\r\n")
    finally:
        stop(server)

    # The same write under --durability=never is still only in the log's
    # buffer, so killing the process does take it back. Proves the flag bites.
    server = start(binary, buffered, "--durability=never")
    try:
        talk(b"SET", b"transient", b"yes")
        check("write is acknowledged without a barrier",
              talk(b"GET", b"transient"), b"$3\r\nyes\r\n")
    finally:
        stop(server, kill=True)

    server = start(binary, buffered, "--durability=never")
    try:
        check("--durability=never loses it on SIGKILL",
              talk(b"GET", b"transient"), b"$-1\r\n")
    finally:
        stop(server)

    # A bad command line must fail before anything is served.
    refused = subprocess.run([binary, "--nope=1"], capture_output=True, text=True, timeout=5)
    check("an unknown flag refuses to start", refused.returncode != 0, True)

    passed = sum(1 for ok in results if ok)
    print(f"\n{passed}/{len(results)} passed")
    print(f"logs: {durable}  {buffered}")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
