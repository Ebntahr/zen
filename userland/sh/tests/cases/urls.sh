# compat: bash dash
# Zen OS paths are URLs such as sys:proc or file:/etc/passwd; the shell
# must never give ':' special meaning in words, paths or commands.
mkdir 'sys:proc' 'display:'
echo info > 'display:/info'
echo 1 > 'sys:proc/status'
cat display:/info
cd sys:proc && echo "in ${PWD##*/}" && cd ..
echo sys:*
echo sys:proc/*
for f in sys:proc/*; do echo "file $f"; done
x=file:/etc/passwd
echo "${x%%:*}" "${x#*:}"
case $x in file:*) echo "scheme file";; esac
ls -d sys:proc
p=sys:proc/status; cat "$p"
v=a:b:c; echo $v
IFS=:; set -- $v; echo $#; unset IFS
mkdir bin; printf '#!/bin/sh\necho scheme-cmd "$@"\n' > 'bin/net:get'; chmod +x 'bin/net:get'
PATH=$(pwd)/bin:$PATH
net:get url:thing
cat < display:/info
echo out > sys:proc/new; cat sys:proc/new
