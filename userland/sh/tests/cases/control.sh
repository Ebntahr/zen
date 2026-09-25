# compat: bash dash
for i in 1 2 3; do echo "i=$i"; done
for i in; do echo never; done
for w in a "b c" d; do printf '[%s]' "$w"; done; echo
set -- x y z
for p; do printf '<%s>' "$p"; done; echo
for p do printf '{%s}' "$p"; done; echo
n=0
while [ $n -lt 3 ]; do n=$((n + 1)); echo "while $n"; done
until [ $n -eq 0 ]; do echo "until $n"; n=$((n - 1)); done
for i in 1 2 3 4 5; do
  if [ $i -eq 2 ]; then continue; fi
  if [ $i -eq 4 ]; then break; fi
  echo "loop $i"
done
for i in a b; do
  for j in 1 2 3; do
    [ $j -eq 2 ] && continue 2
    echo "$i$j"
  done
done
for i in a b; do
  for j in 1 2; do
    echo "$i$j"
    break 2
  done
done
if true; then echo then; fi
if false; then echo no; else echo else; fi
if false; then echo 1; elif false; then echo 2; elif true; then echo 3; else echo 4; fi
if ! false; then echo negated; fi
true && echo and-true
false && echo and-false
false || echo or-false
true || echo or-true
true && false || echo chain
{ echo brace; echo group; }
{ false; }; echo "group status $?"
x=0
while true; do x=$((x+1)); if [ $x -ge 5 ]; then break; fi; done; echo "x=$x"
while false; do :; done; echo "while-false status $?"
i=0; while [ $i -lt 3 ]; do i=$((i+1)); done && echo "loop done $i"
for i in 1 2; do echo $i; done | tr '12' 'ab'
echo "last: $i"
if [ -n "" ] || [ -z "" ]; then echo "test or"; fi
k=3; while k=$((k-1)); [ $k -gt 0 ]; do echo "k=$k"; done
