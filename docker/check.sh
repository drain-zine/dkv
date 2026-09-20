#!/bin/sh
# Correctness first: a backend that fails the suite makes its numbers moot.
set -e

DKV_PORT=6399
REDIS_PORT=6400

wait_port() {
    for _ in $(seq 1 200); do
        redis-cli -p "$1" PING >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    echo "nothing listening on $1"
    return 1
}

echo "=== platform ==="
uname -srm
echo

echo "=== dkv suite on linux, epoll backend ==="
/usr/local/bin/dkv-test
echo "suite passed"
echo

echo "=== dkv, durability always ==="
mkdir -p /work/dkv
/usr/local/bin/dkv --port=$DKV_PORT --dir=/work/dkv --durability=always \
    >/work/dkv/server.log 2>&1 &
DKV_PID=$!
wait_port $DKV_PORT

printf '  plain      -c50 : '
redis-benchmark -p $DKV_PORT -t set,get -n 20000 -c 50 -d 32 -q 2>/dev/null | tr '\n' ' '
echo
printf '  pipelined  -P16 : '
redis-benchmark -p $DKV_PORT -t set,get -n 60000 -c 50 -P 16 -d 32 -q 2>/dev/null | tr '\n' ' '
echo
printf '  single     -c1  : '
redis-benchmark -p $DKV_PORT -t set -n 2000 -c 1 -d 32 -q 2>/dev/null | tr '\n' ' '
echo
kill $DKV_PID 2>/dev/null || true
wait $DKV_PID 2>/dev/null || true
echo

echo "=== redis, matched durability: appendfsync always ==="
mkdir -p /work/redis
redis-server --port $REDIS_PORT --dir /work/redis --appendonly yes \
    --appendfsync always --save '' --logfile /work/redis/redis.log &
REDIS_PID=$!
wait_port $REDIS_PORT

printf '  plain      -c50 : '
redis-benchmark -p $REDIS_PORT -t set,get -n 20000 -c 50 -d 32 -q 2>/dev/null | tr '\n' ' '
echo
printf '  pipelined  -P16 : '
redis-benchmark -p $REDIS_PORT -t set,get -n 60000 -c 50 -P 16 -d 32 -q 2>/dev/null | tr '\n' ' '
echo
printf '  single     -c1  : '
redis-benchmark -p $REDIS_PORT -t set -n 2000 -c 1 -d 32 -q 2>/dev/null | tr '\n' ' '
echo
kill $REDIS_PID 2>/dev/null || true
echo

echo "done"
