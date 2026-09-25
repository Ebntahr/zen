# compat: bash dash
# Pathname expansion
mkdir d && cd d || exit 1
touch a.txt b.txt c.log .hidden 'sp ace.txt' ab abc
mkdir sub sub2
touch sub/x.txt sub2/y.txt
echo *.txt
echo ?
echo a?
echo a*
echo [ab]*
echo [!a]*
echo [a-b].txt
echo .h*
echo *
echo */
echo */*.txt
echo nomatch*
echo "*.txt" '*.txt' \*.txt
x='*.log'
echo $x "$x"
set -f
echo *.txt
set +f
for f in *.txt; do printf '[%s]\n' "$f"; done
echo [[:alpha:]]b
echo sub/../a.*
echo `echo *.log`
cd ..
echo d/*.log
