#!/bin/bash
#
# Unit tests for the Safety Gate (gate_check).
#
# The Safety Gate is the single most important defense in this tool. Every path
# in the "must reject" table below MUST be rejected. If any one of them is ever
# allowed, the tool could delete system files or the user's personal folders.
#
# These tests source cleaner.sh in library mode (no main()) and call gate_check
# directly with a controlled HOME.
#
# The human-readable labels use "~/..." for readability; the actual path under
# test is always the second ("$HOME/...") argument.
# shellcheck disable=SC2088
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CLEANER="$HERE/../cleaner.sh"

# Controlled fake HOME so home-relative rejections are deterministic and never
# touch the real user's home.
export HOME="/tmp/cleaner_test_home"
rm -rf "$HOME"
mkdir -p "$HOME/Library/Caches"

# Load cleaner.sh as a library (must not run main()).
# shellcheck source=/dev/null
CLEANER_LIB_ONLY=1 source "$CLEANER"

pass=0
fail=0

expect_reject() { # $1 = description, $2 = path
  if gate_check "$2" >/dev/null 2>&1; then
    printf 'FAIL  should REJECT but allowed: %s  [%s]\n' "$1" "$2"
    fail=$((fail + 1))
  else
    printf 'ok    rejected: %s\n' "$1"
    pass=$((pass + 1))
  fi
}

expect_allow() { # $1 = description, $2 = path
  if gate_check "$2" >/dev/null 2>&1; then
    printf 'ok    allowed:  %s\n' "$1"
    pass=$((pass + 1))
  else
    printf 'FAIL  should ALLOW but rejected: %s  [%s]\n' "$1" "$2"
    fail=$((fail + 1))
  fi
}

echo "=== MUST REJECT: empty / relative / traversal ==="
expect_reject "empty string"                 ""
expect_reject "single space"                 " "
expect_reject "relative path"                "Library/Caches/com.microsoft.OneDrive"
expect_reject "parent traversal"             "../../etc"
expect_reject "traversal inside home"        "$HOME/Library/../../../etc"

echo "=== MUST REJECT: filesystem root and top-level system dirs ==="
expect_reject "root"                         "/"
expect_reject "/System"                      "/System"
expect_reject "/System/Library"             "/System/Library"
expect_reject "/usr"                         "/usr"
expect_reject "/usr/bin"                     "/usr/bin"
expect_reject "/bin"                         "/bin"
expect_reject "/sbin"                        "/sbin"
expect_reject "/etc"                         "/etc"
expect_reject "/etc/hosts"                   "/etc/hosts"
expect_reject "/var"                         "/var"
expect_reject "/private"                     "/private"
expect_reject "/private/etc/hosts"           "/private/etc/hosts"
expect_reject "/Library bare"                "/Library"
expect_reject "/Applications bare"           "/Applications"
expect_reject "/Volumes/External"            "/Volumes/External"
expect_reject "/opt"                         "/opt"

echo "=== MUST REJECT: user home and personal folders ==="
expect_reject "HOME bare"                    "$HOME"
expect_reject "HOME trailing slash"          "$HOME/"
expect_reject "HOME/Library bare"            "$HOME/Library"
expect_reject "HOME/Documents"               "$HOME/Documents"
expect_reject "HOME/Desktop"                 "$HOME/Desktop"
expect_reject "HOME/Downloads"               "$HOME/Downloads"
expect_reject "HOME/Pictures"                "$HOME/Pictures"
expect_reject "HOME/Movies"                  "$HOME/Movies"
expect_reject "HOME/Music"                   "$HOME/Music"
expect_reject "HOME/Public"                  "$HOME/Public"

echo "=== MUST REJECT: bare Library container dirs ==="
expect_reject "Library/Caches bare"                    "$HOME/Library/Caches"
expect_reject "Library/Preferences bare"               "$HOME/Library/Preferences"
expect_reject "Library/Application Support bare"       "$HOME/Library/Application Support"
expect_reject "Library/Containers bare"                "$HOME/Library/Containers"
expect_reject "Library/Group Containers bare"          "$HOME/Library/Group Containers"
expect_reject "Library/LaunchAgents bare"              "$HOME/Library/LaunchAgents"
expect_reject "Library/Logs bare"                      "$HOME/Library/Logs"
expect_reject "Library/CloudStorage bare"              "$HOME/Library/CloudStorage"
expect_reject "Library/HTTPStorages bare"              "$HOME/Library/HTTPStorages"
expect_reject "Library/Saved Application State bare"   "$HOME/Library/Saved Application State"

echo "=== MUST REJECT: iCloud / Apple-owned ==="
expect_reject "Mobile Documents"             "$HOME/Library/Mobile Documents"
expect_reject "com~apple~CloudDocs"          "$HOME/Library/Mobile Documents/com~apple~CloudDocs"
expect_reject "com.apple bundle"             "$HOME/Library/Caches/com.apple.Safari"

echo "=== MUST ALLOW: legitimate provider traces (OneDrive/Google/Nextcloud) ==="
expect_allow "OneDrive cache"                "$HOME/Library/Caches/com.microsoft.OneDrive"
expect_allow "OneDrive group container"      "$HOME/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"
expect_allow "OneDrive pref plist"           "$HOME/Library/Preferences/com.microsoft.OneDrive.plist"
expect_allow "OneDrive app bundle"           "/Applications/OneDrive.app"
expect_allow "OneDrive system daemon"        "/Library/LaunchDaemons/com.microsoft.OneDrive.plist"
expect_allow "OneDrive CloudStorage data"    "$HOME/Library/CloudStorage/OneDrive-Personal"
expect_allow "GoogleDrive support"           "$HOME/Library/Application Support/Google/DriveFS"
expect_allow "GoogleDrive app bundle"        "/Applications/Google Drive.app"
expect_allow "Nextcloud data folder"         "$HOME/Nextcloud"
expect_allow "Nextcloud app support"         "$HOME/Library/Application Support/Nextcloud"

echo "=== MUST ALLOW: newly added providers (Dropbox/Box/pCloud/MEGA) ==="
expect_allow "Dropbox app bundle"            "/Applications/Dropbox.app"
expect_allow "Dropbox app support"           "$HOME/Library/Application Support/Dropbox"
expect_allow "Dropbox hidden config"         "$HOME/.dropbox"
expect_allow "Dropbox helper tools (sudo)"   "/Library/DropboxHelperTools"
expect_allow "Box app support"               "$HOME/Library/Application Support/Box"
expect_allow "pCloud app bundle"             "/Applications/pCloud Drive.app"
expect_allow "MEGA app support"              "$HOME/Library/Application Support/Mega Limited"

echo "=== MUST REJECT: symlink whose target is a system path ==="
ln -s /System "$HOME/Library/Caches/evil.symlink" 2>/dev/null || true
expect_reject "symlink -> /System"           "$HOME/Library/Caches/evil.symlink"

echo
echo "-------------------------------------------"
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
rm -rf "$HOME"
[ "$fail" -eq 0 ]
