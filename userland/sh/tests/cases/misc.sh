# zensh-specific builtins and behaviours
type echo cd true
type ls | sed 's|is .*/ls|is PATH/ls|'
type if
f() { echo body; }
type f
alias ll='ls -l'
type ll
command -v ll f echo if
command -V echo
type nonexistent_zz 2>&1 | sed 's/^[^:]*: line [0-9]*: //'
hash -r; hash ls; hash | sed 's|.*/ls$|PATH/ls|'
local x 2>&1 | sed 's/^[^:]*: line [0-9]*: //'
return 2>&1 | sed 's/^[^:]*: line [0-9]*: //'
break 2>&1 | sed 's/^[^:]*: line [0-9]*: //'
umask 022; umask -S; umask u=rwx,g=,o=; umask; umask 022
kill -l | head -1
trap 'echo x' USR1; trap -p USR1; trap - USR1; trap -p USR1
set -o | grep -E '^(errexit|pipefail|noglob)'
set -e; set -o | grep errexit; set +e
set +o | grep -E 'nounset|xtrace'
readonly RO1=1; readonly -p | grep RO1
export EX1=v; export -p | grep EX1
echo $- | grep -q h && echo "flags has h"
[ "$$" = "$(echo $$)" ] && echo "\$\$ same in subshell"
r1=$RANDOM; r2=$RANDOM; [ "$r1" -ge 0 ] && [ "$r1" -lt 32768 ] && echo "random in range"
echo "lineno $LINENO"
help | head -1
help cd
history
jobs
set -Q 2>&1 | sed 's/^[^:]*: line [0-9]*: //'
printf '%s\n' "$(ulimit)"
times >/dev/null && echo "times ok"
builtin echo "via builtin"
echo() { builtin echo "wrapped: $*"; }
echo hi
command echo not-wrapped
unset -f echo
cd /; cd - >/dev/null; [ "$PWD" != / ] && echo "cd - ok"
wait; echo "wait no jobs $?"
getopts 2>&1 | sed 's/^[^:]*: line [0-9]*: //'
let 2>&1 | sed 's/^[^:]*: line [0-9]*: //'
shift 99 2>&1 | sed 's/^[^:]*: line [0-9]*: //'
exit 5
