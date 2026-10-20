#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
version="2.10.0"
sha256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
shared="${SPARKLE_HOME:-$HOME/Library/Application Support/Sparkle-tools}/$version"
link="$root/vendor/Sparkle"
if [[ ! -f "$shared/.version" || "$(cat "$shared/.version")" != "$version" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$tmp/sparkle.tar.xz"
  echo "$sha256  $tmp/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
  rm -rf "$shared"
  mkdir -p "$shared"
  tar -xJf "$tmp/sparkle.tar.xz" -C "$shared"
  echo "$version" > "$shared/.version"
fi
if [[ ! -L "$link" || "$(readlink "$link")" != "$shared" ]]; then
  mkdir -p "$root/vendor"
  rm -rf "$link"
  ln -s "$shared" "$link"
fi
