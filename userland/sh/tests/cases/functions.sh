# compat: bash dash
f() { echo "f called with $# args: $*"; }
f; f a; f a b "c d"
g() {
  echo "g: \$1=$1"
  return 42
}
g x; echo "status=$?"
outer() { inner "$@"; echo "outer after inner: $?"; }
inner() { echo "inner: $*"; return 3; }
outer 1 2
counter=0
incr() { counter=$((counter + 1)); }
incr; incr; incr; echo "counter=$counter"
setpos() { set -- x y; echo "inside: $*"; }
set -- a b c
setpos; echo "outside: $*"
recurse() { if [ "$1" -gt 0 ]; then echo "depth $1"; recurse $(($1 - 1)); fi; }
recurse 3
fib() { if [ $1 -lt 2 ]; then echo $1; else echo $(( $(fib $(($1-1))) + $(fib $(($1-2))) )); fi; }
fib 12
redefine() { echo one; }
redefine
redefine() { echo two; }
redefine
withredir() { echo "to file"; } > out.txt
withredir; cat out.txt
subsh() ( echo "in subshell func"; exit 5 )
subsh; echo "subsh status=$?"
loopy() { for i in 1 2 3; do [ $i = 2 ] && return $i; done; }
loopy; echo "loopy=$?"
local_test() { local v=local; echo "in: $v"; }
v=global; local_test; echo "out: $v"
nested_def() { inner_fn() { echo "defined inside"; }; }
nested_def; inner_fn
echo "\$0 unchanged: $(basename "$0")"
retlast() { false; }
retlast; echo "implicit return: $?"
