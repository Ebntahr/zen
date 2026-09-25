# compat: bash
set -x
echo hello
x=5
echo "$x" 'a b' ""
y=$(echo sub)
f() { echo in-f; }
f arg
: ${x:-default}
set +x
echo quiet
