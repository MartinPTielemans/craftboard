#!/bin/sh
# Symlink the addon into the Forever beta AddOns folder for live testing.
set -e
A="/Applications/World of Warcraft/_classic_beta_/Interface/AddOns/CraftBoard"
rm -rf "$A"
ln -s "$(cd "$(dirname "$0")/.." && pwd)/CraftBoard" "$A"
echo "linked -> $A"
