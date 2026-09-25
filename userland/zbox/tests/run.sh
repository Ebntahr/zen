#!/usr/bin/env bash
# zbox test suite.
#
# Builds a native zbox binary and checks many applets:
#   * against expected outputs embedded in this script, and
#   * against the host GNU tools (coreutils, grep, sed, diffutils, ...) on
#     the fixture files in tests/fixtures, where behaviour should be identical.
#
# Usage: userland/zbox/tests/run.sh [-v] [-k]
#   -v  show diffs for failures (default: first lines only)
#   -k  keep the work directory
#   ZIG=/path/to/zig to select the compiler (default: zig)
#   RISCV=1 also cross-compile the riscv64 ReleaseSmall binary
set -u

VERBOSE=0
KEEP=0
for a in "$@"; do
  case "$a" in
    -v) VERBOSE=1 ;;
    -k) KEEP=1 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
ZDIR=$(dirname "$HERE")
FIX="$HERE/fixtures"
ZIG=${ZIG:-zig}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/zbox-test.XXXXXX")
if [ "$KEEP" = 0 ]; then trap 'rm -rf "$WORK"' EXIT; else echo "work dir: $WORK"; fi

echo "== building zbox (native)"
if ! "$ZIG" build-exe "$ZDIR/main.zig" -femit-bin="$WORK/zbox" 2>"$WORK/build.log"; then
  cat "$WORK/build.log"; echo "BUILD FAILED"; exit 1
fi
if [ "${RISCV:-0}" = 1 ]; then
  echo "== building zbox (riscv64-linux-none, ReleaseSmall)"
  if ! "$ZIG" build-exe "$ZDIR/main.zig" -target riscv64-linux-none -O ReleaseSmall -femit-bin="$WORK/zbox-riscv64" 2>"$WORK/build-rv.log"; then
    cat "$WORK/build-rv.log"; echo "RISCV BUILD FAILED"; exit 1
  fi
  ls -l "$WORK/zbox-riscv64" | awk '{print "   riscv64 binary size: " $5 " bytes"}'
fi

Z="$WORK/zbox"
BIN="$WORK/bin"
mkdir -p "$BIN"
"$Z" --install "$BIN" || { echo "zbox --install failed"; exit 1; }
export LC_ALL=C TZ=UTC
unset LS_COLORS GREP_COLORS POSIXLY_CORRECT
PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

