# compat: bash
echo $(( (1+2) * (3+4) )) $(( $(echo 5) + 1 ))
case x in (x) echo paren-pat ;; esac
for i in a b; do :; done; echo "i=$i"
echo a # comment
echo a#b
# only comment
if true; then # comment after then
  echo x # trailing
fi # after fi
echo "$( echo ")" )"
echo $(echo "(" )
echo ${unset-"}"}
x=${y:-'a b'}; echo "$x"
echo if then else fi do done case esac in
echo ! {
a=1 b=2 env | grep '^[ab]=' | sort
cat <<EOF | tr a-z A-Z
piped
EOF
f()
{
  echo "newline before brace"
}
f
g() ( echo "subshell body" )
g
case y in
  # comment in case
  x) echo no
     ;;
  y)
     echo yes
     ;;
esac
echo "cont\
inued" con\
tinued
echo $'it\'s'
echo "a
b" | wc -l
v=$(cat <<EOF
heredoc in subst $x
EOF
); echo "$v"
while read -r line; do echo "r:$line"; done <<EOF
1
2
EOF
echo "nested $(echo "in $(echo "deep")")"
echo `echo "bq \`echo inner\`"`
[ -n "$(echo x)" ] && echo "test with subst"
echo "${x:+"quoted alt"}" ${x:+unquoted alt}
echo "$(printf '%s' "a  b")"
: <<'COMMENT'
this is ignored $(not run)
COMMENT
echo done-parsing
echo $((1 +
2))
echo "tab	sep" | cut -f2
echo '\n' "\n"
e=; echo "[${e:-}]" "[${e-dflt}]"
echo $# ${#} "$#"
set -- 1 2; echo "${1}${2}" "$1$2"
echo "$(( 1 + (2 * 3) ))"
x=5; echo $((x+=1)); echo $x
echo "a""b"'c'd
echo "$(
  echo multi
  echo line
)"
