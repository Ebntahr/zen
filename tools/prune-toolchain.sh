#!/bin/sh
# Prepare a slim riscv64 Zig toolchain for the Zen OS image.
#
#   tools/prune-toolchain.sh <out-dir> [zig-version]
#
# Downloads the official riscv64 Linux build of Zig from PyPI (the `ziglang`
# wheel), keeps only what `cc`/`c++` need to build riscv64-linux-musl
# programs (musl, libc++, libunwind, compiler-rt, clang headers, std) and
# writes the result to <out-dir>. Then build the image with:
#
#   zig build image -Dtoolchain=<out-dir> -Ddisk-size=2048
set -e
out=${1:?usage: prune-toolchain.sh <out-dir> [version]}
version=${2:-0.15.2}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pip download "ziglang==$version" --no-deps --only-binary=:all: \
    --platform manylinux_2_31_riscv64 -d "$work" >/dev/null
python3 -m zipfile -e "$work"/ziglang-*.whl "$work/x"
src="$work/x/ziglang"

rm -rf "$out"
mkdir -p "$out/lib/libc/include"
cp "$src/zig" "$out/zig"
chmod 755 "$out/zig"
cp "$src/LICENSE" "$out/LICENSE"
# Everything except per-platform libc trees and the thread sanitizer.
for entry in "$src"/lib/*; do
    name=$(basename "$entry")
    case "$name" in
        libc|libtsan|docs) ;;
        *) cp -r "$entry" "$out/lib/$name" ;;
    esac
done
mkdir -p "$out/lib/libc"
for d in "$src"/lib/libc/*; do
    name=$(basename "$d")
    case "$name" in
        include|glibc|mingw|darwin|wasi|freebsd|netbsd) ;;
        *) cp -r "$d" "$out/lib/libc/$name" ;;
    esac
done
# Header sets used by riscv64-linux-musl.
for d in generic-musl riscv64-linux-musl riscv-linux-any any-linux-any; do
    cp -r "$src/lib/libc/include/$d" "$out/lib/libc/include/$d"
done
du -sh "$out"
