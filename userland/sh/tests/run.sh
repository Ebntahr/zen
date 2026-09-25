#!/bin/sh
# zensh test runner.
#
#   tests/run.sh              build zensh natively and run all tests
#   tests/run.sh -v           verbose: show diffs for failures
#   tests/run.sh -u NAME...   (re)generate expected output for cases from zensh
#   tests/run.sh --riscv      also cross-compile for riscv64-linux-none and run
#                             the script cases under qemu-riscv64 (if present)
#   tests/run.sh -k PATTERN   only run cases whose name matches PATTERN
#   ZENSH_MODE=Debug tests/run.sh   build with a different optimize mode
#                             (Debug poisons freed memory)
#
# Script cases live in tests/cases/NAME.sh with the expected combined
# stdout/stderr plus a final "[exit N]" line in tests/cases/NAME.out.
# Cases can run the shell under test as $TEST_SHELL (unquoted: it may be
# "qemu-riscv64 path"); $CASES is the cases directory.
# A case whose first line is "# compat: bash dash" is additionally run
# with those reference shells (bash in --posix mode) when they are
# installed, and their output must match the same expected file.
#
# Interactive line-editor tests are in tests/pty_test.py (python3 + pty).

set -u
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/.." && pwd)
verbose=0
update=0
riscv=0
pattern=
while [ $# -gt 0 ]; do
    case $1 in
        -v) verbose=1 ;;
        -u) update=1 ;;
        --riscv) riscv=1 ;;
        -k) shift; pattern=$1 ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
    shift
done

ZIG=${ZIG:-zig}
work=$(mktemp -d "${TMPDIR:-/tmp}/zensh-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
bin=$work/bin
mkdir -p "$bin"

MODE=${ZENSH_MODE:-ReleaseSafe}
echo "building zensh (native, $MODE)..."
if ! (cd "$bin" && "$ZIG" build-exe "$src/main.zig" -O "$MODE" --name zensh) >"$work/build.log" 2>&1; then
    cat "$work/build.log"
    echo "BUILD FAILED"
    exit 1
fi
ZENSH=$bin/zensh

if [ $riscv = 1 ]; then
    echo "building zensh (riscv64-linux-none, ReleaseSmall)..."
    if ! (cd "$bin" && "$ZIG" build-exe "$src/main.zig" -target riscv64-linux-none -O ReleaseSmall --name zensh-riscv64) >"$work/build-rv.log" 2>&1; then
        cat "$work/build-rv.log"
        echo "RISCV BUILD FAILED"
        exit 1
    fi
fi

pass=0
fail=0
skip=0
failed=

# run_case SHELL-COMMAND CASEFILE OUTFILE
run_case() {
    shell_cmd=$1 case_file=$2 out=$3
    d=$work/run.$$
    rm -rf "$d"; mkdir -p "$d/home"
    (
        cd "$d" || exit 1
        HOME=$d/home LC_ALL=C PATH=/usr/local/bin:/usr/bin:/bin PS1='$ ' TZ=UTC \
            TEST_SHELL=$shell_cmd CASES=$here/cases \
            $shell_cmd "$case_file" </dev/null >"$out" 2>&1
        echo "[exit $?]" >>"$out"
    )
    rm -rf "$d"
}

check() {
    name=$1 expected=$2 actual=$3 label=$4
    if cmp -s "$expected" "$actual"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        failed="$failed $name($label)"
        echo "FAIL: $name [$label]"
        if [ $verbose = 1 ]; then
            diff -u "$expected" "$actual" | head -40
        fi
    fi
}

for case_file in "$here"/cases/*.sh; do
    name=$(basename "$case_file" .sh)
    if [ -n "$pattern" ]; then
        case $name in *$pattern*) ;; *) continue ;; esac
    fi
    expected=$here/cases/$name.out
    actual=$work/$name.actual
    run_case "$ZENSH" "$case_file" "$actual"
    if [ $update = 1 ]; then
        cp "$actual" "$expected"
        echo "updated $name.out"
        continue
    fi
    if [ ! -f "$expected" ]; then
        echo "MISSING: $expected"
        fail=$((fail + 1))
        continue
    fi
    check "$name" "$expected" "$actual" zensh
    if [ $riscv = 1 ] && command -v qemu-riscv64 >/dev/null 2>&1; then
        # run the riscv64 build under user-mode emulation; children spawned
        # by the shell (e.g. `sh`) still run natively.
        run_case "qemu-riscv64 $bin/zensh-riscv64" "$case_file" "$actual.rv"
        check "$name" "$expected" "$actual.rv" riscv64
    fi
    compat=$(sed -n '1s/^# compat://p' "$case_file")
    for ref in $compat; do
        case $ref in
            bash) refcmd="bash --posix" ;;
            dash) refcmd="dash" ;;
            *) continue ;;
        esac
        if ! command -v "$ref" >/dev/null 2>&1; then
            skip=$((skip + 1))
            continue
        fi
        run_case "$refcmd" "$case_file" "$actual.$ref"
        check "$name" "$expected" "$actual.$ref" "$ref"
    done
done

if [ $update = 0 ] && [ -z "$pattern" ]; then
    if command -v python3 >/dev/null 2>&1; then
        echo "running interactive (pty) tests..."
        if python3 "$here/pty_test.py" "$ZENSH"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
            failed="$failed pty_test"
        fi
        if [ $riscv = 1 ] && command -v qemu-riscv64 >/dev/null 2>&1; then
            echo "running interactive (pty) tests on riscv64 (qemu)..."
            printf '#!/bin/sh\nexec qemu-riscv64 "%s" "$@"\n' "$bin/zensh-riscv64" >"$bin/zensh-rv-wrapper"
            chmod +x "$bin/zensh-rv-wrapper"
            if python3 "$here/pty_test.py" "$bin/zensh-rv-wrapper"; then
                pass=$((pass + 1))
            else
                fail=$((fail + 1))
                failed="$failed pty_test(riscv64)"
            fi
        fi
    else
        echo "python3 not found: skipping pty tests"
        skip=$((skip + 1))
    fi
fi

echo
echo "passed: $pass  failed: $fail  skipped: $skip"
if [ $fail -gt 0 ]; then
    echo "failures:$failed"
    exit 1
fi
exit 0
