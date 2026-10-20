#!/bin/zsh
set -euo pipefail
here="${0:A:h}"
source "$here/scripts/identity.sh"
dest="${1:-${INSTALL_DIR:-$HOME/Applications}}"
app="$dest/$APP_NAME.app"
last="$here/build/.last-identity"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

"$here/scripts/build-app.sh" >/dev/null

prev() { [[ -f "$last" ]] && sed -n "s/^$1=//p" "$last" | head -1 || true; }
prev_app="$(prev app)"
prev_exe="$(prev executable)"
prev_cfg="$(prev config)"
prev_id="$(prev bundle)"

if [[ -n "$prev_app" && "$prev_app" != "$app" && -d "$prev_app" ]]; then
  [[ -n "$prev_exe" ]] && "$prev_app/Contents/MacOS/$prev_exe" --login-off >/dev/null 2>&1 || true
  [[ -n "$prev_exe" ]] && pkill -x "$prev_exe" >/dev/null 2>&1 || true
  "$lsregister" -u "$prev_app" >/dev/null 2>&1 || true
  rm -rf "$prev_app"
fi
if [[ -n "$prev_cfg" && "$prev_cfg" != "$CONFIG_DIR_NAME" && -d "$HOME/.config/$prev_cfg" && ! -e "$HOME/.config/$CONFIG_DIR_NAME" ]]; then
  ditto "$HOME/.config/$prev_cfg" "$HOME/.config/$CONFIG_DIR_NAME"
  chmod 700 "$HOME/.config/$CONFIG_DIR_NAME"
  find "$HOME/.config/$CONFIG_DIR_NAME" -type f -exec chmod 600 {} +
  print "Copied settings from ~/.config/$prev_cfg to ~/.config/$CONFIG_DIR_NAME"
fi

if [[ -d "$app" ]]; then
  old_id="$(defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)"
  old_exe="$(defaults read "$app/Contents/Info.plist" CFBundleExecutable 2>/dev/null || true)"
  if [[ -n "$old_id" && "$old_id" != "$BUNDLE_ID" && -n "$old_exe" ]]; then
    "$app/Contents/MacOS/$old_exe" --login-off >/dev/null 2>&1 || true
    prev_id="$old_id"
  fi
  [[ -n "$old_exe" && "$old_exe" != "$EXECUTABLE" ]] && pkill -x "$old_exe" >/dev/null 2>&1 || true
fi
pkill -x "$EXECUTABLE" 2>/dev/null || true
sleep 0.5
mkdir -p "$dest"
rm -rf "$app"
ditto "$here/build/$APP_NAME.app" "$app"
"$lsregister" -f "$app"
print -l "app=$app" "executable=$EXECUTABLE" "config=$CONFIG_DIR_NAME" "bundle=$BUNDLE_ID" > "$last"
open -g "$app" --args --background
print -r -- "installed: $app"
if [[ -n "$prev_id" && "$prev_id" != "$BUNDLE_ID" ]]; then
  print -r -- "The bundle ID changed ($prev_id → $BUNDLE_ID)."
fi
