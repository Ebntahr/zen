# compat: bash dash
# POSIX parameter expansion
v=hello.tar.gz
echo ${v%.*} ${v%%.*} ${v#*.} ${v##*.}
echo ${v%x} ${v#x} ${v%%} "${v#}"
p=/usr/local/lib/libfoo.so
echo ${p##*/} ${p%/*} ${p#/*/}
echo ${#v} ${#p} ${#nosuch}
echo "${unset1:-default}" "${unset2-dflt}"
empty=
echo "[${empty-notused}]" "[${empty:-used}]" "[${empty+set}]" "[${empty:+alt}]"
echo "[${unset3+set}]" "[${unset3:+alt}]"
echo ${unset4:=assigned} "$unset4"
echo ${empty:=nowset} "$empty"
: ${colon_assign=value}; echo "$colon_assign"
echo "${v:+alternate}"
(echo ${nope:?custom message}) 2>/dev/null; echo "err status nonzero: $([ $? -ne 0 ] && echo yes)"
(echo ${nope?}) 2>/dev/null || echo "unset errors"
x=5
echo "${x:-$(echo not-run)}" "${nope:-$(echo run)}"
echo ${nope:-a b c}
set -- ${nope:-a b c}; echo "$#"
set -- "${nope:-a b c}"; echo "$#"
pat='*.gz'
echo ${v%$pat} "${v%"$pat"}"
star='*'
echo "${v#$star}" "${v#"$star"}"
set -- one two three
echo $1 $2 $3 ${1} $# "$*"
echo ${#1}
set -- a b c d e f g h i j k
echo $10 ${10} ${11}
echo "$0" | grep -c params
q=abcabc
echo ${q#a*c} ${q##a*c} ${q%b*} ${q%%b*}
path=a/b/c
echo ${path%%/*} ${path#*/} ${path%/*}
