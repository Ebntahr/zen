# compat: bash dash
t() {
  case $1 in
    a|b) echo "$1: a or b" ;;
    [0-9]*) echo "$1: starts with digit" ;;
    *.txt) echo "$1: text" ;;
    \*) echo "$1: literal star" ;;
    "q*") echo "$1: quoted q*" ;;
    '') echo "empty" ;;
    ?) echo "$1: single char" ;;
    *) echo "$1: other" ;;
  esac
}
for w in a b 42 notes.txt '*' 'q*' qq '' z hello; do t "$w"; done
case foo in
  f*)
    echo multi
    echo line
    ;;
esac
case x in (x) echo paren-pattern;; esac
case abc in a*c) echo star-mid;; esac
case "a b" in "a b") echo space;; esac
v=hi
case hi in $v) echo var-pattern;; esac
case '$v' in '$v') echo literal-dollar;; esac
case abc in *) ;; esac
echo "empty body status: $?"
case nomatch in a) echo no;; esac
echo "no match status: $?"
case "x" in
  x) echo first
esac
case y in x) ;; y) echo second-without-semis
esac
r=$(case a in a) echo in-cmdsub;; esac)
echo "$r"