report() { # name ok expected actual
  if [ "$2" = 1 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$1")
    echo "FAIL: $1"
    if [ "$VERBOSE" = 1 ]; then
      diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | sed 's/^/    /'
    else
      diff <(printf '%s\n' "$3") <(printf '%s\n' "$4") | head -6 | sed 's/^/    /'
    fi
  fi
}

# run zbox applet via its symlink (or a plain command such as sh):
# capture stdout+stderr and exit status
zrun() {
  if [ -e "$BIN/$1" ]; then "$BIN/$1" "${@:2}" 2>&1; else "$@" 2>&1; fi
  echo "[rc=$?]"
}
want_of() { if [ -z "$1" ]; then printf '[rc=0]'; else printf '%s\n[rc=0]' "$1"; fi; }
# host tool
hrun() { local c="$1"; shift; env "$c" "$@" 2>&1; echo "[rc=$?]"; }

# expect NAME EXPECTED CMD ARGS...   (stdout+stderr+rc)
expect() {
  local name="$1" exp="$2"; shift 2
  local act; act=$(cd "$T" && zrun "$@")
  report "$name" "$([ "$act" == "$(want_of "$exp")" ] || [ "$act" == "$exp" ] || [ "$act" == "$exp[rc=0]" ] && echo 1 || echo 0)" "$exp" "$act"
}
# expect_in NAME INPUT EXPECTED CMD ARGS...
expect_in() {
  local name="$1" inp="$2" exp="$3"; shift 3
  local act; act=$(cd "$T" && printf '%s' "$inp" | zrun "$@")
  report "$name" "$([ "$act" == "$(want_of "$exp")" ] || [ "$act" == "$exp" ] || [ "$act" == "$exp[rc=0]" ] && echo 1 || echo 0)" "$exp" "$act"
}
have() { command -v "$1" >/dev/null 2>&1; }
# gnu CMD ARGS...   compare with host tool (run in fixtures dir)
gnu() {
  if ! have "$1"; then SKIP=$((SKIP + 1)); return; fi
  local exp act
  exp=$(cd "$FIX" && hrun "$@" | sed "s#^/usr/bin/##; s#^/bin/##")
  act=$(cd "$FIX" && zrun "$@")
  report "gnu: $*" "$([ "$exp" == "$act" ] && echo 1 || echo 0)" "$exp" "$act"
}
# gnu_in INPUT CMD ARGS...
gnu_in() {
  local inp="$1"; shift
  if ! have "$1"; then SKIP=$((SKIP + 1)); return; fi
  local exp act
  exp=$(cd "$FIX" && printf "$inp" | hrun "$@" | sed "s#^/usr/bin/##; s#^/bin/##")
  act=$(cd "$FIX" && printf "$inp" | zrun "$@")
  report "gnu<: $*" "$([ "$exp" == "$act" ] && echo 1 || echo 0)" "$exp" "$act"
}
# gnu_sh SNIPPET: run a shell snippet in two scratch dirs, once with host
# tools and once with zbox applets first in PATH; compare output and tree.
gnu_sh() {
  local snip="$1"
  rm -rf "$WORK/g" "$WORK/z"; mkdir -p "$WORK/g" "$WORK/z"
  local exp act
  exp=$(cd "$WORK/g" && bash -c "$snip" 2>&1; echo "[rc=$?]"; find . -mindepth 1 | sort | while read -r f; do stat -c '%n %F %a %s' "$f"; done)
  act=$(cd "$WORK/z" && PATH="$BIN:$PATH" bash -c "$snip" 2>&1; echo "[rc=$?]"; find . -mindepth 1 | sort | while read -r f; do stat -c '%n %F %a %s' "$f"; done)
  report "sh: $snip" "$([ "$exp" == "$act" ] && echo 1 || echo 0)" "$exp" "$act"
}

T="$WORK/t"
mkdir -p "$T"

echo "== dispatcher"
act=$("$Z" --list | wc -l); report "zbox --list has >100 applets" "$([ "$act" -gt 100 ] && echo 1 || echo 0)" ">100" "$act"
act=$("$Z" echo hi 2>&1); report "zbox echo" "$([ "$act" == hi ] && echo 1 || echo 0)" "hi" "$act"
act=$("$Z" /some/dir/echo hi 2>&1); report "zbox path/applet" "$([ "$act" == hi ] && echo 1 || echo 0)" "hi" "$act"
expect "zbox via symlink" "a b" echo a b
act=$("$Z" nosuchapplet 2>&1; echo "[rc=$?]"); report "unknown applet" "$([ "$act" == $'zbox: applet not found: nosuchapplet\n[rc=127]' ] && echo 1 || echo 0)" "" "$act"
for c in $("$Z" --list); do
  out=$("$BIN/$c" --help 2>&1 </dev/null); rc=$?
  if { [ -z "$out" ] && [ "$c" != test ]; } || { [ "$rc" != 0 ] && [ "$c" != false ]; }; then report "--help: $c" 0 "usage text" "rc=$rc $out"; else PASS=$((PASS + 1)); fi
done

echo "== basic output"
expect "echo -n" "ab" echo -n ab
expect "echo -e" $'a\tb\nc' echo -e 'a\tb\nc'
expect "echo -e \\c" "x" echo -e 'x\cyz'
expect "echo -E" 'a\tb' echo -E 'a\tb'
expect "echo octal" "A" echo -e '\0101'
expect "echo not option" "-x y" echo -x y
expect "true" "" true
act=$(zrun false); report "false" "$([ "$act" == "[rc=1]" ] && echo 1 || echo 0)" "[rc=1]" "$act"
expect "yes|head" $'y\ny\ny' sh -c "$BIN/yes | $BIN/head -n 3"
expect "yes words" $'a b\na b' sh -c "$BIN/yes a b | $BIN/head -n 2"
expect "basename" "c" basename /a/b/c.txt .txt
expect "basename -s" $'a\nb' basename -s .c x/a.c y/b.c
expect "basename /" "/" basename /
expect "dirname" $'/a/b\n.\n/' dirname /a/b/c file /
expect "pwd -P" "$T" pwd -P

echo "== printf"
gnu printf '%s-%d-%5.2f-%x-%o-%e-%g-%c|\n' str 42 3.14159 255 8 12345.678 0.00001234 xyz
gnu printf '%-10s|%10s|%.2s\n' ab cd efgh
gnu printf '%b\n' 'a\tb\101\0101'
gnu printf '%q\n' "it's" 'a b' ''
gnu printf '%d %d\n' 1 2 3
gnu printf '%i\n' 0x1F 010 "'A"
gnu printf '%d\n' abc 12abc
gnu printf '%*d|%-*d|\n' 5 42 4 7
gnu printf '%.3d %+d % d %05d\n' 7 7 7 -7
gnu printf '%#x %#o %X\n' 255 8 255
gnu printf '%G %E %g %g\n' 0.000001 1e10 100000 1000000
gnu printf '%.0f %.0f %.0f %.2f %.1f\n' 0.5 1.5 2.5 2.675 0.05
gnu printf 'a\cb\n'
gnu printf '%u\n' -1
gnu printf '%10.4f|%-10.2e|\n' 3.14159265 314.159
gnu printf '%5%|%s\n' x

echo "== cat head tail wc"
gnu cat -n text.txt
gnu cat -A text.txt
gnu cat -b -s text.txt
gnu cat -E -T text.txt nonl.txt
gnu cat nonexist words.txt
gnu_in 'a\n\n\n\nb\n' cat -s
gnu head -3 lines.txt
gnu head -n -9 lines.txt
gnu head -c 10 lines.txt
gnu head -c -60 lines.txt
gnu head -n 2 words.txt lines.txt
gnu head -q -n1 words.txt lines.txt
gnu tail -3 lines.txt
gnu tail -n +10 lines.txt
gnu tail -c 7 lines.txt
gnu tail -c +70 lines.txt
gnu tail -n 2 words.txt lines.txt
gnu tail -n1 nonl.txt
gnu_in 'a\nb\nc' tail -n 1
gnu wc words.txt
gnu wc -l words.txt
gnu wc text.txt words.txt
gnu wc -L text.txt
gnu wc -w -c text.txt
gnu wc -m nonl.txt
gnu wc nonexist words.txt
gnu_in 'one two\nthree\n' wc

echo "== sort uniq cut tr paste comm"
gnu sort words.txt
gnu sort -f words.txt
gnu sort -u words.txt
gnu sort -r words.txt
gnu sort -n nums.txt
gnu sort -g nums.txt
gnu sort -h nums.txt
gnu sort -rn nums.txt
gnu sort -t, -k2n table.csv
gnu sort -t, -k4,4nr -k1,1 table.csv
gnu sort -k2 spaces.txt
gnu sort -k2,2 -k1,1n spaces.txt
gnu sort -b -k2 spaces.txt
gnu sort -V versions.txt
gnu sort -t: -k3n fields.txt
gnu sort -s -k1,1 spaces.txt
gnu sort -c words.txt
gnu sort -k1.2,1.3 words.txt
gnu sort -d text.txt
gnu uniq words.txt
gnu uniq -c words.txt
gnu uniq -d words.txt
gnu uniq -u words.txt
gnu uniq -i -c words.txt
gnu uniq -D words.txt
gnu uniq -f1 spaces.txt
gnu uniq -s1 -w2 words.txt
gnu_in 'a\na\nb\na\n' uniq -c
gnu cut -d, -f1,3 table.csv
gnu cut -d: -f1,6- fields.txt
gnu cut -c1-5 text.txt
gnu cut -b2,4-6 words.txt
gnu cut -d, -f2 --complement table.csv
gnu cut -d: -s -f2 text.txt
gnu cut -d, -f1,2 --output-delimiter=' | ' table.csv
gnu cut -f2 fields.txt
gnu_in 'Hello World\n' tr a-z A-Z
gnu_in 'Hello World\n' tr '[:lower:]' '[:upper:]'
gnu_in 'Hello   World\n' tr -s ' '
gnu_in 'Hello World\n' tr -d 'lo'
gnu_in 'Hello World 123\n' tr -cd '[:digit:]\n'
gnu_in 'aabbcc\n' tr -s 'a-c' 'x-z'
gnu_in 'abc\n' tr abc x
gnu_in 'abcdef\n' tr -t abcdef xy
gnu_in 'hello\n' tr 'a-z' 'n-za-m'
gnu_in 'hello\n' tr 'a-l' '[x*3]y'
gnu_in 'x\n' tr
gnu_in 'x\n' tr -d a b
gnu paste sorted1.txt sorted2.txt
gnu paste -d, sorted1.txt sorted2.txt words.txt
gnu paste -s sorted1.txt sorted2.txt
gnu paste -s -d '+-' lines.txt
gnu comm sorted1.txt sorted2.txt
gnu comm -12 sorted1.txt sorted2.txt
gnu comm -3 sorted1.txt sorted2.txt

echo "== nl rev tac fold seq strings"
gnu nl text.txt
gnu nl -ba -nln text.txt
gnu nl -nrz -w3 -s: words.txt
gnu rev words.txt
gnu tac words.txt
gnu tac nonl.txt
gnu fold -w 20 text.txt
gnu fold -s -w 20 text.txt
gnu fold -b -w 7 words.txt
gnu seq 5
gnu seq 2 10
gnu seq 10 -3 1
gnu seq -w 8 11
gnu seq 1 0.5 3
gnu seq -s, 5
gnu seq 0.1 0.1 1
gnu seq 1e3 1e3 3e3
gnu seq -f '%03g' 3
gnu seq -w -5 5
gnu seq 0 0.000001 0.000003
gnu seq 1 0 5
gnu strings -n 3 nonl.txt
gnu strings -n 8 -t x /bin/true

echo "== grep"
gnu grep -n -C1 -e two -e six lines.txt
gnu grep -c line lines.txt
gnu grep -o -n '[aeiou]e' words.txt
gnu grep -v -n e words.txt
gnu grep -w 'the' text.txt
gnu grep -x -E 'fig|date' words.txt
gnu grep -i 'the' text.txt
gnu grep --color=always -n o words.txt
gnu grep -l e words.txt lines.txt nums.txt
gnu grep -L 1 words.txt lines.txt
gnu grep -A1 -m1 a words.txt
gnu grep -B2 fig words.txt
gnu grep -E '(p)\1' words.txt
gnu grep -F 'a.b' text.txt
gnu grep -E 'x{2,}|[[:digit:]]{3}' text.txt
gnu grep -e '(' -E words.txt
gnu grep 'a\|e' words.txt
gnu grep '^[A-Z]' words.txt
gnu grep -o '[a-z]*@[a-z.]*' text.txt
gnu grep -h e words.txt lines.txt
gnu grep -H fig words.txt
gnu grep -q fig words.txt
gnu grep -s x nonexist
gnu grep -r -n banana .
gnu grep nomatch words.txt
gnu grep -c '' nonl.txt
gnu grep -b fig words.txt

echo "== sed"
gnu_in 'x\ny\n' sed ':a;N;$!ba;s/\n/ /g'
gnu_in 'x\ny\n' sed -n 'l;l 3'
gnu_in 'hello\n' sed 's/\(l\+\)/[\U\1\E]/'
gnu_in 'abc' sed p
gnu_in 'abc\n' sed 'a  foo; p'
gnu_in 'a\nb\nc\n' sed '1!G;h;$!d'
gnu_in 'baaac\n' sed 's/a*/x/g'
gnu_in 'abc\n' sed 's/b*/x/g'
gnu_in 'hello\n' sed 's/l/L/2'
gnu_in 'abc\n' sed -n '/b/{p;p}'
gnu_in 'abc\n' sed 'y/abc/xyz/'
gnu_in '1\n2\n3\n4\n5\n' sed -n '2,+1p;4~2p'
gnu_in '1\n2\n3\n' sed '0,/1/d'
gnu_in '1\n2\n3\n' sed '2q'
gnu_in '1\n2\n3\n' sed '2Q5'
gnu_in '1\n2\n3\n4\n' sed -n '$='
gnu_in 'a b c\n' sed -E 's/(\w+) (\w+)/\2 \1/'
gnu_in 'one\ntwo\nthree\n' sed '/two/c\\\nchanged'
gnu_in 'one\ntwo\nthree\n' sed '2i\\\ninserted'
gnu_in 'one\ntwo\nthree\n' sed -n '/one/,/two/p'
gnu_in 'one\ntwo\nthree\n' sed '$!N;P;D'
gnu_in 'one\ntwo\nthree\n' sed 'n;d'
gnu_in 'aaa\n' sed 's/a/b/3'
gnu_in 'path/to/file\n' sed 's|/|\\\\|g'
gnu_in 'CamelCase\n' sed 's/.*/\L&/'
gnu_in 'a\tb\n' sed -n l
gnu_in 'a.b.c\n' sed 's/\./-/2g'
gnu_in 'hello\n' sed 'unknown'
gnu_in 'hello\n' sed 's/a/b'
gnu_in '1\n2\n3\n4\n5\n6\n' sed '2,4!d'
gnu_in '1\n2\n3\n4\n5\n6\n' sed -n '/2/,+2{=;p}'
gnu_in 'hello\n' sed -E 's/(l+)|(h)/<\1|\2>/g'
gnu sed -n '/^[a-z]/p' words.txt
gnu sed -s -n '$p' words.txt lines.txt
gnu sed '1~3d' lines.txt
gnu_sh 'printf "a\nb\n" > f; sed -i "s/a/X/" f; cat f; printf "q\n" > g; sed -i.bak "s/q/Q/" g; cat g g.bak'

echo "== file operations"
gnu_sh 'mkdir -p a/b/c && mkdir -v x y && mkdir x; mkdir -p a/b/c/d -v'
gnu_sh 'mkdir -m 700 m1; mkdir -m u=rwx,go=rx m2; mkdir -p -m 711 p1/p2; mkdir no/such'
gnu_sh 'mkdir -p a/b/c; rmdir a; rmdir -p a/b/c; rmdir nonexist'
gnu_sh 'touch f1 f2; touch -c f3; touch -d "2020-01-01 12:00" f1; touch -t 202101020304.05 f2; stat -c "%y" f1 f2; touch no/such'
gnu_sh 'echo hi > a; cp a b; cp -v a c; cp a nodir/x; cp nonexist y; cp a a'
gnu_sh 'mkdir -p d/e; echo x > d/e/f; ln -s f d/e/l; cp -r d d2; cp d d3; cp -a d d4; ls -l d4/e/l | cut -c1-10'
gnu_sh 'echo 1 > a; chmod 600 a; cp -p a b; cp a c; stat -c %a b c'
gnu_sh 'echo 1 > a; mkdir d; mv a b; mv -v b d; mv nonexist x; mv d d/sub; mkdir e; touch f; mv f e/'
gnu_sh 'touch a b; mkdir -p d/e; touch d/e/f; rm a; rm -v b; rm d; rm -r -v d; rm nonexist; rm -f nonexist'
gnu_sh 'mkdir d; rm -d d; mkdir e; touch e/f; rm -d e; rm -rf e; rm .; rm -r ..'
gnu_sh 'touch a; ln a b; ln -s a c; ln -s a c; ln -sf a c; ln -sv a d; readlink c d; ln nonexist z'
gnu_sh 'touch a b; chmod 755 a; chmod u-x,g+w a; chmod -v a=r b; chmod -c 444 b; chmod o+t a; stat -c %A a b; chmod xyz a'
gnu_sh 'mkdir -p d/e; touch d/f d/e/g; chmod -R 700 d; chmod -w d/f; chmod +x d/f; stat -c "%n %a" d d/f d/e/g'
gnu_sh 'truncate -s 100 f; stat -c %s f; truncate -s +50 f; truncate -s -20 f; truncate -s %64 f; stat -c %s f'
gnu_sh 'install -d a/b/c; echo x > f; install -m 644 f a/b/; install -D f x/y/z; install -v f g'
gnu_sh 'echo hi > a; link a b; unlink b; unlink nonexist'
gnu_sh 'mkdir -p d/e; touch d/f; ln -s d/f lf; readlink lf; readlink -f nonexist/x; realpath -m no/such/../x | sed "s#.*/##"; realpath --relative-to=d/e d/f'
gnu_sh 'touch f; ln -s f l; stat -c "%n %F %a %A %s %h %U %G" f l .; stat -L -c %F l; stat --printf "%n\t%s\n" f'
gnu_sh 'mkdir -p d/e/f; echo hello > d/x; echo world > d/e/y; (du d; du -a d; du -b d; du -d 1 d; du --apparent-size -a d) | sort; du -s d; du -c d d/e'
gnu_sh 'seq 1 2500 > big; split big; ls; split -l 1000 -d big p_; ls p_*; split -b 3000 big b_; ls b_*; split -n 3 big n_; wc -c n_*'
gnu_sh 'seq 1 100 > f; dd if=f of=g bs=10 count=3 2>/dev/null; cat g; dd if=f bs=5 skip=2 count=2 2>/dev/null; echo abc | dd conv=ucase 2>/dev/null; dd if=f of=h bs=7 status=noxfer 2>&1'
gnu_sh 'echo hi | tee a b; cat a b; echo more | tee -a a > /dev/null; cat a'

echo "== ls"
LS="$WORK/lsdir"
mkdir -p "$LS/d1" && cd "$LS" && touch a bb ccc dddd eeeee ffffff g h i j k l m n o p 'with space' && echo hello > sized && ln -s a lnk && ln -s nonexist broken && touch exe && chmod 755 exe && mkfifo pipe 2>/dev/null
touch -d '2020-01-02 03:04:05' old; for f in *; do [ -L "$f" ] || touch -h -d '2024-05-06 07:08:09' "$f"; done; touch -d '2020-01-02 03:04:05' old
cd "$HERE"
lsgnu() {
  local exp act
  exp=$(cd "$LS" && ls "$@" 2>&1; echo "[rc=$?]")
  act=$(cd "$LS" && "$BIN/ls" "$@" 2>&1; echo "[rc=$?]")
  report "ls $*" "$([ "$exp" == "$act" ] && echo 1 || echo 0)" "$exp" "$act"
}
set -f
for o in "" -a -A -l -la -lh -1 "-C -w 40" "-x -w 40" -m -F -lF -p -t -S -r -R "-d d1 a" -i -s -n -g -o "nonexist a" "-l --color=always" "--color=always -C -w 50" "-lL" "--full-time old" "-l --time-style=long-iso old" -X "-I a*" -Q "-l lnk" "lnk d1" -lS -lt -ltr; do
  # shellcheck disable=SC2086
  lsgnu $o
done
set +f

echo "== find xargs"
FD="$WORK/fd"
mkdir -p "$FD/d/e/f" "$FD/d/g" && cd "$FD" && echo hi > d/a.txt && echo hello > d/e/b.TXT && touch d/e/f/empty && ln -s a.txt d/lnk && : > d/g/.hidden && chmod 755 d/a.txt && touch -d 2000-01-01 d/old
cd "$HERE"
findgnu() {
  local exp act
  exp=$(cd "$FD" && eval "find $1" 2>&1 | sort; echo "[rc=${PIPESTATUS[0]}]")
  act=$(cd "$FD" && eval "$BIN/find $1" 2>&1 | sort; echo "[rc=${PIPESTATUS[0]}]")
  report "find $1" "$([ "$exp" == "$act" ] && echo 1 || echo 0)" "$exp" "$act"
}
for e in "d" "d -name '*.txt'" "d -iname '*.txt'" "d -type f" "d -type d" "d -type l" "d -maxdepth 1" "d -mindepth 2" \
  "d -empty" "d -size +0 -type f" "d -name e -prune -o -print" "d ! -name '*.txt' -type f" "d \\( -name a.txt -o -name b.TXT \\)" \
  "d -perm 755" "d -newer d/old -type f" "d -mtime +1000" "d -type f -exec echo X {} \\;" "d -path '*/e/*'" \
  "d -regex '.*\\.txt'" "d/e -printf '%p %f %s %d %y %m %h\\n'" "nonexist" "d -foo" "d -links 1 -type f" "d -user root -type d"; do
  findgnu "$e"
done
gnu_in 'a b  c\n' xargs
gnu_in 'a\nb\nc\n' xargs -n 2 echo X
gnu_in 'a b\nc\n' xargs -L 1 echo
gnu_in '"q u" x\\ y\n' xargs -n1
gnu_in 'a\0b c\0' xargs -0 -n1 echo
gnu_in 'x\ny\n' xargs -I{} echo 'pre-{}-post'
gnu_in '\n' xargs -r echo nope
gnu_in '1,2,3' xargs -d, -n1
gnu_in 'a\n' xargs false

echo "== test expr"
for t in "1 -eq 1" "a = b" "-f words.txt" "-d words.txt" "! -e nonexist" "abc" "" "1 -lt 2 -a 3 -gt 2" "( a = a ) -o b = c" \
  "x -eq 1" "a b" "1 -eq" "( 1" "1 = 1 = 1" "5 -ge 5 -a ! 3 -le 2" "-z ''" "words.txt -nt nonexist"; do
  # shellcheck disable=SC2086
  gnu test $t
done
gnu [ 1 = 1 ]
gnu [ 1 = 1
gnu expr 1 + 2
gnu expr 10 / 3
gnu expr 10 % 3
gnu expr 2 '*' 3 + 1
gnu expr abc : 'a\(.\)'
gnu expr abcdef : '.*'
gnu expr length hello
gnu expr substr hello 2 3
gnu expr index hello l
gnu expr 5 '>' 3
gnu expr a '<' b
gnu expr 0 '|' 5
gnu expr 0 '&' 5
gnu expr 1 / 0
gnu expr a + 1
gnu expr 3 = 3
gnu expr '(' 1 + 2 ')' '*' 3
gnu expr match abc b
gnu expr -5 + 2
gnu expr 1 +
gnu expr

echo "== checksums and dumps"
gnu md5sum words.txt lines.txt
gnu sha1sum words.txt
gnu sha256sum words.txt
gnu sha512sum nonl.txt
gnu sha256sum --tag words.txt
gnu cksum words.txt lines.txt
gnu base64 text.txt
gnu base64 -w 20 words.txt
gnu base64 -w0 nonl.txt
gnu_in 'aGVsbG8gd29ybGQK' base64 -d
gnu_in 'aGVsbG8=!' base64 -d
gnu od lines.txt
gnu od -c text.txt
gnu od -An -tx2 words.txt
gnu od -t x1 -t c nonl.txt
gnu od -t d4 lines.txt
gnu od -A x -t x1z text.txt
gnu od -j 4 -N 6 -c lines.txt
gnu od -a nonl.txt
gnu cmp words.txt words.txt
gnu cmp words.txt lines.txt
gnu cmp -l sorted1.txt sorted2.txt
gnu cmp -b words.txt lines.txt
gnu cmp sorted1.txt /dev/null
gnu_sh 'printf "hello\n" > f; sha256sum f > sums; sha256sum -c sums; echo x >> f; sha256sum -c sums; echo rc=$?'
expect "hexdump -C" "00000000  68 65 6c 6c 6f 20 77 6f  72 6c 64 0a 00 ff        |hello world...|
0000000e" sh -c "printf 'hello world\n\000\377' | $BIN/hexdump -C"
expect "hexdump" "0000000 6568 6c6c 0a6f
0000006" sh -c "printf 'hello\n' | $BIN/hexdump"
expect "hexdump squeeze" "00000000  61 61 61 61 61 61 61 61  61 61 61 61 61 61 61 61  |aaaaaaaaaaaaaaaa|
*
00000030  61 0a                                             |a.|
00000032" sh -c "printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' | $BIN/hexdump -C"
expect "xxd" "00000000: 6865 6c6c 6f20 776f 726c 640a            hello world." sh -c "printf 'hello world\n' | $BIN/xxd"
expect "xxd -p" "68656c6c6f0a" sh -c "printf 'hello\n' | $BIN/xxd -p"
expect "xxd -r" "hello world" sh -c "printf 'hello world\n' | $BIN/xxd | $BIN/xxd -r"
expect "xxd -r -p" "hi" sh -c "echo 6869 | $BIN/xxd -r -p; echo"
expect "xxd -i" "  0x61, 0x62" sh -c "printf ab | $BIN/xxd -i"
gnu factor 1 2 12 97 100 1000000007 18446744073709551615 600851475143

echo "== diff"
DD="$WORK/dd"
mkdir -p "$DD/a/sub" "$DD/b/sub"; cd "$DD"
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n' > a/f
printf 'one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\n' > b/f
echo x > a/onlya; echo y > b/onlyb; echo s > a/sub/s; echo t > b/sub/s
printf 'a\nb' > nonl1; printf 'a\nb\n' > nonl2
seq 1 100 > n1; seq 1 100 | sed 's/^5$/five/; s/^50$/fifty/; /^77$/d' > n2
printf 'the cat\nsat on\nthe mat\n' > w1; printf 'the  cat\nsat on\nthe mat\n' > w2
touch -d '2024-01-01 00:00:00' a/f b/f nonl1 nonl2 n1 n2 w1 w2
cd "$HERE"
diffgnu() {
  if ! have diff; then SKIP=$((SKIP + 1)); return; fi
  local exp act
  exp=$(cd "$DD" && diff "$@" 2>&1; echo "[rc=$?]")
  act=$(cd "$DD" && "$BIN/diff" "$@" 2>&1; echo "[rc=$?]")
  report "diff $*" "$([ "$exp" == "$act" ] && echo 1 || echo 0)" "$exp" "$act"
}
diffgnu a/f b/f
diffgnu -u a/f b/f
diffgnu -c a/f b/f
diffgnu -U1 a/f b/f
diffgnu -q a/f b/f
diffgnu a b
diffgnu -r a b
diffgnu -ru a b
diffgnu nonl1 nonl2
diffgnu -u nonl1 nonl2
diffgnu -i a/f b/f
diffgnu -s a/f a/f
diffgnu a/f nonexist
diffgnu -N a/f nonexist
diffgnu w1 w2
diffgnu -b w1 w2
diffgnu -w w1 w2
diffgnu n1 n2
diffgnu -u n1 n2
diffgnu -c n1 n2
diffgnu --label A --label B -u n1 n2
if have diff && have awk; then
  for i in 1 2 3 4 5 6 7 8 9 10; do
    seq 1 $((RANDOM % 80 + 5)) | awk -v s=$RANDOM 'BEGIN{srand(s)} {if (rand() < 0.2) print "x" $0; else if (rand() < 0.1) next; else print}' > "$DD/r1"
    seq 1 $((RANDOM % 80 + 5)) | awk -v s=$RANDOM 'BEGIN{srand(s)} {if (rand() < 0.2) print "y" $0; else if (rand() < 0.1) {print "new"; print} else print}' > "$DD/r2"
    touch -d '2024-01-01' "$DD/r1" "$DD/r2"
    diffgnu r1 r2
    diffgnu -u r1 r2
  done
fi

echo "== misc system"
gnu date -d @1700000000
gnu date -u -d @1700000000 +%Y-%m-%dT%H:%M:%S%z
gnu date -d '2024-02-29 13:45:00' '+%A %B %d %j %U %W %V %G %u %w %e %k %l %I %p %P %s %C %y %D %F %T %R %r %x %X %c %%'
gnu date -I -d @0
gnu date -Iseconds -d @1700000000
gnu date -R -d @1700000000
gnu date --rfc-3339=ns -d @1700000000.123456789
gnu date -d 'invalid garbage'
gnu date +%-d/%-m/%_H/%^a/%10A -d @1700000000
gnu date -d '2024-01-01 +3 days' +%F
for d in 2004-12-31 2005-01-01 2009-12-31 2010-01-03 2020-12-31 2021-01-03; do gnu date -d $d '+%j %U %W %V %G %g %u %w'; done
gnu env -i FOO=bar env
gnu env -i A=1 B=2 printenv B
gnu env -u HOME printenv HOME
gnu env nonexistentcmd
gnu printenv NOPE
gnu id
gnu id -u
gnu id -Gn
gnu id root
gnu id nosuchuser
gnu groups root
gnu whoami
gnu nproc
gnu tty
gnu getconf PAGESIZE
gnu getconf NOSUCH
gnu sleep abc
gnu timeout 0.2 sleep 5
gnu timeout 5 true
gnu timeout 1 sh -c 'exit 3'
gnu nice -n 5 nice
gnu uname -s -r -m
gnu hostname
gnu df -h /
gnu df -T /
gnu stat -f -c '%T %s' /
expect "kill -l" "HUP INT QUIT ILL TRAP ABRT BUS FPE KILL USR1 SEGV USR2 PIPE ALRM TERM STKFLT
CHLD CONT STOP TSTP TTIN TTOU URG XCPU XFSZ VTALRM PROF WINCH POLL PWR SYS" kill -l
expect "kill -l 9 SIGTERM" $'KILL\n15' kill -l 9 SIGTERM
expect "kill pid" "[rc=0]" sh -c "sleep 10 & p=\$!; $BIN/kill \$p; wait \$p; echo \"[rc=\$((\$? - 143))]\""
expect "pidof self-excluded" "[rc=1]" sh -c "$BIN/pidof zbox-nonexistent-name; echo \"[rc=\$?]\""
act=$(zrun ps -o pid,comm -p $$); report "ps -p" "$(echo "$act" | grep -q "^ *$$ " && echo 1 || echo 0)" "pid $$" "$act"
act=$(zrun ps aux); report "ps aux header" "$(echo "$act" | head -1 | grep -q '^USER *PID %CPU %MEM' && echo 1 || echo 0)" "USER PID ..." "$(echo "$act" | head -1)"
act=$(zrun uptime); report "uptime" "$(echo "$act" | grep -q 'up .*load average' && echo 1 || echo 0)" "up ... load average" "$act"
act=$(zrun free); report "free" "$(echo "$act" | grep -q '^Mem:' && echo 1 || echo 0)" "Mem:" "$act"
act=$(zrun free -h); report "free -h" "$(echo "$act" | grep -q '^Swap:' && echo 1 || echo 0)" "Swap:" "$act"
expect "which" "/bin/sh" env PATH=/bin:/usr/bin "$BIN/which" sh
expect "dmesg fallback (no crash)" "" sh -c "$BIN/dmesg >/dev/null 2>&1; true"
expect "stty size (not a tty)" "[rc=1]" sh -c "$BIN/stty size </dev/null >/dev/null 2>&1; echo \"[rc=\$?]\""
expect "less fallback to cat" "banana" sh -c "$BIN/less $FIX/words.txt | head -1"
expect "more fallback to cat" "banana" sh -c "$BIN/more $FIX/words.txt | head -1"
expect "column -t" "name   age  city   score
alice  30   Paris  88.5" sh -c "head -2 $FIX/table.csv | $BIN/column -t -s,"
expect "column" $'a\tb\tc' sh -c "printf 'a\nb\nc\n' | $BIN/column -c 40"
TR="$WORK/tree"; mkdir -p "$TR/d/e" && touch "$TR/d/a" "$TR/d/e/b" "$TR/d/.h"
expect "tree" "d
├── a
└── e
    └── b

1 directory, 2 files" sh -c "cd $TR && $BIN/tree d"
expect "tree -a --charset=ascii" "d
|-- .h
|-- a
\`-- e
    \`-- b

1 directory, 3 files" sh -c "cd $TR && $BIN/tree -a --charset=ascii d"
expect "tree -d -L 1" "d
└── e

1 directory" sh -c "cd $TR && $BIN/tree -d -L 1 d"
expect "users/who fallback" "[rc=0]" sh -c "$BIN/who >/dev/null; $BIN/users >/dev/null; echo \"[rc=\$?]\""
expect "arch" "$(uname -m)" arch
expect "mktemp" "[rc=0]" sh -c "f=\$($BIN/mktemp -p $WORK); test -f \"\$f\"; echo \"[rc=\$?]\""
expect "mktemp -d" "[rc=0]" sh -c "f=\$($BIN/mktemp -d -p $WORK); test -d \"\$f\"; echo \"[rc=\$?]\""
expect "sync" "" sync
expect "clear" $'\033[H\033[2J\033[3J' clear
expect "reboot -w (dry)" "" reboot -w
expect "sys: URL paths are passed through" "cat: sys:proc/nonexistent: No such file or directory
[rc=1]" cat sys:proc/nonexistent

echo "== unit tests (zig test)"
if "$ZIG" test "$ZDIR/tests.zig" >"$WORK/unit.log" 2>&1; then
  PASS=$((PASS + 1)); tail -1 "$WORK/unit.log" | sed 's/^/   /'
else
  FAIL=$((FAIL + 1)); FAILED_NAMES+=("zig unit tests"); tail -30 "$WORK/unit.log"
fi

echo
echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf '  %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
exit 0
