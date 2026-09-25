# compat: bash dash
base=$(pwd)
mkdir -p a/b/c 'with space' dir2
cd a/b
echo "${PWD#$base}"
cd c; echo "${PWD#$base}"
cd ..; echo "${PWD#$base}"
cd ../..; echo "${PWD#$base}" "[${OLDPWD#$base}]"
cd - >/dev/null; echo "${PWD#$base}"
cd "$base"
cd 'with space'; echo "${PWD#$base}"; cd ..
cd nonexistent 2>/dev/null || echo "cd failed"
HOME=$base/dir2; cd; echo "${PWD#$base}"
cd "$base"
CDPATH=$base/a
cd b >/dev/null; echo "${PWD#$base}"
unset CDPATH
cd "$base"
pwd | sed "s|$base|BASE|"
cd a && cd b && pwd | sed "s|$base|BASE|"
