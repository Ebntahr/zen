# compat: bash dash
alias hi='echo hello'
hi there
alias say=echo
say something
alias chain='say chained'
chain
alias ls_like='echo ls'
alias ls_like='echo redefined'
ls_like
alias echo='echo aliased-echo'
echo recursive
unalias echo
echo unaliased
alias sp='echo with-space '
alias word=expanded
sp word
alias | sort
unalias hi say chain ls_like sp word
alias | wc -l | tr -d ' '
f() { hi; }
alias hi='echo late'
f 2>/dev/null || echo "alias not expanded in earlier-parsed function"
