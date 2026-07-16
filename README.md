# Cloud Provider Cleaner

A safe, interactive macOS command-line tool that **removes third-party cloud
storage providers** — the app and all of its traces — while making it
**impossible** to delete macOS system folders or your personal files.

Supported providers:

- **Microsoft OneDrive**
- **Google Drive**
- **Nextcloud**
- **Dropbox**
- **Box** (Box Drive)
- **pCloud**
- **MEGA** (MEGAsync)

Provider IDs (for `--provider`): `onedrive` `googledrive` `nextcloud` `dropbox`
`box` `pcloud` `mega`.

> ⚠️ This tool deletes app files (by moving them to the Trash). It **never**
> deletes your synced data folders. Read [Safety design](#safety-design) and
> [Synced data folders](#synced-data-folders--file-provider) before using it.
> The default run is a **dry-run**.

---

## Why this exists

Generic "cleanup" scripts are dangerous: a single unquoted variable or an
over-broad wildcard can wipe system folders or your entire home directory. This
tool is built the opposite way — **every path it touches must pass a strict
Safety Gate**, and it can only ever act on paths that match a known provider
pattern. It never guesses, never recurses into system folders, and never deletes
your synced files.

---

## Features

- **Interactive menu** — lists only the providers actually installed on your Mac.
- **Full dry-run first** — see exactly what will be removed, with sizes, before
  anything happens.
- **Explicit confirmation** — you type the provider's name to proceed (not just
  "y").
- **Recoverable deletes** — everything goes to the **macOS Trash**; restore from
  Finder any time before you empty it.
- **Your synced data is never deleted** — the tool detects your synced data
  folders (e.g. `~/Library/CloudStorage/OneDrive-…`, `~/Dropbox`) and reports
  them for your information only. It never deletes them (see below for why).
- **Keychain cleanup** — removes the provider's saved credentials (shown in the
  dry-run first, deleted only after you confirm).
- **Graceful app shutdown** — quits a running app cleanly, offering a force-kill
  only if it refuses to quit.
- **sudo only when allowlisted** — root-owned remnants (e.g.
  `/Library/DropboxHelperTools`) are moved to a quarantine folder, and only when
  they match a provider pattern.
- **Audit log** — every action is written to a timestamped log file.
- **iCloud is hard-blocked** — Apple iCloud Drive can never be selected or
  touched.

---

## Requirements

- macOS (uses `osascript`, `security`, `pluginkit`, `pgrep` — all built in).
- `bash` (the script is compatible with the `bash 3.2` that ships on macOS).
- No third-party dependencies.

---

## Installation

```bash
git clone <this-repo> Cleaner
cd Cleaner
chmod +x cleaner.sh
```

That's it — it's a single self-contained script.

---

## Usage

### Interactive (recommended)

```bash
./cleaner.sh
```

Flow:

1. **Detect** — shows the providers installed on this Mac.
2. **Select** — pick one from the menu.
3. **Scan (dry-run)** — a categorized report of everything found, with sizes.
4. **Confirm** — type the provider's exact name to proceed.
5. **Remove** — app quit → extensions unregistered → traces moved to Trash →
   (optional) system items → (optional) Keychain items. Synced data is left
   untouched.
6. **Summary** — what happened, plus the log file path.

### Command-line flags

| Flag | Description |
|------|-------------|
| *(none)* | Interactive menu. |
| `--dry-run` | Scan and print the report only. **Never modifies anything.** |
| `--provider <id>` | Target one provider directly (see IDs above). |
| `--scan-all` | Report across **all** detected providers. No deletion. |
| `--yes`, `-y` | Skip the typed confirmation for app/traces. |
| `--help`, `-h` | Show help. |

Examples:

```bash
./cleaner.sh --dry-run                    # scan the chosen provider, change nothing
./cleaner.sh --provider onedrive --dry-run
./cleaner.sh --scan-all                   # overview of everything installed
./cleaner.sh --provider dropbox           # remove Dropbox interactively
```

---

## What gets removed

For the selected provider, the scanner looks **only** at that provider's known
locations:

| Category | Example | Handling |
|----------|---------|----------|
| App bundle | `/Applications/OneDrive.app` | Trash (auto) |
| Preferences | `~/Library/Preferences/com.microsoft.OneDrive.plist` | Trash (auto) |
| Application Support | `~/Library/Application Support/OneDrive` | Trash (auto) |
| Caches / HTTPStorages | `~/Library/Caches/com.microsoft.OneDrive` | Trash (auto) |
| Containers / Group Containers | `~/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite` | Trash (auto) |
| Saved State / Logs | `~/Library/Logs/OneDrive` | Trash (auto) |
| LaunchAgents (user) | `~/Library/LaunchAgents/com.microsoft.OneDrive*.plist` | Trash (auto) |
| System items | `/Library/DropboxHelperTools`, `/Library/LaunchDaemons/…` | **sudo + confirm** → quarantine |
| Keychain items | credentials labeled for the provider | **confirm**, then removed |
| Finder Sync / File Provider extensions | provider extension bundle IDs | unregistered via `pluginkit` |
| **Synced DATA folders** | `~/Library/CloudStorage/OneDrive-*`, `~/Dropbox`, `~/MEGA` | **detected & reported — never deleted** |

---

## Synced data folders & File Provider

The folders that hold **your actual files** (Documents, photos, project files,
etc.) are **never deleted** by this tool. It detects them and shows them in the
report for your information, with guidance — but there is no code path that
removes them.

