identity_root="${${(%):-%x}:A:h:h}"
unset APP_NAME EXECUTABLE BUNDLE_ID PUBLISHER GITHUB_OWNER GITHUB_REPO CONFIG_DIR_NAME SPARKLE_ACCOUNT SPARKLE_PUBLIC_KEY SIGN_IDENTITY VERSION BUILD
source "$identity_root/app.env"
identity_local="$identity_root/app.local.env"
if [[ -f "$identity_local" ]]; then
  if [[ "${IDENTITY_RELEASE:-0}" == 1 ]]; then
    SPARKLE_HOME="$(zsh -fc 'source "$1"; print -r -- "${SPARKLE_HOME:-}"' _ "$identity_local")"
    [[ -n "$SPARKLE_HOME" ]] || unset SPARKLE_HOME
  else
    source "$identity_local"
  fi
fi

: ${EXECUTABLE:=$APP_NAME}
owner_lc="${(L)GITHUB_OWNER}"
[[ -n "${BUNDLE_ID:-}" ]] || BUNDLE_ID="io.github.$owner_lc.${(L)GITHUB_REPO}"
[[ -n "${CONFIG_DIR_NAME:-}" ]] || CONFIG_DIR_NAME="${(L)APP_NAME}"
[[ -n "${SPARKLE_ACCOUNT:-}" ]] || SPARKLE_ACCOUNT="${(L)GITHUB_REPO}"
[[ -n "${SIGN_IDENTITY:-}" ]] || SIGN_IDENTITY="$PUBLISHER Apps"
REPO_URL="https://github.com/$GITHUB_OWNER/$GITHUB_REPO"
SITE_URL="$REPO_URL"
FEED_URL="$REPO_URL/releases/latest/download/appcast.xml"
ZIP_BASE="${APP_NAME// /-}"
DOWNLOAD_URL="$REPO_URL/releases/latest/download/$ZIP_BASE.dmg"

identity_fail() { print -u2 -r -- "app.env: $1"; return 1; }
identity_check() {
  [[ "$APP_NAME" =~ '^[A-Za-z0-9][A-Za-z0-9 ._-]*$' ]] || identity_fail "APP_NAME '$APP_NAME' may use letters, digits, space, . _ -" || return 1
  [[ "$EXECUTABLE" =~ '^[A-Za-z0-9._-]+$' ]] || identity_fail "EXECUTABLE '$EXECUTABLE' may use letters, digits, . _ -" || return 1
  [[ "$GITHUB_OWNER" =~ '^[A-Za-z0-9-]+$' ]] || identity_fail "GITHUB_OWNER '$GITHUB_OWNER' may use letters, digits, -" || return 1
  [[ "$GITHUB_REPO" =~ '^[A-Za-z0-9._-]+$' ]] || identity_fail "GITHUB_REPO '$GITHUB_REPO' may use letters, digits, . _ -" || return 1
  [[ "$BUNDLE_ID" =~ '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' ]] || identity_fail "BUNDLE_ID '$BUNDLE_ID' must look like org.example.app" || return 1
  [[ "$PUBLISHER" =~ '^[A-Za-z0-9][A-Za-z0-9 ._,()-]*$' ]] || identity_fail "PUBLISHER '$PUBLISHER' may use letters, digits, space, . _ , ( ) -" || return 1
  [[ "$SIGN_IDENTITY" =~ '^[A-Za-z0-9][A-Za-z0-9 ._,()-]*$' ]] || identity_fail "SIGN_IDENTITY '$SIGN_IDENTITY' has invalid characters" || return 1
  [[ "$CONFIG_DIR_NAME" =~ '^[A-Za-z0-9._-]+$' ]] || identity_fail "CONFIG_DIR_NAME '$CONFIG_DIR_NAME' may use letters, digits, . _ -" || return 1
  [[ "$SPARKLE_ACCOUNT" =~ '^[A-Za-z0-9._-]+$' ]] || identity_fail "SPARKLE_ACCOUNT '$SPARKLE_ACCOUNT' may use letters, digits, . _ -" || return 1
  [[ "$SPARKLE_PUBLIC_KEY" =~ '^[A-Za-z0-9+/=]+$' ]] || identity_fail "SPARKLE_PUBLIC_KEY must be the base64 key from Sparkle's generate_keys" || return 1
}
identity_placeholders() {
  local found=()
  [[ "$GITHUB_OWNER" == YOUR-ORG ]] && found+=("GITHUB_OWNER (the GitHub user or organization that hosts the repo)")
  [[ "$PUBLISHER" == "Your Name or Org" ]] && found+=("PUBLISHER (the name shown in the license and signing certificate)")
  (( ${#found} )) || return 1
  print -r -- "${(F)found}"
}
identity_check
export APP_NAME EXECUTABLE BUNDLE_ID PUBLISHER GITHUB_OWNER GITHUB_REPO CONFIG_DIR_NAME SPARKLE_ACCOUNT \
  SPARKLE_PUBLIC_KEY SIGN_IDENTITY REPO_URL SITE_URL FEED_URL ZIP_BASE DOWNLOAD_URL
[[ -n "${SPARKLE_HOME:-}" ]] && export SPARKLE_HOME
true
