# Runs the suite and the benchmark on Linux, so the epoll backend is exercised
# on a real kernel and dkv is measured against redis under one set of limits.
#
#   zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
#   zig test src/main.zig -target aarch64-linux-musl -OReleaseSafe \
#       --test-no-exec -femit-bin=zig-out/bin/dkv-test
#   docker build -f docker/Dockerfile -t dkv-linux .
#   docker run --rm dkv-linux
FROM alpine:3.20

RUN apk add --no-cache redis strace

COPY zig-out/bin/dkv /usr/local/bin/dkv
COPY zig-out/bin/dkv-test /usr/local/bin/dkv-test
COPY docker/check.sh /check.sh

WORKDIR /work
CMD ["sh", "/check.sh"]
