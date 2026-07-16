#!/bin/bash
#
# cleaner.sh — Safe, interactive removal of third-party cloud storage providers
#              from macOS (OneDrive, Google Drive, Nextcloud, Dropbox, Box,
#              pCloud, MEGA).
#
# SAFETY FIRST. This tool moves files to the Trash (recoverable). It is
# engineered so that it is *impossible* to delete macOS system folders or the
# user's personal folders. Every path it acts on must pass the Safety Gate
# (gate_check), and the Executor acts ONLY on the frozen list produced by the
# dry-run Scanner — what you confirm is exactly what is removed.
#
# It removes the app and its traces (prefs, caches, containers, launch items,
# Keychain items). It does NOT delete your synced DATA folders: those hold your
# real files and are usually macOS "File Provider" folders that the OS refuses to
# force-delete. The tool detects and reports them, with guidance to remove them
# from inside the provider app (sign out / "Unlink this Mac").
#
# Usage:
#   ./cleaner.sh                 Interactive menu (dry-run, then confirm, then remove)
#   ./cleaner.sh --dry-run       Scan and report only; never modifies anything
#   ./cleaner.sh --provider ID   Target one provider (see IDs below)
#   ./cleaner.sh --scan-all      Report across all detected providers, no deletion
#   ./cleaner.sh --yes           Skip the typed confirmation for app/traces
#   ./cleaner.sh --help
#
#   Provider IDs: onedrive googledrive nextcloud dropbox box pcloud mega
#
# Test hooks (env vars):
#   CLEANER_LIB_ONLY=1      source the functions without running main()
#   CLEANER_TRASH_DIR=DIR   move items here instead of the real Trash
#   CLEANER_QUARANTINE_DIR  sudo-quarantine target dir
#   CLEANER_SKIP_KEYCHAIN   do not query the Keychain
#   CLEANER_SKIP_APPQUIT    do not quit running apps
#   CLEANER_SKIP_EXTENSIONS do not touch pluginkit extensions
#   CLEANER_LOG=FILE        log file path

set -u

# Sequence counter used to avoid basename collisions inside CLEANER_TRASH_DIR.
CLEANER_TRASH_SEQ=0

# ===========================================================================
# SECTION 1 — Safety Gate
# ===========================================================================

# Minimum number of path components below root. "/Applications/OneDrive.app" has
# 2, "/Library" has 1. Fewer than 2 is a top-level dir: never a valid target.
readonly GATE_MIN_DEPTH=2

gate_exact_blocklist() {
  # System roots
  cat <<'EOF'
/System
/usr
/bin
/sbin
/etc
/var
/tmp
/private
/dev
/opt
/cores
/Network
/Volumes
/Library
/Applications
/Users
EOF
  # User home + personal folders + bare Library containers
  cat <<EOF
$HOME
$HOME/Library
$HOME/Documents
$HOME/Desktop
$HOME/Downloads
$HOME/Pictures
$HOME/Movies
$HOME/Music
$HOME/Public
$HOME/Sites
$HOME/Applications
$HOME/Library/Caches
$HOME/Library/Preferences
$HOME/Library/Application Support
$HOME/Library/Containers
$HOME/Library/Group Containers
$HOME/Library/LaunchAgents
$HOME/Library/Logs
$HOME/Library/CloudStorage
$HOME/Library/HTTPStorages
$HOME/Library/Saved Application State
$HOME/Library/WebKit
$HOME/Library/Cookies
EOF
}

# Prefixes that are always system-owned. /tmp is intentionally NOT here so the
# test sandbox works; providers never store meaningful traces in /tmp.
gate_prefix_blocklist() {
  cat <<'EOF'
/System/
/usr/
/bin/
/sbin/
/etc/
/var/
/private/
/dev/
/cores/
/Network/
/Volumes/
/opt/
EOF
}

# is_blocked_path <path> — true (0) if the path is a protected system/home path.
is_blocked_path() {
  local p="$1" entry

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    [ "$p" = "$entry" ] && return 0
  done <<EOF
$(gate_exact_blocklist)
EOF

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$p/" in
      "$entry"*) return 0 ;;
    esac
  done <<EOF
$(gate_prefix_blocklist)
EOF

  case "$p" in
    *"Mobile Documents"*|*"com.apple."*|*"com~apple~"*|*"CloudDocs"*|*iCloud*)
      return 0 ;;
  esac

  return 1
}

