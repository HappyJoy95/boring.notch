#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=${1:-"$root/dist"}
mkdir -p "$out"
name="boring-notch-dsh-$(node -p "require('$root/package.json').version")"
stage="$out/$name"
rm -rf "$stage" "$out/$name.zip"
mkdir -p "$stage"
cp -R "$root/lib" "$root/cordis.patch.yml" "$root/package.json" "$root/README.md" "$stage/"
(cd "$out" && ditto -c -k --sequesterRsrc --keepParent "$name" "$name.zip")
rm -rf "$stage"
printf '%s\n' "$out/$name.zip"
