# compat: bash dash
x=parent
(x=child; echo "in sub: $x")
echo "after: $x"
(cd /; pwd)
[ "$(pwd)" != / ] && echo "cwd preserved"
(exit 3); echo "status $?"
( (echo nested) )
(set -- a b; echo "sub params $#")
echo "parent params $#"
f() { echo func; }
(f)
(unset -f f; type f >/dev/null 2>&1 || echo "unset in sub")
f
v=$( (echo deep) ); echo "$v"
(echo out; echo err >&2) 2>/dev/null
(trap 'echo sub-trap' EXIT; true)
echo "$(echo a; (echo b); echo c)"
umask 022; (umask 077); umask
