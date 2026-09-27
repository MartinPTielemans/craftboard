#!/bin/sh
# Syntax-check every Lua file (Lua 5.4 parser; WoW is 5.1-compatible so this only catches gross errors),
# with LuaJIT (a real 5.1 parser) too when installed; then check locale keys.
cd "$(dirname "$0")/.."
fail=0
for f in $(find CraftBoard -name '*.lua' -not -path '*/Libs/*'); do
  lua -e "local f,e=loadfile('$f'); if not f then print(e); os.exit(1) end" || fail=1
  if command -v luajit >/dev/null 2>&1; then
    luajit -b "$f" /dev/null || fail=1
  fi
done
[ $fail = 0 ] && echo "syntax ok"

# Locales: every L["..."] used in the addon must be listed in Locales.lua's enUS table,
# and every listed key should still be used somewhere.
used=$(mktemp); listed=$(mktemp)
cat $(find CraftBoard -name '*.lua' -not -path '*/Libs/*') | grep -vE '^[[:space:]]*--' \
  | grep -oE 'L\["([^"\\]|\\.)*"\]' | sed -E 's/^L\["(.*)"\]$/\1/' | sort -u > "$used"
sed -n '/^local enUS = {/,/^}/p' CraftBoard/Locales.lua \
  | grep -E '^[[:space:]]*"' | sed -E 's/^[[:space:]]*"(.*)",[[:space:]]*$/\1/' | sort -u > "$listed"
missing=$(comm -23 "$used" "$listed")
unused=$(comm -13 "$used" "$listed")
if [ -n "$missing" ]; then
  echo "locale keys used but not in enUS:"; echo "$missing" | sed 's/^/  /'; fail=1
fi
if [ -n "$unused" ]; then
  echo "locale keys in enUS but unused:"; echo "$unused" | sed 's/^/  /'; fail=1
fi
[ -z "$missing$unused" ] && echo "locales ok ($(wc -l < "$used" | tr -d ' ') keys)"
rm -f "$used" "$listed"

# Translations: keys must be enUS keys with the same placeholders (reports untranslated ones).
out=$(lua tools/check-locales.lua) || fail=1
echo "$out" | grep -v "^    untranslated: "
exit $fail
