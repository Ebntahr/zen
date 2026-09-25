# zensh-specific: syntax errors and their exit status
for src in 'if true; then' 'fi' 'echo (' 'for x in; do' 'case x in' '{ echo' 'echo "unterminated' 'done' 'while :; do echo; ' '$(' 'a && ' 'x=$((1+))' '; ;' 'echo ${bad sub}'; do
  $TEST_SHELL -c "$src"
  echo "status $?"
done 2>&1 | sed 's/^[^:]*: line [0-9]*: /zensh: /'
eval 'if' 2>/dev/null; echo "eval syntax status $?"
eval 'echo eval-still-works'
