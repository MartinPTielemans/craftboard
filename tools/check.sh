#!/bin/sh
# Syntax-check every Lua file (Lua 5.4 parser; WoW is 5.1-compatible so this only catches gross errors).
cd "$(dirname "$0")/.."
fail=0
for f in $(find CraftBoard -name '*.lua' -not -path '*/Libs/*'); do
  lua -e "local f,e=loadfile('$f'); if not f then print(e); os.exit(1) end" || fail=1
done
[ $fail = 0 ] && echo "syntax ok"
exit $fail
