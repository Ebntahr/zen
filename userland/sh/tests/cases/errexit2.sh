# compat: bash dash
set -e
g() { echo "g start"; false; echo "g not reached"; }
g
echo "not reached"
