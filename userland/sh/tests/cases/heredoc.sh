# compat: bash dash
name=World
cat <<EOF
Hello, $name!
  Indented line
Math: $((6 * 7))
Cmd: $(echo substituted)
Escaped: \$name \\ \`
Quotes: "double" 'single'
EOF
cat <<'EOF'
Literal $name $(echo no) \$
EOF
cat <<"EOF"
Also literal $name
EOF
cat <<\EOF
Backslash-quoted $name
EOF
cat <<-EOF
	tab-stripped $name
		two tabs
	EOF
cat <<EOF | tr a-z A-Z
piped heredoc
EOF
cat <<A; cat <<B
first
A
second
B
f() {
  cat <<END
in function: $1
END
}
f arg1
f arg2
while read line; do echo "read: $line"; done <<EOF
line 1
line 2
EOF
cat <<EOF
EOF
echo "empty heredoc done"
cat <<EOF
line continuation \
joined
EOF
x=$(cat <<EOF
inside cmdsub
EOF
)
echo "$x"
cat << EOF
spaced delimiter
EOF
cat <<EOF >out.txt
to file
EOF
cat out.txt
body=$(i=0; while [ $i -lt 2000 ]; do echo "line $i with some padding"; i=$((i+1)); done)
eval "cat <<EOF | wc -l
$body
EOF"
cat <<EOF | tail -1
$body
EOF
