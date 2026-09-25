# zensh-specific: invocation and startup
$TEST_SHELL -c 'echo "c: $0 $1 $2 $#"' name one two
$TEST_SHELL -c 'echo "\$0 default: $0"' | sed 's|[^ ]*/||; s/zensh[-a-z0-9]*/zensh/'
echo 'echo "script: $1 $#"; exit 4' > s.sh
$TEST_SHELL s.sh arg1 arg2; echo "status $?"
$TEST_SHELL nonexistent_script.sh 2>/dev/null; echo "missing script status $?"
$TEST_SHELL -c 'exit 300'; echo "exit 300 -> $?"
$TEST_SHELL -e -c 'false; echo not-reached'; echo "-e status $?"
$TEST_SHELL -o pipefail -c 'false | true'; echo "pipefail $?"
$TEST_SHELL -x -c 'echo traced' 2>&1
$TEST_SHELL -n -c 'echo should not run'; echo "noexec $?"
$TEST_SHELL -c 'echo $-' | grep -q c && echo "dollar-dash has c"
$TEST_SHELL --version | sed 's/[0-9][0-9.]*/X/'
mkdir -p home2
echo 'echo profile-ran; PROFILE_VAR=1' > home2/.profile
HOME=$PWD/home2 $TEST_SHELL -l -c 'echo "var=$PROFILE_VAR"' 2>&1 | grep -E '^(profile-ran|var=)'
HOME=$PWD/home2 $TEST_SHELL --noprofile -l -c 'echo "noprofile var=$PROFILE_VAR"'
$TEST_SHELL -c 'echo $SHLVL' >/dev/null && echo "shlvl ok"
$TEST_SHELL -c 'syntax error ( here' 2>/dev/null; echo "syntax status $?"
$TEST_SHELL -c 'echo ${x' 2>/dev/null; echo "unterminated status $?"
$TEST_SHELL -c 'cd /; pwd'
$TEST_SHELL -c 'echo $PPID' | grep -q '^[0-9][0-9]*$' && echo "ppid ok"
$TEST_SHELL -c 'echo "$ZENSH_VERSION"' | grep -q '^[0-9]' && echo "version var ok"
