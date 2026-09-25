# compat: bash dash
set -e
false || echo "or ok"
! true
echo "bang ok"
if false; then echo no; fi
while false; do :; done
false && echo no
echo "conditionals ok"
f() { false; echo "in f after false: runs because f in condition"; }
if f; then echo "f ok"; fi
f || echo unused
x=$(echo sub-ok)
echo "$x"
{ false || true; }
echo "group ok"
(false) || echo "subshell or ok"
echo "before failure"
(exit 4)
echo "not reached"
