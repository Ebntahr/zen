# compat: bash dash
echo one > f; cat f
echo two >> f; cat f
echo three >| f; cat f
cat < f
cat 0< f
echo err 2> e >&2; cat e
echo both > g 2>&1; cat g
{ echo out; echo err >&2; } > o 2> e2; cat o; cat e2
{ echo out; echo err >&2; } > all 2>&1; cat all
{ echo out; echo err >&2; } 2>&1 >/dev/null | cat
exec 3> fd3
echo "to three" >&3
echo "again" 1>&3
exec 3>&-
cat fd3
exec 4< f
read line <&4
echo "read from 4: $line"
exec 4<&-
echo data > rw
exec 5<> rw
read l <&5
echo "rw: $l"
exec 5>&-
: > empty; wc -c < empty | tr -d ' '
> created; ls created
echo x > "space name"; cat "space name"
n=fname; echo var > $n; cat fname
cat nonexistent 2>/dev/null || echo "missing file"
echo abc 1>&2 2>/dev/null
( echo sub-out; echo sub-err >&2 ) 2>&1 | sort
while read w; do echo "w=$w"; done < f
echo redirect-before >/dev/null; echo visible
2>/dev/null echo "prefix redirect"
echo a b c > f 2>&1 < /dev/null; cat f
set -C
echo clobber 2>/dev/null > f || echo "noclobber works"
echo force >| f; cat f
set +C
x=$(echo captured 2>&1); echo "$x"
f() { echo in-func; echo in-func-err >&2; }
f 2>/dev/null
f > fo 2>&1; cat fo
