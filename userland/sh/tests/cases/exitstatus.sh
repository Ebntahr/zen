# compat: bash dash
true; echo $?
false; echo $?
nosuchcommand_zz 2>/dev/null; echo $?
touch notexec; ./notexec 2>/dev/null; echo $?
mkdir adir; ./adir 2>/dev/null; echo $?
(exit 42); echo $?
(exit 300); echo $?
sh -c 'exit 7'; echo $?
! true; echo $?
! false; echo $?
true | false; echo $?
false | true; echo $?
{ true; false; }; echo $?
if false; then :; fi; echo "if-no-branch $?"
if true; then false; fi; echo "if-false-body $?"
for i in 1; do false; done; echo "for $?"
x=$(exit 9); echo "assign-subst $?"
x=1; echo "plain-assign $?"
f() { return 5; }; f; echo "func $?"
f() { false; }; f; echo "func-implicit $?"
{ sh -c 'kill -9 $$'; } 2>/dev/null; echo "signal $?"
exit 3
