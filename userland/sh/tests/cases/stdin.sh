# compat: bash
# Scripts read from stdin must be consumed one line at a time so that
# commands can read the following lines.
printf 'read x\nhello from stdin\necho "got: $x"\n' | $TEST_SHELL
printf 'echo one\necho two\n' | $TEST_SHELL -s
printf 'echo "args: $1 $2"\n' | $TEST_SHELL -s a b
printf 'if true\nthen\n  echo multi-line\nfi\n' | $TEST_SHELL
printf 'cat <<EOF\nheredoc via stdin\nEOF\necho after\n' | $TEST_SHELL
printf 'exit 3\necho not reached\n' | $TEST_SHELL; echo "status $?"
echo 'echo from file' > script.txt
$TEST_SHELL < script.txt
