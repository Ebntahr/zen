# compat: bash dash
trap 'echo "exit trap, status $?"' EXIT
trap 'echo got USR1' USR1
kill -USR1 $$
echo "after usr1"
trap 'echo got HUP' HUP
kill -HUP $$
trap - HUP
trap '' USR2
kill -USR2 $$
echo "usr2 ignored"
( trap 'echo subshell exit' EXIT; echo in subshell )
( echo "subshell with parent trap"; )
f() { trap 'echo trap in func' USR1; kill -USR1 $$; }
f
trap 'echo "caught TERM"; exit 9' TERM
kill -TERM $$
echo "not reached"
