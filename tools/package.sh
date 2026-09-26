#!/bin/sh
# Build dist/CraftBoard-<version>.zip by hand, with the same contents the BigWigs packager ships:
# the CraftBoard/ folder (dotfiles excluded) plus the root LICENSE, under a top-level CraftBoard/.
# Fallback for manual CurseForge upload.
set -e
cd "$(dirname "$0")/.."
root=$(pwd)
version=$(awk -F: '/^## Version:/ { gsub(/[ \t\r]/, "", $2); print $2; exit }' CraftBoard/CraftBoard.toc)
[ -n "$version" ] || { echo "no ## Version: in CraftBoard/CraftBoard.toc" >&2; exit 1; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/CraftBoard"
(cd CraftBoard && find . -name '.*' ! -name '.' -prune -o -type f -print) | while read -r f; do
  mkdir -p "$stage/CraftBoard/$(dirname "$f")"
  cp "CraftBoard/$f" "$stage/CraftBoard/$f"
done
cp LICENSE "$stage/CraftBoard/LICENSE"

mkdir -p dist
out="$root/dist/CraftBoard-$version.zip"
rm -f "$out"
(cd "$stage" && zip -qrX "$out" CraftBoard)
echo "built $out"
