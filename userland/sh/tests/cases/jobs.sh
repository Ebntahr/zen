# compat: bash dash
sleep 0.1 &
pid=$!
[ -n "$pid" ] && echo "have pid"
wait $pid; echo "wait status $?"
(exit 3) &
wait $!; echo "bg exit $?"
( sleep 0.1; echo background-out ) &
wait
echo "after wait-all"
for i in 1 2 3; do (sleep 0.0$i; exit $i) & done
wait
echo "waited three"
{ echo in-bg-group; } &
wait
false & wait $!; echo "false bg $?"
echo a | tr a b &
wait
x=1; (x=2; echo "sub x=$x") & wait; echo "parent x=$x"
