# DPX - DDEV Project eXtend

[Read in Russian](README.ru.md)

> **v1.9.1 (Stable)**

![Version](https://img.shields.io/badge/version-1.9.1-blue)
![Bash](https://img.shields.io/badge/Bash-4.0+-green)
![DDEV](https://img.shields.io/badge/DDEV-1.21.0+-blue)
![Docker](https://img.shields.io/badge/Docker-20.10+-blue)
![License](https://img.shields.io/badge/License-MIT-yellow)

DPX is a Bash CLI for managing DDEV projects. It adds database refresh, snapshots, restore and production-export workflows; project scaffolding for WordPress, Joomla, OpenCart, ocStore, Laravel and plain PHP; Cloudflare and ngrok tunnels; PHP version switching; project metadata; full backups; migrations; deployment; cleanup; diagnostics; and self-update support.

The command layer is deliberately conservative around data mutations. Database imports, URL changes, PHP changes, configuration patches and tunnel setup have a backup or rollback path whenever the operation supports one.

## Table of Contents

- [Data Integrity](#data-integrity)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Extended CLI Reference](#extended-cli-reference)
- [Command Matrix](#command-matrix)
- [Configuration](#configuration)
- [Tunnels](#tunnels)
- [Safe Sudo Protocol](#safe-sudo-protocol)
- [Architecture and Tech Stack](#architecture-and-tech-stack)
- [Testing and Quality Gates](#testing-and-quality-gates)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)
- [License](#license)

## Data Integrity

DPX follows a zero-trust mutation policy:

- A local database snapshot is created before destructive database work where the workflow supports it.
- Full site restore takes a safety DDEV snapshot before unpacking files or importing the embedded dump.
- WordPress URL replacement uses WP-CLI with `--all-tables`, `--precise` and `--allow-root` in the WordPress path.
- Non-WordPress SQL replacement uses the container-side `lib/php_helpers/dpx_serialize_safe_replace.php` helper so PHP serialized string lengths are recalculated after replacement.
- `wp-config.php` changes use a hidden byte-for-byte snapshot, a patch, `php -l` validation through DDEV, marker verification and rollback on failure.
- Nginx tunnel configuration is written as a host-side DDEV extension and removed during tunnel cleanup.
- Ctrl+C during a tunnel invokes cleanup traps that restore WordPress configuration, reverse database changes, remove the Nginx override, stop the provider and remove temporary state.

### Two snapshot subsystems

DPX uses two distinct recovery mechanisms — they store data in different places and serve different purposes:

**1. File-based SQL dumps** live in the central `DPX_DB_LOCAL_DIR` directory as `<project>_<TYPE>_<yyMMdd>_<HHMMSS>_<rand>.sql` with type tags:

| Tag | Created by | Retention |
| --- | --- | --- |
| `SNAP` | `dpx db snap` | newest 3 (hardcoded) |
| `LOCAL_BACKUP` | `dpx db pull` / `dpx db restore` protective dumps | newest 3, configurable via `local_backup_keep` |
| `TO_PROD` | `dpx db push` exports | newest 3 (rotation default) |
| `BEFORE_PHP` | `dpx set-php` | newest 3 (rotation default) |

Retention uses the **timestamp embedded in the filename** (not mtime), so dumps synced without `--times` or touched by restore tooling keep their true chronological order. Rotation is scoped to the `<project>_<TYPE>_` prefix; files of other projects or manual files that do not match a DPX naming pattern are never touched.

**2. DDEV container snapshots** are managed by DDEV itself in `<project>/.ddev-db-snapshots`. DPX creates them (via `ddev snapshot --name=<tag>_<HHMMSS>_<rand>`) before URL replacement passes in the tunnel, `db pull` and `db push` flows, and records the snapshot name in `<project>/.dpx/current_snapshot`. If a process dies mid-mutation, the next DPX command detects the leftover marker and offers to restore the snapshot automatically (orphan recovery). These snapshots are excluded from full site backups and can be freed with `dpx clean --snapshots`.

## Requirements

| Dependency | Minimum | Purpose |
| --- | ---: | --- |
| Bash | 4.0+ | Associative arrays, namerefs, `mapfile`, modern shell features |
| DDEV | 1.21.0+ | Project lifecycle, database import/export, snapshots and container execution |
| Docker | 20.10+ | DDEV container runtime |
| jq | 1.5+ | DDEV JSON parsing and ngrok API parsing |
| curl, grep, sed, awk, tar | system | HTTP access, text processing and archives |
| PHP CLI | optional | Required only for selected local helper/test scenarios; WordPress operations normally use PHP inside DDEV |

### macOS

macOS ships Bash 3.2, which is not supported. Install Bash 4.0 or newer with Homebrew and ensure it precedes `/bin/bash` in `PATH`. The implementation detects macOS and uses BSD-compatible behavior for in-place `sed` operations. The test suite also simulates BSD `sed`, `stat`, `readlink` and tar behavior.

## Installation

```bash
git clone https://github.com/vinyardrip/dpx.git
cd dpx
./install.sh
```

The default installation creates a symlink in `~/.local/bin`. Use `sudo ./install.sh install-global` for a global installation, `./install.sh check` for dependency checks, and `./install.sh uninstall` to remove an installation. The supported update path is `dpx update` when DPX is installed from a Git checkout.

## Quick Start

```bash
dpx                         # first-run wizard when user config is absent
dpx config --show           # inspect active settings
dpx list                    # list DDEV projects
dpx new mysite --cms=wordpress --php=8.1 -y
dpx db pull --project-name mysite --db-file mysite_prod
dpx site backup --project-name mysite --output ~/backups --keep 5
dpx tunnel --project-name mysite --provider=cloudflare
```

The first-run wizard is interactive only. Non-interactive calls do not hang; they print a hint to run `dpx config`. When `cloudflared` is present and `ngrok` is absent, the first-run wizard selects `cloudflare` as the provider default.

## Extended CLI Reference

All commands accept `-h` or `--help` where their command help implements it. Global options recognized by the router are `-h`, `--help`, `-v`, `--version`, `-y`, `--yes` and `--debug`. Arguments may be written as `--key value` or `--key=value` where the command parser supports the option.

### `dpx new`

Creates a DDEV project using one of six scaffolders. Without `--cms`, the command displays an interactive selector.

| Option | Values / default | Behavior |
| --- | --- | --- |
| `--project-name NAME` | Positional name also supported | Target directory and DDEV project name |
| `--cms TYPE` | `wordpress`, `joomla`, `opencart`, `ocstore`, `laravel`, `php`; interactive when omitted | Selects the scaffolder |
| `--type TYPE` | Alias of `--cms` | Compatibility alias |
| `--php VERSION` | Configuration default, normally `7.4` | DDEV PHP version |
| `--db` | Off by default | Creates database data immediately after the container starts |
| `-y`, `--yes` | Off by default | Skips confirmations and makes the workflow non-interactive where possible |
| `--archive` | Not a current `dpx new` option in v1.6.0 | Archive URLs are resolved internally from environment overrides, GitHub releases or source archives; this flag is not parsed by the shipped command |
| `--non-interactive` | Not a current parser option | Use `-y` for the supported non-interactive confirmation switch |

CMS aliases include `wp`, `ocs`, `lara`, `html`, `static` and numeric menu choices `1` through `6`. `dpx new-wp` is a compatibility wrapper for `dpx new --cms=wordpress`.

### `dpx site backup`

`dpx site backup` resolves to the legacy `backup` implementation and creates `FULL_<project>_<timestamp>.tar.gz`. The archive contains project files and an exported database dump when export succeeds. Heavy or generated directories such as `.ddev/.importdb`, `.ddev-backups`, `backups`, `node_modules`, `vendor` and `.git` are excluded.

| Option | Values / default | Behavior |
| --- | --- | --- |
| `--project-name NAME` | Interactive selection when omitted | Project to back up |
| `--output DIR` | `full_backup_path` | Destination directory |
| `--keep N` | `full_backup_keep`, default `3` | Number of newest matching full archives retained |
| `-y`, `--yes` | Off | Skips start and backup confirmations |

After a successful archive, automatic pruning removes older `FULL_<project>_` archives until the retention limit is met. The legacy spelling `dpx backup` remains supported.

### `dpx site restore`

`dpx site restore` restores an archive created by the full backup workflow. Without an archive argument, the command lists `FULL_*.tar.gz` files from `full_backup_path`, newest first.

| Option | Values / default | Behavior |
| --- | --- | --- |
| `ARCHIVE` | Optional positional path | Archive to restore |
| `--file FILE` | Optional alias path | Alternate archive input |
| `--project-name NAME` | Parsed from `FULL_<project>_<timestamp>.tar.gz`, otherwise prompted | Target DDEV project |
| `-y`, `--yes` | Off | Skips overwrite confirmation |

Restore order is safety snapshot, archive validation, merge extraction into the projects base, embedded dump import, CMS-aware cache cleanup and DDEV launch. The pre-restore snapshot is registered in `.dpx/current_snapshot`; `INT`/`TERM`/`EXIT` traps attempt rollback and preserve the marker for orphan recovery if rollback fails. Archive validation rejects `..`/absolute members and symlink or hardlink targets escaping the extraction root. Archived files overwrite matching project files; extra existing files are preserved. The legacy spelling `dpx restore` remains supported.

### `dpx tunnel`

The shipped v1.6.0 command uses `--provider`, not `--driver`, and discovers the host port from DDEV. `--driver=<cloudflared|ngrok>` and `--port` are planned interface names, but are not parsed by the current command. Use the supported form below.

| Option | Values / default | Behavior |
| --- | --- | --- |
| `--project-name NAME` | Auto-detected from the current DDEV directory, otherwise interactive | Project to publish |
| `--cms-type TYPE` | Auto-detected; `wordpress`, `joomla`, `opencart`, `php` | Controls URL replacement and CMS cleanup |
| `--provider=PROVIDER` | `cloudflare` or `ngrok`; configured default, then available provider | Selects `cloudflared` or ngrok |
| `--driver=<cloudflared\|ngrok>` | Not parsed in v1.6.0 | Use `--provider` |
| `--port PORT` | Not parsed in v1.6.0; DDEV port is detected | Use DDEV's detected host port |
| `-y`, `--yes` | Off | Skips confirmations |

For WordPress, DPX replaces the local database URL with the tunnel URL, injects the `DPX_SMART_TUNNEL` block into `wp-config.php`, and writes `.ddev/nginx_full/dpx-tunnel.conf`. The Nginx override disables `absolute_redirect` and `port_in_redirect`, forwards the public `Host`, and sets `X-Forwarded-Proto https` so the application sees the public HTTPS request correctly.

Ctrl+C runs the rollback trap: restore `wp-config.php` from its snapshot, restore the database from the saved DDEV snapshot or perform reverse search-replace fallback, flush WordPress caches, remove the Nginx override, reload Nginx, stop the provider and remove temporary files and PID markers.

### `dpx db pull`, `dpx db snap`, `dpx db restore`, `dpx db push`

The grouped database namespace maps to `refresh`, `db-snap`, `db-restore` and `to-prod` respectively. These legacy names remain valid.

| Command | Main options | Defaults / behavior |
| --- | --- | --- |
| `dpx db pull` | `--project-name`, `--cms-type`, `--db-file`, `--prod-url`, `--prod-tld`, `--no-backup`, `-y` | Refreshes local DB from production; production TLD defaults to `by`; can skip the protective backup with `--no-backup` |
| `dpx db snap` | `--project-name`, `-y` | Exports an uncompressed local snapshot and keeps the newest 3 snapshots |
| `dpx db restore` | `--project-name`, `--cms-type`, `-y` | Selects a local backup, creates a protective dump, imports it and runs CMS post-processing |
| `dpx db push` | `--project-name`, `--cms-type`, `--prod-url`, `--prod-tld`, `-y` | Exports the local database with production URL replacement; production TLD defaults to `by` |

#### Serialization-safe database replacement

There is no standalone public `dpx db replace` router command in v1.6.0. The replacement path used by refresh, deploy, migrate and tunnel-related database operations is `db_import_with_replace()` in `lib/database.sh`. It stages the SQL dump and `lib/php_helpers/dpx_serialize_safe_replace.php` into `.dpx/tmp`, executes the PHP helper inside the DDEV container, recalculates `s:N:` byte lengths and imports the patched dump. This avoids corrupting Joomla, OpenCart and serialized WordPress data when URL lengths change.

### `dpx config`

The wizard manages `~/.config/dpx/dpx.conf`; managed keys are upserted while unrelated lines are preserved.

| Option | Values / default | Behavior |
| --- | --- | --- |
| `--show` | Off | Prints the active merged configuration and file path |
| `--projects-root PATH` | Existing `ddev_projects_base_path` | Sets the DDEV projects directory |
| `--db-local-dir PATH` | Existing `DPX_DB_LOCAL_DIR` | Sets central storage for local snapshots and protective dumps |
| `--db-prod-dir PATH` | Existing `DPX_DB_PROD_DIR` | Sets central storage for production dumps consumed by `db pull` |
| `--backup-dir PATH` | Existing `DPX_BACKUP_DIR` | Sets central storage for full site archives |
| `--provider NAME` | `ngrok` or `cloudflare` | Sets the preferred tunnel provider |
| `--db-user USER` | `db` | Default database user for scaffolders |
| `--db-password PASS` | `db` | Default database password |
| `--lang LANG` | `auto`, `en`, `ru`; default `auto` | Sets CLI output language |
| `-y`, `--yes` | Off | Applies flag updates without summary confirmation |

The first-run wizard asks for projects root, provider, DB user, DB password and language. It uses `command -v cloudflared` and `command -v ngrok` for the provider default when no user file exists.

The complete wizard order is projects directory, local dumps directory, production dumps directory, full backups directory, tunnel provider, DB user, DB password and language. The first four answers are persisted to `~/.config/dpx/config` as canonical `DPX_*` variables.

### `dpx set-php`

Selects a project and a DDEV-supported PHP version interactively. A positional project name is accepted.

| Option | Values / default | Behavior |
| --- | --- | --- |
| `PROJECT` | Optional positional project name | Selects the project without the project picker |
| `-y`, `--yes` | Parsed as a global confirmation flag | Skips supported confirmations |
| `-h`, `--help` | Off | Shows command help |

The workflow reads supported versions from `ddev debug capabilities`, falls back to a built-in version list if needed, exports a database backup tagged `BEFORE_PHP`, changes `php_version`, restarts DDEV, flushes WordPress cache when applicable, and asks whether the tested version should be saved as `php_max` metadata. The command warns before selecting a version above the saved maximum.

### Other commands

| Command | Options / behavior |
| --- | --- |
| `dpx list` | `--sort-by name\|php\|php_max\|status`, `--format table\|json\|simple`, `--group` |
| `dpx edit` | Positional project; `--php-max VERSION`, `--notes TEXT`, `--show`, `--delete` |
| `dpx ddev` | Passes a DDEV command and arguments; selects a project when called outside one |
| `dpx deploy` | `--project-name`, `--cms-type`, `--db-file`, `--prod-url`, `--php-version`, `--db-type`, `--db-version`, `-y` |
| `dpx migrate` | `--project-name`, `--devilbox-folder`, `--cms-type`, `--php-version`, `--devilbox-php`, `--db-name`, `--db-type`, `--db-version`, `--no-db`, `--keep-backup`, `-y` |
| `dpx update` | `--check` performs a check only; `-y` skips update confirmation |
| `dpx info` | Reports configuration, paths, versions and dependency availability |
| `dpx clean` | `--project-name`, `--snapshots`, `--all`, `-y`; `.dpx/config` and `.dpx/current_snapshot` are preserved; `--snapshots`/`--all` inventory and confirm DDEV DB snapshot removal, and require `-y` in non-interactive mode |

## Command Matrix

| Command | Purpose | Implementation details |
| --- | --- | --- |
| `dpx new` / `dpx site new` | Scaffold a project | Six CMS/framework types; `--cms`, `--php`, `--db`, `-y`; `new-wp` is a WordPress alias |
| `dpx tunnel` | Publish a running DDEV project | Cloudflare or ngrok; WordPress URL replacement; smart `wp-config.php`; Nginx override; trap-safe rollback |
| `dpx db pull` / `refresh` | Refresh local DB from production | Protective backup, import and CMS-aware URL replacement |
| `dpx db snap` / `db-snap` | Create a local DB snapshot | Uncompressed export and retention of the newest 3 |
| `dpx db restore` / `db-restore` | Restore a local DB backup | Protective pre-dump and CMS post-processing |
| `dpx db push` / `to-prod` | Prepare a production export | Reverse URL replacement and export workflow |
| `dpx site backup` / `backup` | Create a full archive | Files plus database, exclusions and automatic pruning |
| `dpx site restore` / `restore` | Restore a full archive | Snapshot, validate, unpack, import, cache cleanup and launch |
| `dpx site migrate` / `migrate` | Move Devilbox project to DDEV | File copy, DB export, CMS configuration and import |
| `dpx site deploy` / `deploy` | Deploy an existing codebase | DDEV setup, DB import and URL replacement |
| `dpx config` | Manage user configuration | Wizard, `--show`, provider, credentials, paths and language |
| `dpx set-php` | Switch project PHP | Backup, change, restart, cache flush and tested-version metadata |
| `dpx list` | List projects | Table/JSON/simple output, sorting and grouping |
| `dpx edit` | Manage metadata | `php_max`, notes, show and delete |
| `dpx ddev` | Run DDEV commands | Transparent inside a project; interactive selection outside |
| `dpx info` | Diagnostics | Dependency status, versions, configuration and paths |
| `dpx update` | Self-update | Git check, incoming commits and update application |
| `dpx clean` | Remove stale state | Temporary files are age-selected; `--snapshots` inventories and confirms DDEV DB snapshot removal (`.ddev-db-snapshots`); non-interactive removal requires `-y`; config and recovery markers are preserved |

## Configuration

Settings are loaded in cascade order, lowest to highest priority: `/etc/dpx/dpx.conf`, then the repository-local `config/dpx.conf` (shipped defaults — it never overrides explicit user settings), then `~/.config/dpx/dpx.conf` and `~/.config/dpx/config` for global storage paths. Later files override earlier values, so user configuration always wins over repo defaults. Values use `key = value` syntax. `dpx config` creates and maintains the global path file `~/.config/dpx/config` with `DPX_PROJECTS_DIR`, `DPX_DB_LOCAL_DIR`, `DPX_DB_PROD_DIR` and `DPX_BACKUP_DIR`; application and compatibility settings remain in `dpx.conf`.

Central storage is outside project webroots: the configured projects directory contains DDEV projects, while `db_local/`, `db_prod/` and `backups/` hold local dumps, production dumps and full archives. Database and site commands use these configured paths when their path flags are omitted.

Interactive database workflows use a two-step picker. First DPX renders the project table with status and PHP version. Then it renders a newest-first dump file list, with `[1]` as the default. Database names are resolved from `.ddev/config.yaml`, CMS configuration or `.env`; if no safe name can be resolved, an interactive manual database-name prompt is used, with the project name as the non-interactive fallback.

```ini
DPX_PROJECTS_DIR = ~/projects/php
DPX_DB_LOCAL_DIR = ~/projects/db_local
DPX_DB_PROD_DIR = ~/projects/db_prod
DPX_BACKUP_DIR = ~/projects/backups
```

Compatibility and application settings remain available in `~/.config/dpx/dpx.conf`:

```ini
ddev_projects_base_path = ~/projects/php
default_tunnel_provider = cloudflare   # ngrok | cloudflare
db_user = db
db_password = db
cli_lang = auto                         # auto | en | ru
default_php_version = 7.4
default_db_type = mysql
default_db_version = 5.7
project_tld = lo
full_backup_path = ~/projects/backups
full_backup_keep = 3
local_backup_keep = 3                   # *_LOCAL_BACKUP_*.sql retention (db pull / db restore)
auto_update_check = true
```

## Tunnels

Cloudflare Tunnel is the verified and recommended provider. The ngrok provider is experimental and untested in restricted regions; upstream geo-blocking may return `ERR_NGROK_9040`. Provider selection is configured with `default_tunnel_provider` or `--provider=cloudflare|ngrok`.

The Cloudflare driver runs `cloudflared tunnel --url http://127.0.0.1:<host-port>` and passes the local domain as `--http-host-header`. The ngrok driver starts `ngrok http`, reads `127.0.0.1:4040/api/tunnels`, and selects an HTTPS endpoint using jq, Python or a grep fallback.

### Browser local-network prompts

When the public tunnel page loads assets from a local DDEV address, Chrome may show a Local Network Access prompt or display a broken layout. This is Chrome Private Network Access protection. Click **Allow**, or use an Incognito window and allow the request there. A tunnel URL does not make a local origin automatically trusted by the browser.

## Safe Sudo Protocol

`lib/sudo.sh` centralizes privileged operations. `dpx_sudo` limits authentication to `DPX_SUDO_MAX_ATTEMPTS` (3) and uses a 60-second timeout through `timeout`, `gtimeout` on macOS, or direct `sudo` when no timeout utility exists. A failed timeout or exhausted attempt count returns a failure instead of retrying indefinitely. The module does not cache a password; the sudo timestamp cache is owned by the operating system's `sudo` session.

The file protocol is:

1. Verify the source file exists.
2. Create a sibling `.bak` snapshot with `cp` and verify that the operation succeeded.
3. Perform the privileged edit through `dpx_sudo`.
4. Validate the result.
5. Remove the snapshot on success, or restore it through `cp`/`dpx_sudo` on failure.

The `wp-config.php` protocol uses a hidden `.wp-config.php.dpx_bak` file. The snapshot is checked for existence, non-empty content and byte-for-byte equality with `diff -q`. After `mv -f` rollback, DPX verifies that `DPX_SMART_TUNNEL` is absent. If verification fails, the operation reports a critical error for manual inspection.

## Architecture and Tech Stack

### Module layout

```text
dpx.sh                  Entry point, global help and command router
commands/*.sh           Command parsing and workflow orchestration
lib/paths.sh            OS detection and DPX_ROOT resolution
lib/i18n.sh             Locale detection and t() dictionary engine
lib/io.sh               STDERR-oriented print_* output helpers
lib/config.sh           Cascaded configuration and first-run wizard
lib/args.sh             --key value / --key=value argument parser
lib/checks.sh           DDEV, Docker and orphan-state checks
lib/sudo.sh             Safe privileged file protocol
lib/cms.sh              CMS registry and cache handlers
lib/projects.sh         Project discovery and selection
lib/ddev.sh              DDEV command wrappers
lib/database.sh         Import/export, replacement and snapshots
lib/backup.sh           Full archive and retention logic
lib/devilbox.sh         Devilbox migration integration
lib/meta.sh             projects.json metadata
lib/utils.sh            prompts, validation and portable file helpers
```

### i18n engine

`lib/i18n.sh` resolves language in this order: explicit `DPX_LANG`, configured `cli_lang` when it is `en` or `ru`, `LC_ALL`, `LANG`, then English. The `t KEY [printf-args...]` function selects the Russian dictionary when the resolved language is `ru`, otherwise the English canonical dictionary, and formats placeholders with `printf -v`. User-facing command text should pass through `t`; technical identifiers such as `DDEV`, `wp-config.php`, provider names and command syntax remain unchanged.

### Cross-platform compatibility

`lib/paths.sh` detects Linux or macOS and records the in-place `sed` mode. The code avoids GNU-only assumptions where practical: BSD/GNU `sed` uses the platform-specific backup extension, symlink resolution uses plain `readlink`, file metadata uses portable `du`/`awk` paths, and archive argument ordering is compatible with GNU tar and bsdtar. The macOS simulation suite supplies shims that reject incompatible GNU flags so regressions are visible before a real macOS run.

### Human-AI collaboration rules

The repository treats command output, data output and test process state as separate concerns:

- Data-returning functions write their result to stdout; UI is written to stderr.
- Command files are syntax-checked with `bash -n` before dynamic sourcing by the router.
- Tests use isolated temporary directories and mocked DDEV, Docker, Git, network and provider binaries.
- Subshells that are expected to terminate or consume no interactive input use explicit `</dev/null` stdin redirection; this prevents inherited test pipes or terminals from hanging child processes.
- Background provider and update-check jobs are cleaned up by test teardown.
- Tests should assert both success and failure paths, including rollback and cleanup behavior.

## Testing and Quality Gates

Run the complete suite with:

```bash
./run_tests.sh
```

The runner performs a ShellCheck gate and then executes the suites for core behavior, configuration, domain routing, cleanup, universal project creation, i18n, tunnel patches/provider parsing, macOS/BSD simulation, and hardening regressions. The gate covers `dpx.sh`, `install.sh`, `run_tests.sh`, every `lib/` and `commands/` module, and the test suites; files are analyzed individually to keep it fast. Useful focused commands are:

```bash
bash tests/test_hardening.sh
bash tests/test_i18n.sh
bash tests/test_config.sh
bash tests/test_tunnel_patch.sh
bash tests/test_macos_sim.sh
```

The v1.9.1 repository includes Linux and Darwin-simulation coverage. Real hardware macOS, WSL2 and field-environment coverage remain separate roadmap items.

## Troubleshooting

### Cloudflare or ngrok broken layout

If assets are requested from a `.ddev.site` or another local address, Chrome may block them under Private Network Access. Click **Allow** in the Local Network Access prompt or retry in Incognito mode. Inspect browser developer tools to confirm that blocked requests target the local origin rather than the public tunnel.

### ngrok `ERR_NGROK_9040`

This indicates an upstream ngrok geo-restriction or access policy. Verify the ngrok account and authtoken, then prefer `--provider=cloudflare` in restricted regions.

### Interrupted tunnel

Run a new DPX command from the project or inspect `.dpx/current_snapshot`, `.dpx/tunnel.pid` and hidden WordPress backup state. DPX performs orphan recovery on the next relevant command; if automatic recovery cannot complete, use the recorded DDEV snapshot name and do not delete it until the database state is verified.

## Roadmap

- [x] Grouped `db` and `site` namespaces with compatibility aliases
- [x] Universal `dpx new` with six project types including ocStore
- [x] Cloudflare Tunnel provider
- [x] ngrok provider implementation
- [!] ngrok remains experimental and untested in restricted regions; upstream geo-blocking may return `ERR_NGROK_9040`
- [x] Serialization-safe PHP replacement helper for serialized SQL data
- [x] English/Russian locale engine and tunnel output coverage
- [ ] Add public `dpx db replace` command and explicit tunnel `--driver`/`--port` options if the interface is approved
- [ ] Field testing of `migrate`, `deploy`, `refresh` on Ubuntu, Debian and Fedora
- [ ] Real hardware macOS runs with Homebrew Bash
- [ ] WSL2 verification
- [ ] Visual progress indicators, such as spinners or table progress, during long-running WordPress SQL URL replacements with `--precise`

## License

[MIT License](https://github.com/vinyardrip/dpx/blob/main/LICENSE)

Copyright (c) 2026 DPX Contributors
