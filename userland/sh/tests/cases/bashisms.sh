# compat: bash
# Features beyond POSIX that zensh shares with bash
function kw_func { echo "function keyword"; }
kw_func
function kw_paren() { echo "function keyword with parens"; }
kw_paren
declare -x DX=exported; sh -c 'echo "child: $DX"'
g() { declare L=inner; typeset M=also; echo "$L $M"; }
L=outer; g; echo "$L [${M-unset}]"
declare -r DR=ro; (DR=x) 2>/dev/null || echo "declare -r readonly"
trap 'echo "ERR trap: $?"' ERR
false
(exit 3)
true
trap - ERR
false
echo "after err trap removed"
set -o pipefail; false | true; echo "pipefail $?"; set +o pipefail
{ time true; } 2>&1 | grep -c '^real'
x=1; x+=2; echo "$x"
echo "${x:-$((x+1))}"
cat <<< "here-string"
echo {a,b} # no brace expansion in POSIX mode either
n=0; while (( n < 3 )); do (( n++ )); done; echo "n=$n"
echo $(( 2 ** 8 ))
s=abc; echo "${s:1}" "${s^^}"
echo $'a\tb'
read -r -d ':' tok <<< "first:second"; echo "$tok"
printf -v out '%s-%s' a b; echo "$out"
echo "abcdef" | { read -n 3 part; echo "$part"; }