Two reasons:

1. **They are your data.** Losing them is the worst-case outcome; the tool
   refuses to be responsible for it.
2. **macOS won't let anything force-delete them anyway.** Modern providers
   (OneDrive, Google Drive, Dropbox, Box, …) mount their folder under
   `~/Library/CloudStorage/…` as a **File Provider domain** managed by the
   system daemon `fileproviderd`. These are marked with the extended attribute
   `com.apple.file-provider-domain-id`. Finder's "Move to Trash", `rm -rf`, and
   even restarting `fileproviderd` are all refused by macOS by design — and the
   daemon's registration store is protected by SIP.

### How to remove a synced data folder

The folder can only be removed by its owner — the provider app:

1. **Before uninstalling** (best): open the provider app → sign out /
   **"Unlink this Mac"**. The app removes its own File Provider domain and the
   `~/Library/CloudStorage/…` folder disappears.
2. **If you already uninstalled** and the folder is stuck: reinstall the app,
   sign in, then **Unlink this Mac**, then uninstall again (with this tool).

> **Tip:** always **sign out / unlink inside the app first**, then uninstall.
> Removing the app before unlinking leaves an orphaned, undeletable folder.

---

## Safety design

Before any path is deleted, it must pass the **Safety Gate** (`gate_check`). A
path is rejected — and logged — unless **all** of these hold:

1. **Non-empty & absolute** — empty variables and relative paths are refused.
   (This alone prevents the classic `rm -rf "$X/"` disaster when `$X` is empty.)
2. **No `..` traversal.**
3. **Not the filesystem root**, and **at least 2 path components deep** — no
   top-level directory can ever be a target.
4. **System blocklist** — `/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/var`,
   `/private`, `/Library` (bare), `/Applications` (bare), and more are always
   rejected.
5. **Home blocklist** — your home dir and personal folders (`~/Documents`,
   `~/Desktop`, `~/Downloads`, `~/Pictures`, `~/Movies`, `~/Music`, …) plus the
   bare Library container dirs (`~/Library/Caches`, `~/Library/Preferences`, …)
   are always rejected. Only **provider-specific sub-paths** inside them can
   match.
6. **Symlink guard** — a symlink whose target resolves to a system path is
   rejected.
7. **iCloud hard-block** — anything containing `com.apple.`, `Mobile Documents`,
   `CloudDocs`, or `iCloud` is rejected outright.

Two more structural guarantees:

- **Frozen list** — the dry-run builds an exact list of paths. The remover acts
  on **that list only** and never re-expands wildcards at delete time. *What you
  confirm is exactly what is removed.*
- **Provider allowlist** — candidates are generated **only** from the selected
  provider's known patterns. The tool never scans your disk generically.

---

## Recovery

- **Trashed items** — restore from **Finder → Trash** any time before you empty
  it.
- **Quarantined (root-owned) items** — moved to
  `~/CloudProviderCleaner-Quarantine/`. Review and delete manually when you're
  sure.
- **Log file** — `~/Library/Logs/CloudProviderCleaner-<timestamp>.log` records
  every action, for audit and manual recovery.

---

## Testing

The tool ships with an automated test suite that runs entirely inside disposable
fake `HOME` directories under `/tmp` — it **never** touches your real home or
Trash.

```bash
bash tests/run_all.sh
```

This runs:

- **`tests/test_safety.sh`** — unit tests for the Safety Gate. A table of
  dangerous inputs (`/`, `~`, `/System`, symlink-to-system, empty var, `..`
  escapes, bare home/Library dirs) that must **all** be rejected, plus
  legitimate provider traces that must be allowed.
- **`tests/test_sandbox.sh`** — an integration test that builds fake provider
  traces plus "decoy" files, scans, and verifies that **only** the intended
  traces are moved, every decoy survives, and the synced-data folder is **never
  deleted — even when the user answers "y"**.
- **ShellCheck** (if installed) on the script and tests.

Install ShellCheck (optional) with `brew install shellcheck`.

---

## Extending it to another provider

The provider registry is pure data. To add, say, Sync.com:

1. Add `synccom` to `provider_ids` and `validate_provider`.
2. Add a `synccom)` case to `provider_name`.
3. Add `synccom:app`, `synccom:trace`, `synccom:daemon`, and `synccom:data`
   pattern blocks to `provider_globs`.
4. Add entries to `provider_keychain_labels`, `provider_processes`, and
   `provider_extension_ids`.

No logic changes are needed — the scanner, safety gate, reporter, and executor
work off the registry data. Add matching cases to the tests and run
`tests/run_all.sh`.

---

## Limitations & disclaimer

- Path patterns cover the **known** locations for current versions of each
  provider. Always read the dry-run report before confirming.
- The tool operates on the **current user** by default; a system-wide install
  may leave a root-owned remnant, handled via the sudo/quarantine step.
- Synced data folders are your responsibility to remove (via the app), as
  described above.
- This software is provided as-is; you are responsible for reviewing what it
  will remove.

---

## Project layout

```
Cleaner/
├── cleaner.sh                 # the tool (single self-contained script)
├── README.md                  # this file
├── tests/
│   ├── run_all.sh             # runs the whole suite + shellcheck
│   ├── test_safety.sh         # Safety Gate unit tests
│   └── test_sandbox.sh        # Scanner/Executor integration test (fake HOME)
```
