# compat: bash dash
# Declaration utilities, special builtins, misc POSIX corners
y="a b"
f() { local x=$y; echo "[$x]"; }
f
export e=$y; echo "[$e]"
readonly r=$y; echo "[$r]"
export t=~/sub; [ "$t" = "$HOME/sub" ] && echo "tilde in export"
v="p=1 q=2"; export $v; echo "$p$q"
x=1 :; echo "special builtin assignment persists: $x"
z=2 true; echo "regular builtin assignment: [${z-}]"
unset x; echo "[${x-unset}]"
( echo hi > /nonexistent/dir/file ) 2>/dev/null; [ $? -ne 0 ] && echo "redir failure nonzero"
exec 3>&1
out=$(echo "to fd3" >&3; echo captured)
echo "$out"
exec 3>&-
{ echo a; echo b; } | while read l; do echo "l=$l"; done
echo "pipe subshell var: [${l-}]"
n=0; for i in 1 2 3; do n=$((n+i)); done; echo "n=$n"
g() { return 7; }; g; echo "g=$?"
h() { (return 3); echo "after subshell return $?"; }; h
set -- "a b" c
IFS=,; echo "$*"; unset IFS
echo ${#}
cd; [ "$PWD" = "$HOME" ] && echo "cd home"
cd "$OLDPWD"
w=$(trap 'echo t' USR2; trap) ; echo "${w:-no traps listed in subst}" | sed 's/^trap -- //'
unset -v y; echo "[${y-gone}]"
fn() { echo fn; }; unset -f fn; fn 2>/dev/null || echo "fn unset"
a=1; b=$a; a=2; echo "$b"
echo "$(( 010 + 0x10 ))"
c="x"; case $c in [[:alpha:]]) echo alpha-class;; esac
printf '%s\n' "a\\b" 'c\d'