# gate_check <path> — 0 if safe to act on, non-zero (reason on stderr) if rejected.
gate_check() {
  local p="${1:-}"

  if [ -z "$p" ] || [ "$p" = " " ]; then
    echo "gate: reject empty path" >&2; return 1
  fi

  case "$p" in
    ".."|"../"*|*"/.."|*"/../"*)
      echo "gate: reject path traversal: $p" >&2; return 1 ;;
  esac

  case "$p" in
    /*) : ;;
    *) echo "gate: reject non-absolute path: $p" >&2; return 1 ;;
  esac

  while [ "${#p}" -gt 1 ]; do
    case "$p" in
      */) p="${p%/}" ;;
      *) break ;;
    esac
  done

  if [ "$p" = "/" ]; then
    echo "gate: reject filesystem root" >&2; return 1
  fi

  local rel depth
  rel="${p#/}"
  depth="$(printf '%s' "$rel" | awk -F/ '{print NF}')"
  if [ "$depth" -lt "$GATE_MIN_DEPTH" ]; then
    echo "gate: reject shallow path (depth $depth): $p" >&2; return 1
  fi

  if is_blocked_path "$p"; then
    echo "gate: reject protected path: $p" >&2; return 1
  fi

  # Symlink guard: if the leaf itself is a symlink pointing at a system path,
  # reject. We do NOT resolve benign ancestor symlinks (e.g. /tmp -> /private/tmp).
  if [ -L "$p" ]; then
    local target tdir tbase rt
    target="$(readlink "$p")"
    case "$target" in
      /*) : ;;
      *) target="$(dirname "$p")/$target" ;;
    esac
    tdir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)"
    tbase="$(basename "$target")"
    if [ -n "$tdir" ]; then
      if [ "$tdir" = "/" ]; then rt="/$tbase"; else rt="$tdir/$tbase"; fi
      if is_blocked_path "$rt"; then
        echo "gate: reject symlink -> system target: $p -> $rt" >&2; return 1
      fi
    fi
  fi

  return 0
}

# ===========================================================================
# SECTION 2 — Provider Registry (pure data)
# ===========================================================================

provider_ids() { printf '%s\n' onedrive googledrive nextcloud dropbox box pcloud mega; }

provider_name() {
  case "$1" in
    onedrive)    echo "Microsoft OneDrive" ;;
    googledrive) echo "Google Drive" ;;
    nextcloud)   echo "Nextcloud" ;;
    dropbox)     echo "Dropbox" ;;
    box)         echo "Box" ;;
    pcloud)      echo "pCloud" ;;
    mega)        echo "MEGA (MEGAsync)" ;;
    *)           echo "$1" ;;
  esac
}

validate_provider() {
  case "$1" in
    onedrive|googledrive|nextcloud|dropbox|box|pcloud|mega) return 0 ;;
    *) return 1 ;;
  esac
}

# provider_globs <id> <category>
#   category: app | trace | daemon | data
#   Emits one glob pattern per line. Patterns may contain '*' and spaces; they
#   are expanded later by scan_collect (NOT here).
provider_globs() {
  local id="$1" cat="$2"
  case "$id:$cat" in
    # ---------------- OneDrive ----------------
    onedrive:app)
      printf '%s\n' \
        "/Applications/OneDrive.app" \
        "$HOME/Applications/OneDrive.app" ;;
    onedrive:trace)
      printf '%s\n' \
        "$HOME/Library/Preferences/com.microsoft.OneDrive.plist" \
        "$HOME/Library/Preferences/com.microsoft.OneDriveUpdater.plist" \
        "$HOME/Library/Preferences/com.microsoft.OneDriveStandaloneUpdater.plist" \
        "$HOME/Library/Preferences/ByHost/com.microsoft.OneDrive*.plist" \
        "$HOME/Library/Caches/com.microsoft.OneDrive" \
        "$HOME/Library/Caches/com.microsoft.OneDriveUpdater" \
        "$HOME/Library/Caches/com.microsoft.OneDriveStandaloneUpdater" \
        "$HOME/Library/HTTPStorages/com.microsoft.OneDrive*" \
        "$HOME/Library/Containers/com.microsoft.OneDrive*" \
        "$HOME/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite" \
        "$HOME/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite" \
        "$HOME/Library/Group Containers/UBF8T346G9.OfficeOneDriveSyncIntegration" \
        "$HOME/Library/Application Support/OneDrive" \
        "$HOME/Library/Application Support/com.microsoft.OneDrive*" \
        "$HOME/Library/Logs/OneDrive" \
        "$HOME/Library/Saved Application State/com.microsoft.OneDrive.savedState" \
        "$HOME/Library/LaunchAgents/com.microsoft.OneDrive*.plist" \
        "$HOME/Library/WebKit/com.microsoft.OneDrive*" ;;
    onedrive:daemon)
      printf '%s\n' \
        "/Library/LaunchDaemons/com.microsoft.OneDrive*.plist" \
        "/Library/LaunchAgents/com.microsoft.OneDrive*.plist" ;;
    onedrive:data)
      printf '%s\n' \
        "$HOME/Library/CloudStorage/OneDrive-*" \
        "$HOME/OneDrive" \
        "$HOME/OneDrive - *" ;;

    # ---------------- Google Drive ----------------
    googledrive:app)
      printf '%s\n' \
        "/Applications/Google Drive.app" \
        "$HOME/Applications/Google Drive.app" ;;
    googledrive:trace)
      printf '%s\n' \
        "$HOME/Library/Preferences/com.google.drivefs*.plist" \
        "$HOME/Library/Caches/com.google.drivefs" \
        "$HOME/Library/Caches/com.google.drivefs*" \
        "$HOME/Library/HTTPStorages/com.google.drivefs*" \
        "$HOME/Library/Containers/com.google.drivefs*" \
        "$HOME/Library/Group Containers/*.com.google.drivefs" \
        "$HOME/Library/Application Support/Google/DriveFS" \
        "$HOME/Library/Logs/Google/DriveFS" \
        "$HOME/Library/Saved Application State/com.google.drivefs*.savedState" \
        "$HOME/Library/LaunchAgents/com.google.drivefs*.plist" ;;
    googledrive:daemon)
      printf '%s\n' \
        "/Library/LaunchDaemons/com.google.drivefs*.plist" \
        "/Library/LaunchAgents/com.google.drivefs*.plist" ;;
    googledrive:data)
      printf '%s\n' \
        "$HOME/Library/CloudStorage/GoogleDrive-*" \
        "$HOME/Google Drive" ;;

    # ---------------- Nextcloud ----------------
    nextcloud:app)
      printf '%s\n' \
        "/Applications/Nextcloud.app" \
        "$HOME/Applications/Nextcloud.app" ;;
    nextcloud:trace)
      printf '%s\n' \
        "$HOME/Library/Preferences/com.nextcloud.desktopclient*.plist" \
        "$HOME/Library/Preferences/Nextcloud" \
        "$HOME/Library/Caches/com.nextcloud.desktopclient" \
        "$HOME/Library/Caches/Nextcloud" \
        "$HOME/Library/HTTPStorages/com.nextcloud.desktopclient*" \
        "$HOME/Library/Containers/com.nextcloud.desktopclient*" \
        "$HOME/Library/Application Support/Nextcloud" \
        "$HOME/Library/Logs/Nextcloud" \
        "$HOME/Library/Saved Application State/com.nextcloud.desktopclient.savedState" \
        "$HOME/Library/LaunchAgents/com.nextcloud.desktopclient*.plist" ;;
    nextcloud:daemon)
      printf '%s\n' \
        "/Library/LaunchDaemons/com.nextcloud.desktopclient*.plist" ;;
    nextcloud:data)
      printf '%s\n' \
        "$HOME/Nextcloud" ;;

    # ---------------- Dropbox ----------------
    dropbox:app)
      printf '%s\n' \
        "/Applications/Dropbox.app" \
        "$HOME/Applications/Dropbox.app" ;;
    dropbox:trace)
      printf '%s\n' \
        "$HOME/Library/Preferences/com.getdropbox.dropbox.plist" \
        "$HOME/Library/Preferences/com.dropbox.*.plist" \
        "$HOME/Library/Caches/com.getdropbox.dropbox" \
        "$HOME/Library/Caches/com.dropbox.*" \
        "$HOME/Library/HTTPStorages/com.getdropbox.dropbox*" \
        "$HOME/Library/Containers/com.getdropbox.dropbox*" \
        "$HOME/Library/Containers/com.dropbox.*" \
        "$HOME/Library/Group Containers/*.com.getdropbox.dropbox" \
        "$HOME/Library/Group Containers/*.com.dropbox.*" \
        "$HOME/Library/Application Support/Dropbox" \
        "$HOME/Library/Application Support/FinderLoadBundle" \
        "$HOME/Library/Saved Application State/com.getdropbox.dropbox.savedState" \
        "$HOME/Library/LaunchAgents/com.getdropbox.dropbox*.plist" \
        "$HOME/Library/LaunchAgents/com.dropbox.*.plist" \
        "$HOME/.dropbox" \
        "$HOME/.dropbox-master" ;;
    dropbox:daemon)
      printf '%s\n' \
        "/Library/DropboxHelperTools" \
        "/Library/LaunchDaemons/com.getdropbox.dropbox*.plist" \
        "/Library/LaunchDaemons/com.dropbox.*.plist" ;;
    dropbox:data)
      printf '%s\n' \
        "$HOME/Dropbox" \
        "$HOME/Dropbox (*" \
        "$HOME/Library/CloudStorage/Dropbox*" ;;

    # ---------------- Box (Box Drive) ----------------
    box:app)
      printf '%s\n' \
        "/Applications/Box.app" \
        "/Applications/Box Sync.app" \
        "$HOME/Applications/Box.app" ;;
    box:trace)
      printf '%s\n' \
        "$HOME/Library/Preferences/com.box.desktop*.plist" \
        "$HOME/Library/Caches/com.box.desktop" \
        "$HOME/Library/Caches/com.box.desktop*" \
        "$HOME/Library/HTTPStorages/com.box.desktop*" \
        "$HOME/Library/Containers/com.box.desktop*" \
        "$HOME/Library/Group Containers/*.com.box.desktop" \
        "$HOME/Library/Application Support/Box" \
        "$HOME/Library/Logs/Box" \
        "$HOME/Library/Saved Application State/com.box.desktop.savedState" \
        "$HOME/Library/LaunchAgents/com.box.desktop*.plist" ;;
    box:daemon)
      printf '%s\n' \
        "/Library/LaunchDaemons/com.box.desktop*.plist" ;;
    box:data)
      printf '%s\n' \
        "$HOME/Library/CloudStorage/Box-Box" \
        "$HOME/Box" \
        "$HOME/Box Sync" ;;

    # ---------------- pCloud ----------------
    pcloud:app)
      printf '%s\n' \
        "/Applications/pCloud Drive.app" \
        "$HOME/Applications/pCloud Drive.app" ;;
    pcloud:trace)
      printf '%s\n' \
        "$HOME/Library/Preferences/com.pcloud.pcloud*.plist" \
        "$HOME/Library/Caches/com.pcloud.pcloud*" \
        "$HOME/Library/HTTPStorages/com.pcloud.pcloud*" \
        "$HOME/Library/Containers/com.pcloud.pcloud*" \
        "$HOME/Library/Group Containers/*.com.pcloud.pcloud*" \
        "$HOME/Library/Application Support/pCloud*" \
        "$HOME/Library/Saved Application State/com.pcloud.pcloud*.savedState" \
        "$HOME/Library/LaunchAgents/com.pcloud.pcloud*.plist" ;;
    pcloud:daemon)
      printf '%s\n' \
        "/Library/LaunchDaemons/com.pcloud.pcloud*.plist" ;;
    pcloud:data)
      printf '%s\n' \
        "$HOME/pCloud Drive" \
        "$HOME/Library/CloudStorage/pCloud*" ;;

    # ---------------- MEGA (MEGAsync) ----------------
    mega:app)
      printf '%s\n' \
        "/Applications/MEGAsync.app" \
        "$HOME/Applications/MEGAsync.app" ;;
    mega:trace)
      printf '%s\n' \
        "$HOME/Library/Preferences/mega.mac.plist" \
        "$HOME/Library/Caches/mega.mac" \
        "$HOME/Library/HTTPStorages/mega.mac*" \
        "$HOME/Library/Containers/mega.mac*" \
        "$HOME/Library/Application Support/Mega Limited" \
        "$HOME/Library/Application Support/MEGAsync" \
        "$HOME/Library/Saved Application State/mega.mac.savedState" \
        "$HOME/Library/LaunchAgents/mega.mac*.plist" ;;
    mega:daemon)
      printf '%s\n' \
        "/Library/LaunchDaemons/mega.mac*.plist" ;;
    mega:data)
      printf '%s\n' \
        "$HOME/MEGA" \
        "$HOME/MEGAsync" ;;

    *) : ;;
  esac
}

# provider_keychain_labels <id> — Keychain labels/services to search for.
provider_keychain_labels() {
  case "$1" in
    onedrive)    printf '%s\n' "OneDrive" "com.microsoft.OneDrive" ;;
    googledrive) printf '%s\n' "Google Drive" "drivefs" "com.google.drivefs" ;;
    nextcloud)   printf '%s\n' "Nextcloud" "com.nextcloud.desktopclient" ;;
    dropbox)     printf '%s\n' "Dropbox" "com.getdropbox.dropbox" ;;
    box)         printf '%s\n' "Box" "com.box.desktop" ;;
    pcloud)      printf '%s\n' "pCloud" "com.pcloud.pcloud" ;;
    mega)        printf '%s\n' "MEGA" "MEGAsync" "mega.mac" ;;
  esac
}

# provider_processes <id> — app process names to quit.
provider_processes() {
  case "$1" in
    onedrive)    printf '%s\n' "OneDrive" ;;
    googledrive) printf '%s\n' "Google Drive" ;;
    nextcloud)   printf '%s\n' "Nextcloud" ;;
    dropbox)     printf '%s\n' "Dropbox" ;;
    box)         printf '%s\n' "Box" ;;
    pcloud)      printf '%s\n' "pCloud Drive" ;;
    mega)        printf '%s\n' "MEGAsync" ;;
  esac
}

# provider_extension_ids <id> — Finder Sync / File Provider extension bundle ids.
provider_extension_ids() {
  case "$1" in
    onedrive)    printf '%s\n' "com.microsoft.OneDrive.FinderSync" "com.microsoft.OneDrive.FileProvider" "com.microsoft.OneDrive-mac.FileProvider" ;;
    googledrive) printf '%s\n' "com.google.drivefs.findersync" "com.google.drivefs.fpext" ;;
    nextcloud)   printf '%s\n' "com.nextcloud.desktopclient.FinderSyncExt" ;;
    dropbox)     printf '%s\n' "com.getdropbox.dropbox.garcon" "com.getdropbox.dropbox.fileprovider" ;;
    box)         printf '%s\n' "com.box.desktop.findersync" "com.box.desktop.fileprovider" ;;
    pcloud)      printf '%s\n' "com.pcloud.pcloud.macos.fileprovider" ;;
    mega)        printf '%s\n' "mega.mac.MEGAShellExtFinder" ;;
  esac
}

# ===========================================================================
# SECTION 3 — Utilities
# ===========================================================================

log() {
  [ -n "${CLEANER_LOG:-}" ] && printf '%s\n' "$1" >>"$CLEANER_LOG" 2>/dev/null || true
}

path_size() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

# scan_collect <id> <category>
#   Expands each provider glob, keeps only paths that EXIST and pass gate_check.
scan_collect() {
  local id="$1" cat="$2" pat m oldIFS
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    oldIFS="$IFS"; IFS=
    shopt -s nullglob 2>/dev/null
    for m in $pat; do
      if { [ -e "$m" ] || [ -L "$m" ]; } && gate_check "$m" >/dev/null 2>&1; then
        printf '%s\n' "$m"
      fi
    done
    shopt -u nullglob 2>/dev/null
    IFS="$oldIFS"
  done <<EOF
$(provider_globs "$id" "$cat")
EOF
}

# ===========================================================================
# SECTION 4 — Scanner (produces the frozen list)
# ===========================================================================

# scan_provider <id> — populates SCAN_AUTO, SCAN_SUDO, SCAN_DATA, SCAN_KEYCHAIN.
#   SCAN_DATA is DETECTED FOR REPORTING ONLY — it is never a delete target.
scan_provider() {
  local id="$1" line
  SCAN_AUTO=(); SCAN_SUDO=(); SCAN_DATA=(); SCAN_KEYCHAIN=()

  while IFS= read -r line; do
    [ -n "$line" ] && SCAN_AUTO+=("$line")
  done < <( { scan_collect "$id" app; scan_collect "$id" trace; } | awk 'NF && !seen[$0]++' )

  while IFS= read -r line; do
    [ -n "$line" ] && SCAN_SUDO+=("$line")
  done < <( scan_collect "$id" daemon | awk 'NF && !seen[$0]++' )

  while IFS= read -r line; do
    [ -n "$line" ] && SCAN_DATA+=("$line")
  done < <( scan_collect "$id" data | awk 'NF && !seen[$0]++' )

  scan_keychain "$id"
}

scan_keychain() {
  local id="$1" label
  SCAN_KEYCHAIN=()
  [ -n "${CLEANER_SKIP_KEYCHAIN:-}" ] && return 0
  command -v security >/dev/null 2>&1 || return 0
  while IFS= read -r label; do
    [ -z "$label" ] && continue
    if security find-generic-password -l "$label" >/dev/null 2>&1 \
       || security find-internet-password -l "$label" >/dev/null 2>&1; then
      SCAN_KEYCHAIN+=("$label")
    fi
  done <<EOF
$(provider_keychain_labels "$id")
EOF
}

# provider_present <id> — true if any app/trace/data is found for the provider.
provider_present() {
  local id="$1" out
  out="$( { scan_collect "$id" app; scan_collect "$id" trace; scan_collect "$id" data; } | head -n1 )"
  [ -n "$out" ]
}

detect_installed() {
  local id
  while IFS= read -r id; do
    provider_present "$id" && printf '%s\n' "$id"
  done <<EOF
$(provider_ids)
EOF
}

# ===========================================================================
# SECTION 5 — Reporter
# ===========================================================================

report_list() { # $1 = header, rest = items
  local header="$1"; shift
  [ "$#" -eq 0 ] && return 0
  echo "  $header"
  local p
  for p in "$@"; do
    printf '    - %-6s %s\n' "$(path_size "$p")" "${p/#$HOME/~}"
  done
}

report_scan() {
  local id="$1"
  echo
  echo "===================================================================="
  echo "  Scan report for: $(provider_name "$id")"
  echo "===================================================================="

  if [ "${#SCAN_AUTO[@]}" -eq 0 ] && [ "${#SCAN_SUDO[@]}" -eq 0 ] \
     && [ "${#SCAN_DATA[@]}" -eq 0 ] && [ "${#SCAN_KEYCHAIN[@]}" -eq 0 ]; then
    echo "  Nothing found. This provider does not appear to be installed."
    return 0
  fi

  [ "${#SCAN_AUTO[@]}" -gt 0 ] && report_list "App & traces (will be moved to Trash):" "${SCAN_AUTO[@]}"
  [ "${#SCAN_SUDO[@]}" -gt 0 ] && report_list "System items (need sudo):" "${SCAN_SUDO[@]}"
  if [ "${#SCAN_KEYCHAIN[@]}" -gt 0 ]; then
    echo "  Keychain items:"
    local k
    for k in "${SCAN_KEYCHAIN[@]}"; do printf '    - %s\n' "$k"; done
  fi
  if [ "${#SCAN_DATA[@]}" -gt 0 ]; then
    echo
    echo "  ---- Synced DATA folders — NOT removed by this tool ----"
    local d
    for d in "${SCAN_DATA[@]}"; do
      printf '    - %-6s %s\n' "$(path_size "$d")" "${d/#$HOME/~}"
    done
    echo "    These hold YOUR real files and are usually macOS File Provider"
    echo "    folders that the OS refuses to force-delete. To remove one, open"
    echo "    the provider app, sign out / \"Unlink this Mac\", then delete it."
  fi
}

# ===========================================================================
# SECTION 6 — Executor
# ===========================================================================

# trash_path <path> — move ONE path to the Trash (or CLEANER_TRASH_DIR in tests).
# Re-checks the Safety Gate at the last moment (defense in depth).
trash_path() {
  local p="$1"
  [ -e "$p" ] || [ -L "$p" ] || return 0
  if ! gate_check "$p" >/dev/null 2>&1; then
    log "REFUSED by gate: $p"
    echo "  REFUSED (gate): $p" >&2
    return 1
  fi
  if [ -n "${CLEANER_TRASH_DIR:-}" ]; then
    mkdir -p "$CLEANER_TRASH_DIR"
    local base dest
    base="$(basename "$p")"
    dest="$CLEANER_TRASH_DIR/$base"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      CLEANER_TRASH_SEQ=$((CLEANER_TRASH_SEQ + 1))
      dest="$CLEANER_TRASH_DIR/$base.$CLEANER_TRASH_SEQ"
    fi
    if mv "$p" "$dest" 2>/dev/null; then
      log "TRASHED $p -> $dest"
    else
      log "FAILED to move $p"; return 1
    fi
  else
    if osascript -e "tell application \"Finder\" to delete (POSIX file \"$p\")" >/dev/null 2>&1; then
      log "TRASHED (Finder) $p"
    else
      log "FAILED to trash $p"; echo "  Could not trash: $p" >&2; return 1
    fi
  fi
}

sudo_quarantine() {
  local p="$1"
  if ! gate_check "$p" >/dev/null 2>&1; then
    log "REFUSED by gate (sudo): $p"; return 1
  fi
  local qdir="${CLEANER_QUARANTINE_DIR:-$HOME/CloudProviderCleaner-Quarantine}"
  mkdir -p "$qdir" 2>/dev/null || sudo mkdir -p "$qdir"
  if sudo mv "$p" "$qdir"/ 2>/dev/null; then
    log "QUARANTINED (sudo) $p -> $qdir"
    echo "  Quarantined (sudo): $p -> $qdir"
  else
    log "FAILED sudo move $p"; echo "  Could not move (sudo): $p" >&2; return 1
  fi
}

keychain_delete() {
  local label="$1"
  security delete-generic-password -l "$label" >/dev/null 2>&1 || true
  security delete-internet-password -l "$label" >/dev/null 2>&1 || true
  log "KEYCHAIN removed matches for: $label"
}

quit_app() {
  local id="$1" proc ans i
  [ -n "${CLEANER_SKIP_APPQUIT:-}" ] && return 0
  command -v pgrep >/dev/null 2>&1 || return 0
  while IFS= read -r proc; do
    [ -z "$proc" ] && continue
    pgrep -x "$proc" >/dev/null 2>&1 || continue
    echo "  Quitting \"$proc\" ..."
    osascript -e "tell application \"$proc\" to quit" >/dev/null 2>&1 || true
    i=0
    while pgrep -x "$proc" >/dev/null 2>&1 && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
    if pgrep -x "$proc" >/dev/null 2>&1; then
      printf '  "%s" is still running. Force-kill it? [y/N] ' "$proc"
      read -r ans
      case "$ans" in y|Y) pkill -x "$proc" 2>/dev/null || true ;; esac
    fi
  done <<EOF
$(provider_processes "$id")
EOF
}

unregister_extensions() {
  local id="$1" ext
  [ -n "${CLEANER_SKIP_EXTENSIONS:-}" ] && return 0
  command -v pluginkit >/dev/null 2>&1 || return 0
  while IFS= read -r ext; do
    [ -z "$ext" ] && continue
    pluginkit -e ignore -i "$ext" >/dev/null 2>&1 || true
    log "EXTENSION ignored: $ext"
  done <<EOF
$(provider_extension_ids "$id")
EOF
}

# execute_removal <id> <assume_yes>
#   Removes the app, traces, (optional) system items, and Keychain items.
#   It NEVER deletes synced DATA folders — that feature was intentionally removed
#   because those are your files and are usually undeletable File Provider roots.
execute_removal() {
  local id="$1" assume_yes="${2:-0}" p k ans

  echo
  echo "Removing $(provider_name "$id") ..."
  quit_app "$id"
  unregister_extensions "$id"

  # 1. App + traces (auto)
  if [ "${#SCAN_AUTO[@]}" -gt 0 ]; then
    for p in "${SCAN_AUTO[@]}"; do trash_path "$p"; done
    echo "  Moved app & traces to Trash."
  fi

  # 2. System items (sudo, allowlisted)
  if [ "${#SCAN_SUDO[@]}" -gt 0 ]; then
    printf '  Found %d system item(s) needing sudo. Remove them? [y/N] ' "${#SCAN_SUDO[@]}"
    read -r ans
    case "$ans" in
      y|Y) for p in "${SCAN_SUDO[@]}"; do sudo_quarantine "$p"; done ;;
      *)   echo "  Skipped system items." ;;
    esac
  fi

  # 3. Keychain
  if [ "${#SCAN_KEYCHAIN[@]}" -gt 0 ]; then
    printf '  Remove %d Keychain item(s)? [y/N] ' "${#SCAN_KEYCHAIN[@]}"
    read -r ans
    case "$ans" in
      y|Y) for k in "${SCAN_KEYCHAIN[@]}"; do keychain_delete "$k"; done
           echo "  Keychain items removed." ;;
      *)   echo "  Kept Keychain items." ;;
    esac
  fi

  # NOTE: Synced DATA folders are intentionally left untouched. See report_scan
  # for guidance on removing them from inside the provider app.
  if [ "${#SCAN_DATA[@]}" -gt 0 ]; then
    echo
    echo "  Your synced data folders were left in place (this tool never deletes them)."
    echo "  To remove them: open the app, sign out / \"Unlink this Mac\", then delete."
  fi
}

# ===========================================================================
# SECTION 7 — Interactive front-end / main
# ===========================================================================

print_help() {
  sed -n '2,33p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
}

print_banner() {
  echo "===================================================================="
  echo "  Cloud Provider Cleaner  —  safe macOS uninstaller"
  echo "  Default: DRY-RUN. Deletes go to the Trash (recoverable)."
  echo "  Your synced data folders are never deleted."
  echo "===================================================================="
}

init_log() {
  if [ -z "${CLEANER_LOG:-}" ]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$HOME/Library/Logs" 2>/dev/null || true
    CLEANER_LOG="$HOME/Library/Logs/CloudProviderCleaner-$ts.log"
  fi
  log "=== CloudProviderCleaner run $(date 2>/dev/null) ==="
}

choose_provider_menu() {
  local installed ids=() id i choice
  installed="$(detect_installed)"
  if [ -z "$installed" ]; then
    echo "No supported cloud providers detected on this Mac." >&2
    return 1
  fi
  echo "Detected providers:" >&2
  i=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    ids+=("$id")
    i=$((i + 1))
    printf '  %d) %s\n' "$i" "$(provider_name "$id")" >&2
  done <<EOF
$installed
EOF
  printf 'Select a provider to remove [1-%d], or q to quit: ' "$i" >&2
  read -r choice
  case "$choice" in
    q|Q) return 1 ;;
    ''|*[!0-9]*) echo "Invalid selection." >&2; return 1 ;;
  esac
  if [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ]; then
    printf '%s\n' "${ids[$((choice - 1))]}"
    return 0
  fi
  echo "Invalid selection." >&2
  return 1
}

confirm_removal() {
  local id="$1" typed name
  name="$(provider_name "$id")"
  echo
  echo "You are about to remove: $name"
  echo "App & traces will be moved to the Trash (recoverable)."
  echo "Your synced data folders are NEVER deleted by this tool."
  printf 'To proceed, type the provider name exactly (\"%s\"): ' "$name"
  read -r typed
  [ "$typed" = "$name" ]
}

print_summary() {
  local id="$1"
  echo
  echo "Done with $(provider_name "$id")."
  echo "Log: ${CLEANER_LOG:-<none>}"
  echo "Removed items are in the Trash — restore from Finder if needed."
}

main() {
  local dry_run=0 target="" scan_all=0 assume_yes=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)  dry_run=1 ;;
      --provider) shift; target="${1:-}" ;;
      --scan-all) scan_all=1 ;;
      --yes|-y)   assume_yes=1 ;;
      --help|-h)  print_help; return 0 ;;
      *) echo "Unknown option: $1" >&2; return 2 ;;
    esac
    shift
  done

  print_banner
  init_log

  if [ "$scan_all" -eq 1 ]; then
    local any=0 id
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      any=1
      scan_provider "$id"
      report_scan "$id"
    done <<EOF
$(detect_installed)
EOF
    [ "$any" -eq 0 ] && echo "No supported cloud providers detected."
    return 0
  fi

  if [ -z "$target" ]; then
    target="$(choose_provider_menu)" || return 1
  fi
  if ! validate_provider "$target"; then
    echo "Unknown provider: $target" >&2
    echo "Valid IDs: onedrive googledrive nextcloud dropbox box pcloud mega" >&2
    return 2
  fi

  scan_provider "$target"
  report_scan "$target"

  if [ "$dry_run" -eq 1 ]; then
    echo
    echo "Dry-run only. Nothing was modified."
    return 0
  fi

  # Only app/traces/sudo/keychain are removable; data folders are never deleted.
  if [ "${#SCAN_AUTO[@]}" -eq 0 ] && [ "${#SCAN_SUDO[@]}" -eq 0 ] \
     && [ "${#SCAN_KEYCHAIN[@]}" -eq 0 ]; then
    echo
    echo "Nothing to remove. (Any synced data folders shown above are left as-is.)"
    return 0
  fi

  if [ "$assume_yes" -ne 1 ]; then
    if ! confirm_removal "$target"; then
      echo "Aborted. Nothing was modified."
      return 1
    fi
  fi

  execute_removal "$target" "$assume_yes"
  print_summary "$target"
}

# Run main() only when executed directly (not when sourced as a library).
if [ -z "${CLEANER_LIB_ONLY:-}" ]; then
  main "$@"
fi
