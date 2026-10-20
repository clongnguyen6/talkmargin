#!/bin/zsh
# Packs an unzipped Office Open XML directory into a .docx (zip, deflate,
# [Content_Types].xml first). Usage: make-docx.sh <src-dir> <out.docx>
set -e
src="$1"; out="$2"
[ -d "$src" ] && [ -n "$out" ] || { echo "usage: $0 <src-dir> <out.docx>" >&2; exit 2; }
out_abs="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
rm -f "$out_abs"
cd "$src"
zip -X -D -q "$out_abs" '[Content_Types].xml'
find . -type f ! -name '[Content_Types].xml' ! -name '.DS_Store' | sed 's|^\./||' | sort | zip -X -D -q "$out_abs" -@
