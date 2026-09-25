# compat: bash dash
parse() {
  OPTIND=1
  while getopts "ab:c" opt "$@"; do
    case $opt in
      a) echo "flag a" ;;
      b) echo "b=$OPTARG" ;;
      c) echo "flag c" ;;
      \?) echo "invalid" ;;
    esac
  done
  shift $((OPTIND - 1))
  echo "remaining: $*"
}
parse -a -b val file
parse -ac -bval x y
parse -- -a
parse nonopt -a
parse -b 2>/dev/null
parse -z 2>/dev/null
silent() {
  OPTIND=1
  while getopts ":x:" o "$@"; do
    case $o in
      :) echo "missing arg for $OPTARG" ;;
      \?) echo "unknown $OPTARG" ;;
      x) echo "x=$OPTARG" ;;
    esac
  done
}
silent -x
silent -q
silent -x 1 -x2
set -- -a -c pos
OPTIND=1
while getopts ac o; do echo "pos opt $o"; done
echo "OPTIND=$OPTIND"
