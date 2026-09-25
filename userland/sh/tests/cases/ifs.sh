# compat: bash dash
# Field splitting with IFS
show() { printf '<%s>' "$@"; echo " ($#)"; }
x='  a  b   c  '
show $x
IFS=:
y='a:b::c:'
show $y
y=':a:b'
show $y
IFS=' :'
y=' a : b  c:  d '
show $y
IFS=', '
y='a, b,,c , d'
show $y
IFS=
show $x
unset IFS
show $x
IFS='
'
lines='line one
line two'
show $lines
unset IFS
set -- "a b" "c d"
show $*
show "$*"
show $@
show "$@"
IFS=-
show "$*"
unset IFS
n=12
IFS=1
show $n
unset IFS
IFS=' '
v='a	b'
show $v
unset IFS
echo "${x}" | tr ' ' '.'
