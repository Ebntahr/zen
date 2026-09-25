# compat: bash
f() { echo out; echo err >&2; }
f &> both; cat both
f &>> both; cat both
f >& both2; cat both2
f |& tr a-z A-Z
cat <<< "here string"
cat <<< "multi word $HOME" | sed "s|$HOME|H|"
read -r a b <<< "x y"; echo "$a,$b"
tr a-z A-Z <<< lower
exec 7>&1
echo "via 7" >&7
exec 7>&-
echo "moved" 3>&1 1>&2 2>&3 3>&- 2>/dev/null
{ echo "fd dup"; } 4>&1 >&4
cat 0<<EOF
zero heredoc
EOF
