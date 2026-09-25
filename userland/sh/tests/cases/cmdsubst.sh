# compat: bash dash
echo $(echo simple)
echo `echo backtick`
echo "$(echo quoted   spaces)"
echo $(echo unquoted   spaces)
x=$(printf 'trailing\n\n\n'); echo "[$x]"
x=$(printf '\n\nleading'); echo "[$x]"
echo $(echo $(echo nested $(echo deep)))
echo `echo \`echo bq-nested\``
echo $(case x in x) echo case-in-subst;; esac)
echo $( (echo subshell-in-subst) )
echo $(( $(echo 20) + $(echo 22) ))
echo "$(echo "a")$(echo "b")"
v=$(exit 3); echo "status $?"
y=$(cd /; pwd); echo "$y"
echo "pwd unchanged: $([ "$(pwd)" != / ] && echo yes)"
z=$(for i in 1 2 3; do echo $i; done); echo $z
echo "$(echo multi
echo line)"
echo $(echo 'a)b')
echo "$(echo "(paren)")"
cnt=$(printf 'a\nb\nc\n' | wc -l); echo $cnt
echo $(echo "x" # comment in subst
)
set -- $(echo 1 2 3); echo $#
w=$(echo "*"); echo "$w"
echo pre$(echo mid)post
