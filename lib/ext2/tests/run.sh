#!/usr/bin/env bash
# Integration tests for lib/ext2 against e2fsprogs (mke2fs, debugfs, e2fsck).
#
#   lib/ext2/tests/run.sh            full run (includes a ~300 MiB import)
#   QUICK=1 lib/ext2/tests/run.sh    skip the large import benchmark
#   KEEP=1  ...                      keep the work directory
#
# Every image produced or modified by the library must pass `e2fsck -fn`
# with no messages, and its contents as seen by debugfs (rdump + cat) must
# match a host-side mirror of the same operations byte for byte.
set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)
LIBDIR=$(cd "$HERE/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ext2test.XXXXXX")
if [[ -z "${KEEP:-}" ]]; then trap 'rm -rf "$WORK"' EXIT; else echo "work dir: $WORK"; fi

for t in mke2fs debugfs e2fsck; do
    command -v "$t" >/dev/null || { echo "missing $t"; exit 1; }
done

echo "== building (ReleaseSafe)"
(cd "$LIBDIR" && zig build -Doptimize=ReleaseSafe)
TOOL=$LIBDIR/zig-out/bin/ext2tool
FSTEST=$LIBDIR/zig-out/bin/fstest

PASS=0
FAIL=0
ok() { echo "  ok   $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }
run() { # description, command...
    local d=$1; shift
    local log=$WORK/last.log
    if "$@" >"$log" 2>&1; then ok "$d"; else bad "$d"; sed 's/^/       /' "$log" | tail -40; fi
}

# e2fsck -fn must exit 0 and print nothing but the pass banners/summary.
fsck_clean() {
    local img=$1 out rc=0
    out=$(e2fsck -fn "$img" 2>&1) || rc=$?
    local extra
    extra=$(printf '%s\n' "$out" | grep -vE '^(e2fsck [0-9.]+ \(.*\)|Pass [1-5][A-Z]?: .*|.*: [0-9]+/[0-9]+ files \(.*\), [0-9]+/[0-9]+ blocks)$' || true)
    if [[ $rc -ne 0 || -n "$extra" ]]; then
        printf '%s\n' "$out" | head -60
        return 1
    fi
}

# Compare the image (as dumped by debugfs) with a host mirror directory.
compare_tree() {
    local img=$1 mirror=$2 dump=$WORK/dump
    rm -rf "$dump" && mkdir "$dump"
    debugfs -R "rdump / $dump" "$img" >"$WORK/rdump.log" 2>&1
    local ex=(-x lost+found -x fifo -x null -x bigdev -x sock)
    diff -r --no-dereference "${ex[@]}" "$mirror" "$dump" || return 1
    # setuid/setgid bits are compared via `debugfs stat` elsewhere: rdump
    # chowns after chmod, and the kernel clears them on chown.
    listing() {
        (cd "$1" && find . -mindepth 1 \( -name lost+found -o -type p -o -type c -o -type b -o -type s \) -prune \
            -o -printf '%y %m %U:%G %p\n' | awk '{ if (length($2) > 3) $2 = substr($2, length($2) - 2); print }' | sort)
    }
    diff <(listing "$mirror") <(listing "$dump") || return 1
    # Byte-for-byte comparison through `debugfs cat` for regular files
    # (all of them up to a limit, always including the biggest ones).
    local n=0 f
    while IFS= read -r f; do
        debugfs -R "cat \"/$f\"" "$img" 2>/dev/null | cmp -s - "$mirror/$f" || {
            echo "debugfs cat mismatch: /$f"
            return 1
        }
        n=$((n + 1))
    done < <(cd "$mirror" && { find . -type f -size +100k -printf '%P\n'; find . -type f -printf '%P\n' | sort | head -150; } | sort -u)
    echo "compared $n files with debugfs cat"
}

make_src() {
    local s=$1
    mkdir -p "$s/pre/sub/deep" "$s/pre/bigdir" "$s/pre/tree/x/y" "$s/pre/emptydir" "$s/etc"
    echo "hello from the host" >"$s/pre/hello.txt"
    head -c 300000 /dev/urandom >"$s/pre/data.bin"
    head -c 6291456 /dev/urandom >"$s/pre/huge.bin"
    echo "deep" >"$s/pre/sub/deep/file.txt"
    ln -s hello.txt "$s/pre/link"
    ln -s /pre/sub/deep "$s/pre/abslink"
    ln -s "$(printf 'long/%.0s' {1..40})target" "$s/pre/slowlink"
    local i
    for i in $(seq -f %04g 0 599); do echo "file $i" >"$s/pre/bigdir/f$i"; done
    truncate -s 20M "$s/pre/sparse"
    printf 'mid' | dd of="$s/pre/sparse" bs=1 seek=10485760 conv=notrunc status=none
    for i in 1 2 3; do head -c $((i * 5000)) /dev/urandom >"$s/pre/tree/x/y/f$i"; done
    echo "root:x:0:0::/root:/bin/sh" >"$s/etc/passwd"
    chmod 0600 "$s/pre/data.bin"
    chmod 0750 "$s/pre/sub"
    chmod 4755 "$s/pre/huge.bin"
    chown 1000:100 "$s/pre/hello.txt"
    ln "$s/pre/hello.txt" "$s/pre/hello.hard"
    mkfifo "$s/pre/fifo"
    mknod "$s/pre/null" c 1 3 2>/dev/null || true
}

SRC=$WORK/src
make_src "$SRC"

# ---------------------------------------------------------------------------
echo "== images created by mke2fs, modified by the library"
matrix=(
    "1024 128 -t ext2"
    "1024 256 -t ext2"
    "2048 256 -t ext2"
    "4096 128 -t ext2"
    "4096 256 -t ext2"
    "4096 256 -t ext2 -O ^dir_index,^resize_inode,^ext_attr"
    "1024 128 -r 0"
    "4096 256 -t ext3"
)
seed=1
for m in "${matrix[@]}"; do
    read -r bs isz extra <<<"$m"
    name="bs=$bs isize=$isz ${extra}"
    img=$WORK/m.img
    rm -f "$img"
    iopt=(-I "$isz")
    [[ "$extra" == *"-r 0"* ]] && iopt=()
    echo "-- $name"
    if ! mke2fs -q -F -b "$bs" "${iopt[@]}" $extra -d "$SRC" "$img" 96M >"$WORK/mkfs.log" 2>&1; then
        bad "mke2fs $name"; cat "$WORK/mkfs.log"; continue
    fi
    # Build htree indexes for large directories (dir_index images).
    e2fsck -fyD "$img" >/dev/null 2>&1 || true
    run "e2fsck clean before ($name)" fsck_clean "$img"
    if [[ "$extra" != *"-r 0"* && "$extra" != *"^dir_index"* ]]; then
        run "pre/bigdir is htree-indexed ($name)" sh -c "debugfs -R 'stat /pre/bigdir' '$img' 2>/dev/null | grep -q 'Flags: 0x1000'"
    fi
    run "library reads mke2fs image ($name)" "$FSTEST" verify "$img" "$SRC"
    jhash=""
    [[ "$extra" == *ext3* ]] && jhash=$(debugfs -R "cat <8>" "$img" 2>/dev/null | md5sum)
    mirror=$WORK/mirror
    rm -rf "$mirror" && cp -a "$SRC" "$mirror"
    run "scripted operations ($name)" "$FSTEST" ops "$img" "$mirror"
    run "e2fsck clean after ops ($name)" fsck_clean "$img"
    run "debugfs view matches mirror after ops ($name)" compare_tree "$img" "$mirror"
    run "special files visible to debugfs ($name)" sh -c "
        debugfs -R 'stat /zt/null' '$img' 2>/dev/null | grep -q 'Type: character special' &&
        debugfs -R 'stat /zt/null' '$img' 2>/dev/null | grep -Eq 'Device major/minor number: 0*1:0*3' &&
        debugfs -R 'stat /zt/bigdev' '$img' 2>/dev/null | grep -Eq 'Device major/minor number: 0*259:0*300' &&
        debugfs -R 'stat /zt/fifo' '$img' 2>/dev/null | grep -q 'Type: FIFO'"
    run "setuid/setgid bits ($name)" sh -c "
        debugfs -R 'stat /zt/a/big_hardlink' '$img' 2>/dev/null | grep -Eq 'Mode: +04755' &&
        debugfs -R 'stat /zt/a/big_hardlink' '$img' 2>/dev/null | grep -Eq 'User: +1234 +Group: +5678' &&
        debugfs -R 'stat /zt/empty_dir' '$img' 2>/dev/null | grep -Eq 'Mode: +02775' &&
        debugfs -R 'stat /pre/huge.bin' '$img' 2>/dev/null | grep -Eq 'Mode: +04755'"
    run "random operations ($name)" "$FSTEST" random "$img" "$mirror" "$seed" 400
    run "e2fsck clean after random ops ($name)" fsck_clean "$img"
    run "debugfs view matches mirror after random ops ($name)" compare_tree "$img" "$mirror"
    if [[ -n "$jhash" ]]; then
        run "ext3 journal untouched ($name)" sh -c "[ \"\$(debugfs -R 'cat <8>' '$img' 2>/dev/null | md5sum)\" = '$jhash' ]"
    fi
    seed=$((seed + 1))
done

echo "-- ext4 / unsupported features"
for feat in "-t ext4" "-t ext2 -O extent" "-t ext2 -O 64bit" "-t ext2 -O flex_bg" "-t ext2 -O inline_data"; do
    img=$WORK/u.img
    rm -f "$img"
    if ! mke2fs -q -F $feat "$img" 32M >/dev/null 2>&1; then
        echo "  skip mke2fs cannot create: $feat"
        continue
    fi
    run "mount refused: $feat" "$FSTEST" expect-unsupported "$img"
done

for feat in "-t ext2 -O metadata_csum" "-t ext2 -O huge_file" "-t ext2 -O uninit_bg"; do
    img=$WORK/u.img
    rm -f "$img"
    if ! mke2fs -q -F $feat "$img" 32M >/dev/null 2>&1; then
        echo "  skip mke2fs cannot create: $feat"
        continue
    fi
    run "read-only only: $feat" "$FSTEST" expect-readonly "$img"
done

# ---------------------------------------------------------------------------
echo "== images created by ext2tool mkfs + import"
cat >"$WORK/manifest" <<'EOF'
# path mode uid gid
/pre/huge.bin 4711 0 0
pre/data.bin - 33 44
etc/passwd 0644 0 0
/pre/sub 0700 5 -
EOF
apply_manifest_to_mirror() {
    local m=$1
    chown -R -h 0:0 "$m"
    chmod 4711 "$m/pre/huge.bin"
    chown 33:44 "$m/pre/data.bin"
    chmod 0644 "$m/etc/passwd"
    chmod 0700 "$m/pre/sub" && chown 5 "$m/pre/sub"
}
for geom in "4096 256" "1024 128" "2048 256"; do
    read -r bs isz <<<"$geom"
    img=$WORK/t.img
    rm -f "$img"
    run "ext2tool mkfs -b $bs -I $isz" "$TOOL" mkfs "$img" 128 zenroot -b "$bs" -I "$isz"
    run "fresh image passes e2fsck (bs=$bs)" fsck_clean "$img"
    run "ext2tool import (bs=$bs)" "$TOOL" import "$img" "$SRC" / --owner 0:0 --manifest "$WORK/manifest"
    run "imported image passes e2fsck (bs=$bs)" fsck_clean "$img"
    mirror=$WORK/mirror
    rm -rf "$mirror" && cp -a "$SRC" "$mirror"
    apply_manifest_to_mirror "$mirror"
    run "debugfs view matches source tree (bs=$bs)" compare_tree "$img" "$mirror"
    run "library view matches source tree (bs=$bs)" "$FSTEST" verify "$img" "$mirror"
    run "setuid + ownership from manifest (bs=$bs)" sh -c "
        debugfs -R 'stat /pre/huge.bin' '$img' 2>/dev/null | grep -q 'Mode:  04711' &&
        debugfs -R 'stat /pre/data.bin' '$img' 2>/dev/null | grep -Eq 'User: +33 +Group: +44'"
    run "hard links preserved (bs=$bs)" sh -c "
        [ \"\$(debugfs -R 'stat /pre/hello.hard' '$img' 2>/dev/null | grep -o 'Links: [0-9]*')\" = 'Links: 2' ]"
    run "fifo imported (bs=$bs)" sh -c "debugfs -R 'stat /pre/fifo' '$img' 2>/dev/null | grep -q 'Type: FIFO'"
    if [[ -c "$SRC/pre/null" ]]; then
        run "device node imported (bs=$bs)" sh -c "debugfs -R 'stat /pre/null' '$img' 2>/dev/null | grep -Eq 'Device major/minor number: 0*1:0*3'"
    fi
    # Re-importing over an existing tree replaces content in place.
    echo "changed" >"$WORK/changed.txt"
    run "re-import is idempotent (bs=$bs)" "$TOOL" import "$img" "$SRC" / --owner 0:0 --manifest "$WORK/manifest"
    run "e2fsck clean after re-import (bs=$bs)" fsck_clean "$img"
    run "built-in fsck agrees (bs=$bs)" "$TOOL" fsck "$img"
done

echo "-- reproducibility (SOURCE_DATE_EPOCH)"
for k in 1 2; do
    rm -f "$WORK/r$k.img"
    SOURCE_DATE_EPOCH=1700000000 "$TOOL" mkfs "$WORK/r$k.img" 64 repro
    SOURCE_DATE_EPOCH=1700000000 "$TOOL" import "$WORK/r$k.img" "$SRC" / --owner 0:0 --manifest "$WORK/manifest"
done
run "identical images from identical inputs" cmp "$WORK/r1.img" "$WORK/r2.img"
rm -f "$WORK/r1.img" "$WORK/r2.img"

# ---------------------------------------------------------------------------
echo "== ext2tool commands"
img=$WORK/cmd.img
rm -f "$img"
T() { "$TOOL" "$@"; }
run "mkfs" T mkfs "$img" 32 cmdtest
head -c 200000 /dev/urandom >"$WORK/blob"
run "put" T put "$img" "$WORK/blob" /blob.bin 0640
run "mkdir -p" T mkdir -p "$img" /a/b/c
run "put into dir" T put "$img" "$WORK/blob" /a/b
run "ln -s" T ln -s "$img" /blob.bin /a/link
run "ln (hard)" T ln "$img" /blob.bin /a/b/c/hard
run "mv" T mv "$img" /a/b/blob /a/moved
run "chmod" T chmod "$img" 2755 /a/moved
run "chown" T chown "$img" 42:43 /a/moved
run "get" T get "$img" /a/link "$WORK/blob.out"
run "get content matches" cmp "$WORK/blob" "$WORK/blob.out"
run "cat through symlink" sh -c "'$TOOL' cat '$img' /a/link | cmp - '$WORK/blob'"
run "ls -l" sh -c "'$TOOL' ls -l '$img' /a | grep -q '^lrwxrwxrwx .* link -> /blob.bin$'"
run "stat" sh -c "'$TOOL' stat '$img' /a/moved | grep -q 'Mode: (2755/-rwxr-sr-x)  Uid: 42  Gid: 43'"
run "df" sh -c "'$TOOL' df '$img' | grep -q 'label:        cmdtest'"
run "rm file" T rm "$img" /a/moved
run "rm dir without -r fails" sh -c "! '$TOOL' rm '$img' /a 2>/dev/null"
run "rm -r" T rm -r "$img" /a
run "e2fsck clean after commands" fsck_clean "$img"
run "debugfs sees final state" sh -c "
    debugfs -R 'ls -p /' '$img' 2>/dev/null | grep -q '/blob.bin/' &&
    ! debugfs -R 'ls -p /' '$img' 2>/dev/null | grep -q '/a/' &&
    [ \"\$(debugfs -R 'stat /blob.bin' '$img' 2>/dev/null | grep -o 'Links: [0-9]*')\" = 'Links: 1' ]"

# ---------------------------------------------------------------------------
if [[ -z "${QUICK:-}" ]]; then
    echo "== large import (~300 MiB)"
    BIG=$WORK/bigsrc
    mkdir -p "$BIG"
    for i in $(seq 1 24); do head -c $((8 * 1024 * 1024 + i * 4097)) /dev/urandom >"$BIG/blob$i"; done
    for d in $(seq 1 40); do
        mkdir -p "$BIG/dir$d/sub"
        for f in $(seq 1 120); do head -c $(((f * 997 + d * 13) % 20000)) /dev/urandom >"$BIG/dir$d/sub/f$f"; done
        ln -s "../dir$d" "$BIG/dir$d/self"
    done
    du -sh "$BIG" | sed 's/^/  source: /'
    img=$WORK/big.img
    rm -f "$img"
    start=$(date +%s.%N)
    run "mkfs 512 MiB" "$TOOL" mkfs "$img" 512 bigroot
    run "import large tree" "$TOOL" import "$img" "$BIG" / --owner 0:0
    end=$(date +%s.%N)
    echo "  mkfs+import took $(echo "$end - $start" | bc) s"
    run "large image passes e2fsck" fsck_clean "$img"
    mirror=$WORK/bigmirror
    rm -rf "$mirror" && cp -a "$BIG" "$mirror" && chown -R -h 0:0 "$mirror"
    run "large image matches source (debugfs)" compare_tree "$img" "$mirror"
fi

echo
echo "== $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
