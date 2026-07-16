#!/bin/bash
#
# Integration test for the Scanner + Executor, run entirely inside a disposable
# fake HOME under /tmp. This NEVER touches the real home directory or the real
# Trash: deletions are redirected to a sandbox "trash" dir via CLEANER_TRASH_DIR.
#
# It verifies:
#   1. The scanner finds a provider's real traces.
#   2. Synced DATA folders are DETECTED and REPORTED but NEVER deleted — even if
#      the user answers "y" (the data-wipe feature was removed on purpose).
#   3. Decoys (personal files, Apple files, a DIFFERENT provider) are untouched.
#   4. execute_removal moves ONLY the app/traces to the sandbox trash.
#   5. Newly added providers (e.g. Dropbox) are registered and scan correctly.
#
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CLEANER="$HERE/../cleaner.sh"

SANDBOX="/tmp/cleaner_sandbox_$$"
export HOME="$SANDBOX/home"
export CLEANER_TRASH_DIR="$SANDBOX/trash"
export CLEANER_SKIP_KEYCHAIN=1
export CLEANER_SKIP_APPQUIT=1
export CLEANER_SKIP_EXTENSIONS=1
export CLEANER_LOG="$SANDBOX/cleaner.log"

rm -rf "$SANDBOX"
mkdir -p "$HOME" "$CLEANER_TRASH_DIR"

pass=0
fail=0
ok()  { printf 'ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

in_array() { # $1 = needle, rest = haystack
  local needle="$1"; shift
  local x
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

mkfile() { mkdir -p "$(dirname "$1")"; : >"$1"; }
mkdirp() { mkdir -p "$1"; : >"$1/content"; }

# ---- Fake OneDrive traces ---------------------------------------------------
mkfile "$HOME/Library/Preferences/com.microsoft.OneDrive.plist"
mkdirp "$HOME/Library/Caches/com.microsoft.OneDrive"
mkdirp "$HOME/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"
mkdirp "$HOME/Library/Application Support/OneDrive"
mkfile "$HOME/Library/LaunchAgents/com.microsoft.OneDrive.plist"

# ---- Synced DATA folder (must be detected but NEVER deleted) ----------------
mkdirp "$HOME/Library/CloudStorage/OneDrive-Personal"

# ---- Decoys that MUST remain untouched -------------------------------------
mkfile "$HOME/Documents/important.txt"
mkfile "$HOME/Library/Preferences/com.apple.finder.plist"
mkdirp "$HOME/Library/Caches/com.google.Chrome"

# ---- Fake Dropbox install (newly added provider) ---------------------------
mkdirp "$HOME/Applications/Dropbox.app"
mkdirp "$HOME/Library/Application Support/Dropbox"
mkfile "$HOME/Library/Preferences/com.getdropbox.dropbox.plist"
mkdirp "$HOME/Dropbox"   # Dropbox DATA folder (must be detected, never deleted)

# ---- Load library ----------------------------------------------------------
# shellcheck source=/dev/null
CLEANER_LIB_ONLY=1 source "$CLEANER"

echo "=== Registry: new providers are known ==="
for prov in onedrive googledrive nextcloud dropbox box pcloud mega; do
  if validate_provider "$prov"; then ok "provider registered: $prov"; else bad "provider MISSING: $prov"; fi
done

echo "=== SCAN: onedrive ==="
scan_provider onedrive

expected_auto="\
$HOME/Library/Preferences/com.microsoft.OneDrive.plist
$HOME/Library/Caches/com.microsoft.OneDrive
$HOME/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite
$HOME/Library/Application Support/OneDrive
$HOME/Library/LaunchAgents/com.microsoft.OneDrive.plist"

while IFS= read -r want; do
  if in_array "$want" "${SCAN_AUTO[@]}"; then ok "auto contains: ${want#"$HOME"/}"
  else bad "auto MISSING: $want"; fi
done <<EOF
$expected_auto
EOF

echo "=== Classification: DATA detected, not in AUTO ==="
if in_array "$HOME/Library/CloudStorage/OneDrive-Personal" "${SCAN_DATA[@]}"; then
  ok "data folder detected as DATA"
else bad "data folder NOT detected"; fi
if in_array "$HOME/Library/CloudStorage/OneDrive-Personal" "${SCAN_AUTO[@]}"; then
  bad "DATA folder wrongly in AUTO list"
else ok "DATA folder not in AUTO list"; fi

for decoy in \
  "$HOME/Documents/important.txt" \
  "$HOME/Library/Preferences/com.apple.finder.plist" \
  "$HOME/Library/Caches/com.google.Chrome"; do
  if in_array "$decoy" "${SCAN_AUTO[@]}"; then bad "decoy wrongly in AUTO: $decoy"
  else ok "decoy excluded: ${decoy#"$HOME"/}"; fi
done

echo "=== EXECUTE onedrive: even answering 'y' must NOT delete data ==="
# Feed 'y' repeatedly; the data-wipe feature was removed, so data must survive.
printf 'y\ny\ny\ny\n' | execute_removal onedrive 0 >/dev/null 2>&1

all_gone=1
for p in "${SCAN_AUTO[@]}"; do
  if [ -e "$p" ] || [ -L "$p" ]; then all_gone=0; bad "trace still present: $p"; fi
done
[ "$all_gone" -eq 1 ] && ok "all app/traces removed"

if [ -e "$HOME/Library/CloudStorage/OneDrive-Personal" ]; then
  ok "DATA folder SURVIVED execute_removal (even with 'y')"
else
  bad "DATA folder was DELETED — data-wipe path still exists!"
fi

echo "=== Decoys survived ==="
for survivor in \
  "$HOME/Documents/important.txt" \
  "$HOME/Library/Preferences/com.apple.finder.plist" \
  "$HOME/Library/Caches/com.google.Chrome"; do
  if [ -e "$survivor" ]; then ok "survived: ${survivor#"$HOME"/}"
  else bad "WRONGLY REMOVED: $survivor"; fi
done

echo "=== SCAN: dropbox (new provider) ==="
scan_provider dropbox
if in_array "$HOME/Library/Application Support/Dropbox" "${SCAN_AUTO[@]}"; then
  ok "dropbox app-support trace found"
else bad "dropbox app-support trace MISSING"; fi
if in_array "$HOME/Applications/Dropbox.app" "${SCAN_AUTO[@]}"; then
  ok "dropbox app bundle found"
else bad "dropbox app bundle MISSING"; fi
if in_array "$HOME/Dropbox" "${SCAN_DATA[@]}"; then
  ok "dropbox DATA folder detected"
else bad "dropbox DATA folder NOT detected"; fi
if in_array "$HOME/Dropbox" "${SCAN_AUTO[@]}"; then
  bad "dropbox DATA wrongly in AUTO"
else ok "dropbox DATA not in AUTO"; fi

echo
echo "-------------------------------------------"
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
rm -rf "$SANDBOX"
[ "$fail" -eq 0 ]
