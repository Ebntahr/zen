# compat: bash
i=5
echo $((i++)) $i $((i--)) $i $((++i)) $((--i))
echo $((2 ** 10)) $((3 ** 0)) $((2 ** 3 ** 2))
echo $((2#1010)) $((16#ff)) $((8#17)) $((36#z))
(( 5 > 3 )) && echo "arith cmd true"
(( 0 )) || echo "arith cmd false"
(( j = 4 * 5 )); echo $j
let k=6*7 "m = k / 2"; echo $k $m
let "0" || echo "let zero is false"
expr_var="3+4"; echo $((expr_var * 2))
w=1; (( w++ )); echo $w
echo $(( $(echo 3) ** 2 ))
