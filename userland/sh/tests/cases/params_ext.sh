# compat: bash
v=hello.tar.gz
echo ${v/l/L} ${v//l/L} ${v/#h/H} ${v/%gz/GZ} ${v/x/y} ${v//[aeiou]/_}
echo "${v/tar/"t a r"}" ${v/.tar} "${v//./ }"
echo ${v:1:3} ${v:6} ${v: -2} ${v: -6:3} ${v:0:0}x ${v:100}x
echo ${v^} ${v^^} ${v,} "${v^^}"
U=HELLO; echo ${U,,} ${U,}
echo ${#v}
set -- a b c d e
echo ${@:2} ${@:2:2} "${@:4}" ${*:1:1}
echo $'tab:\t| nl:\\n| hex:\x41 | oct:\101 | quote:\' | esc:\e[0m' | cat -v
x=abc; x+=def; echo $x
n=1; n+=1; echo $n
path=/a/b/c.txt
echo "${path##*/}" "${path%.*}" "${path//\//:}"
s="  spaced  "; echo "[${s// /}]"
e=; echo "[${e/x/y}]" "[${unset_v/x/y}]"
arr="one two three"; echo "${arr// /,}"
echo ${v//}
echo "${v/%}"
