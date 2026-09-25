# compat: bash
echo {a,b} x{1,2,3}y {a,b}{c,d}
echo a{b,c{d,e}}f
echo {1..5} {5..1} {a..e} {1..10..3} {01..10} {-2..2}
echo {} {x} {a,} {,b} "{a,b}" \{a,b\} '{a,b}'
v=Z; echo {$v,w} {"q r",s}
echo pre{A..C}post
echo {x..z}{1..2}
set -B; echo {a,b}; set +B; echo {a,b}; set -B
find_like={}; echo $find_like
echo a{b}c ${v}{1,2}
