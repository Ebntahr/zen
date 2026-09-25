# compat: bash
echo plain
echo -n "no newline"; echo
echo -e 'esc\tapes\n2nd' 
echo -E 'raw\t'
echo -- dashdash
echo -x not-an-option
printf '%s|%s\n' a b c
printf '%d %i %u %x %X %o %c %%\n' 42 -7 3 255 255 8 A
printf '[%5s][%-5s][%.2s][%05d][%-4d][%+d][% d]\n' ab cd xyz 42 7 5 5
printf '%.3f %.0f %e %g %g\n' 3.14159 2.5 12345.678 0.0001 100000
printf '%s\n' "no args"
printf 'x=%s y=%s\n' 1
printf '%b\n' 'b\tescape'
printf '%q\n' "has space" 2>/dev/null | head -1
printf '%d\n' "'a"
printf -v pv '%03d' 7; echo "pv=$pv"
printf 'tab\there\n'
test 1 -eq 1 && echo eq
test abc = abc -a 1 -lt 2 && echo and
[ -f /etc/passwd ] && echo file
[ -d /etc ] && echo dir
[ -e /nonexistent ] || echo nofile
[ "" ] || echo empty-false
[ x ] && echo nonempty-true
[ ! x ] || echo not
[ 3 -gt 2 ] && [ 2 -ge 2 ] && [ 1 -le 1 ] && [ 1 -ne 2 ] && echo numeric
[ a \< b ] && echo lt
[ -z "" -a -n x ] && echo zn
[ \( 1 = 1 \) -o 1 = 2 ] && echo paren
[ 1 -eq x ] 2>/dev/null; echo "bad int status $?"
set -- a b c d
shift; echo "$@"
shift 2; echo "$@"
shift 5 2>/dev/null; echo "shift too many: $?"
set -- x y; echo $#
set a b c; echo "$2"
export EXP=exported
sh -c 'echo "child sees $EXP"'
NOEXP=local; sh -c 'echo "child sees [${NOEXP}]"'
TEMP=temporary sh -c 'echo "temp: $TEMP"'; echo "after temp: [${TEMP}]"
unset EXP; sh -c 'echo "after unset [$EXP]"'
readonly RO=fixed
(RO=changed) 2>/dev/null || echo "readonly enforced"
eval 'echo eval-ran'; eval "E1=1 E2=2"; echo $E1$E2
cmd='echo from variable'; eval $cmd
type echo; type cd | head -1
command -v printf
command -v nonexistent_zz || echo "not found by command -v"
command echo via-command
true; echo "true $?"; false; echo "false $?"; :; echo "colon $?"
umask 027; umask; umask 022
x=5; let x=x+1; echo $x
read a b <<EOF
first second third
EOF
echo "a=$a b=$b"
read -r raw <<'EOF'
back\slash
EOF
echo "$raw"
read nor <<'EOF'
back\slash
EOF
echo "$nor"
IFS=: read -r f1 f2 <<EOF
one:two:three
EOF
echo "$f1 / $f2"
echo "no names" | { read; echo "REPLY=$REPLY"; }
printf 'no newline at end' | { read l; echo "status $? l=$l"; }
kill -l 9; kill -l INT
pwd >/dev/null && echo pwd-ok
