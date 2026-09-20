#!/bin/sh
# Counts the syscalls each server makes under identical load, so the cost of
# arming is measured rather than argued about.
#
# strace is signalled through its child: killing the tracer directly races the
# report it is still writing.
set -e

DKV_PORT=6399
REDIS_PORT=6400
REQUESTS=20000

wait_port() {
    for _ in $(seq 1 200); do
        redis-cli -p "$1" PING >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    echo "nothing listening on $1"
    return 1
}

report() {
    echo "--- $1 ---"
    if [ -s "$2" ]; then
        head -18 "$2"
    else
        echo "(strace produced no report)"
    fi
    echo
}

mkdir -p /work/dkv /work/redis

echo "=== dkv: $REQUESTS SET at -c50, durability always ==="
strace -f -c -o /work/dkv.strace \
    /usr/local/bin/dkv --port=$DKV_PORT --dir=/work/dkv --durability=always \
    >/work/dkv/server.log 2>&1 &
TRACER=$!
wait_port $DKV_PORT
redis-benchmark -p $DKV_PORT -t set -n $REQUESTS -c 50 -d 32 -q 2>/dev/null \
    | tr '\r' '\n' | tail -1
killall -TERM dkv 2>/dev/null || true
wait $TRACER 2>/dev/null || true
report "dkv" /work/dkv.strace

echo "=== redis: $REQUESTS SET at -c50, appendfsync always ==="
strace -f -c -o /work/redis.strace \
    redis-server --port $REDIS_PORT --dir /work/redis --appendonly yes \
    --appendfsync always --save '' --logfile /work/redis/redis.log &
TRACER=$!
wait_port $REDIS_PORT
redis-benchmark -p $REDIS_PORT -t set -n $REQUESTS -c 50 -d 32 -q 2>/dev/null \
    | tr '\r' '\n' | tail -1
redis-cli -p $REDIS_PORT SHUTDOWN NOSAVE 2>/dev/null || true
wait $TRACER 2>/dev/null || true
report "redis" /work/redis.strace
