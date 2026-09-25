# compat: bash dash
# Quoting: single, double, backslash, nested
x='a b  c'
printf '[%s]\n' $x
printf '[%s]\n' "$x"
printf '[%s]\n' '$x' "\$x" \$x
printf '[%s]\n' "a\\b" 'a\\b' a\\b
printf '[%s]\n' "q\"uote" 'it'"'"'s' "back\`tick"
printf '[%s]\n' "dollar\$" "\x" '\x' \x
printf '[%s]\n' "" '' ""''"" x""y
printf '[%s]\n' "${x}"'lit'${x}
printf '[%s]\n' a\
b
printf '[%s]\n' "multi
line"
printf '[%s]\n' "tab	here" 'semi;colon' "pipe|amp&"
printf '[%s]\n' \# a#b '#' "#"
printf '[%s]\n' ~root/x "~" '~' x~
y="*"
printf '[%s]\n' "$y" "\*"
printf '[%s]\n' "$(echo "inner \"quotes\" $x")"
printf '[%s]\n' "`echo "bq $x"`"
printf '[%s]\n' "a'b" 'a"b'
empty=
printf '[%s]\n' $empty "$empty" ${empty} "${empty}"
set -- $empty
echo "count=$#"
set -- "$empty"
echo "count=$#"
