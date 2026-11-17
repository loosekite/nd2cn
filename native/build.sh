#!/bin/sh
# Build nd2cn-dashd for the CMU: a static ARMv7 binary (musl libc, soft-float
# calling convention), so it depends on nothing that is installed on the car.
# glibc is not an option: a static glibc binary refuses to start on a kernel
# older than 3.2 ("FATAL: kernel too old"), and the CMU runs 3.0.35.
#
# Needs zig (https://ziglang.org/download/), used here only as a C cross
# compiler:   ZIG=/path/to/zig sh native/build.sh
# Result:     app/nd2cn-dashd   (checked in, so installing needs no compiler)
#             native/dashd-host (same source for this machine, for the tests)
set -eu
cd "$(dirname "$0")/.."
ZIG="${ZIG:-zig}"
CFLAGS="-std=c99 -Os -Wall -Wextra -Wshadow -Wconversion -Wno-sign-conversion"
# shellcheck disable=SC2086
"$ZIG" cc -target arm-linux-musleabi -mcpu=cortex_a9 $CFLAGS -static -s \
    -o app/nd2cn-dashd native/dashd.c
# shellcheck disable=SC2086
${CC:-cc} $CFLAGS -g -o native/dashd-host native/dashd.c
ls -l app/nd2cn-dashd native/dashd-host
