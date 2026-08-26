# DPX — DDEV Project eXtend

[Читать на русском / Read in Russian](README.ru.md)

> **v1.5.2 (Stable)**

![Version](https://img.shields.io/badge/version-1.5.2-blue)
![Bash](https://img.shields.io/badge/Bash-4.4+-green)
![DDEV](https://img.shields.io/badge/DDEV-1.21.0+-blue)
![Docker](https://img.shields.io/badge/Docker-20.10+-blue)
![License](https://img.shields.io/badge/License-MIT-yellow)

Universal CLI for managing DDEV projects. DPX extends DDEV with database operations (refresh from production, snapshots, restore), project scaffolding for five CMS/framework stacks, Cloudflare & ngrok tunnels with automatic rollback, PHP version switching, project metadata, and self-updates.

---

**Actively developed.** Stable commands: `list`, `set-php`, `edit`, `ddev`, `tunnel`, `db-snap`, `db-restore`, `to-prod`, `backup`, `new`, `config`. Commands `migrate`, `deploy`, `refresh` need additional field testing on different environments. Feedback and bug reports are welcome.

---

## Table of Contents

- [Data Integrity](#data-integrity)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Command Matrix](#command-matrix)
- [Architecture Overview](#architecture-overview)
- [Configuration](#configuration)
- [Tunnels](#tunnels)
- [Testing & Quality Gates](#testing--quality-gates)
- [Roadmap](#roadmap)
- [License](#license)

---

## Data Integrity

DPX treats data with a **Zero-Trust** policy: no mutation (URL rewrite, PHP switch, dump import, config patch) starts without an escape path. Snapshots are taken before destructive DB work (`ddev snapshot`), `wp-config.php` edits follow a backup → patch → `php -l` → verify → rollback cycle, and `/etc/hosts` changes go through a Safe-Sudo protocol (backup → edit → verify → rollback). Interrupting any operation with Ctrl+C triggers the registered cleanup traps: wp-config is restored byte-for-byte from snapshot, URLs are rolled back, the tunnel process and temp files are removed.

## Requirements

| Dependency                | Min version | Notes                                              |
| ------------------------- | :---------: | -------------------------------------------------- |
| **Bash**                  |  **4.4+**   | Associative arrays, `read -ra`, `mapfile`          |
| DDEV                      |   1.21.0+   | Local development environment                      |
| Docker                    |   20.10+    | Container engine (daemon running)                   |
| jq                        |    1.5+     | Parsing JSON output of `ddev describe` / ngrok API |
| sed, grep, awk, curl, tar |      —      | Standard GNU/BSD utilities                         |

### macOS note

macOS ships Bash 3.2 which is **not supported** (no associative arrays). Install modern Bash via Homebrew and make sure it precedes `/bin/bash` in `PATH`. All BSD-specific logic (BSD `sed -i ''`, `stat -f`, `readlink` without `-f`, bsdtar option order) is covered by the automated simulation suite, so no manual adjustments are required.

## Installation

```bash
git clone https://github.com/vinyardrip/dpx.git
cd dpx
./install.sh            # symlink into ~/.local/bin (no sudo)
```

Global install: `sudo ./install.sh install-global`. Dependency check only: `./install.sh check`.
Updates: `dpx update` (git fetch + pull + symlink reinstall). Uninstall: `./install.sh uninstall`.

## Quick Start

```bash
dpx                     # first run opens the configuration wizard if no user config exists
dpx list                # show all DDEV projects
dpx new                 # scaffold a project (interactive type selector)
dpx tunnel              # share a running project via public URL
dpx refresh             # refresh local DB from a production dump
dpx backup              # full project backup (files + database)
dpx config --show       # inspect active configuration
```

## Command Matrix

| Command        | Purpose                                                                    | Highlights                                                                 |
| -------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `dpx new`      | Scaffold a new project                                                     | 6 types: WordPress, Joomla, OpenCart, ocStore, Laravel, Plain PHP; flags `--cms=`, `--php=`, `--db`, `-y`; positional name supported |
| `dpx new-wp`   | Backward-compatible alias                                                  | Equivalent to `dpx new --cms=wordpress`; WP flags pass through              |
| `dpx tunnel`   | Public URL for a running project                                           | Providers: `cloudflare` and `ngrok`; smart wp-config block; Nginx hot-patch; Ctrl+C = full rollback |
| `dpx migrate`  | Migrate a project from Devilbox to DDEV                                    | DB transfer, PHP version mapping                                            |
| `dpx deploy`   | Deploy an existing codebase onto DDEV                                      | Import production dump, choose CMS type                                     |
| `dpx db pull` / `refresh`   | Refresh local DB from production          | URL replacement (WP search-replace or SQL-level), soft container restart before import |
| `dpx db snap` / `db-snap`     | Quick local DB snapshot                   | Rotation keeps last 3                                                       |
| `dpx db restore` / `db-restore` | Restore DB from local backup            | Protective pre-dump, CMS-aware post-import                                  |
| `dpx db push` / `to-prod`     | Prepare local DB for production export    | Reverse URL replacement, rotation                                           |
| `dpx site backup` / `backup`   | Full project backup (files + DB)                                           | `FULL_<name>_<timestamp>.tar.gz`, excludes heavy dirs, retention N          |
| `dpx site restore` / `restore` | Restore a full backup archive       | Safety DB snapshot -> unpack code/uploads -> import embedded dump -> CMS cache flush |
| `dpx site new` / `new`          | Scaffold (see `dpx new`)             | 6 project types                                                             |
| `dpx site migrate` / `migrate`  | Devilbox migration                   |                                                                             |
| `dpx site deploy` / `deploy`    | Deploy codebase onto DDEV            |                                                                             |
| `dpx config`   | Interactive configuration wizard / `--show`                                 | Writes `~/.config/dpx/dpx.conf`                                             |
| `dpx ddev`     | Run any DDEV command for a selected project                                | Works outside project directories                                           |
| `dpx list`     | List projects                                                              | Sort by php/status, JSON output, grouping                                   |
| `dpx set-php`  | Change project PHP version                                                 | Automatic DB backup first                                                   |
| `dpx edit`     | Project metadata (`php_max`, notes)                                        | Stored in `~/.config/dpx/projects.json`                                     |
| `dpx info`     | Environment & configuration report                                         | Dependency status with color indicators                                     |
| `dpx update`   | Self-update from Git                                                       | Shows incoming commits before applying                                      |

## Architecture Overview

```
dpx.sh                  Entry point / router (per-command source, syntax-checked)
commands/*.sh           Thin command layer (arg parsing + flow orchestration)
lib/
├── core.sh             Module loader; loads the chain below in order
├── paths.sh            OS detection (linux/macos), DPX_ROOT resolution
├── i18n.sh             Locale chain DPX_LANG -> LC_ALL -> LANG -> en; t() resolver
├── io.sh               print_* output helpers (stderr), color handling
├── config.sh           Cascaded configuration (system -> user -> project)
├── args.sh             CLI argument parsing (--key=value supported)
├── checks.sh           Dependency/version gates
├── sudo.sh             Safe-sudo protocol for privileged file edits
├── cms.sh              CMS registry, interactive selectors, cache flush handlers
├── projects.sh         Project discovery/selection
├── ddev.sh             DDEV wrappers (start/restart/import-db/export-db...)
├── database.sh         Dump import/export, DB-name detection, snapshots
├── backup.sh           Full-project backups with rotation
├── devilbox.sh         Devilbox integration (migrate)
├── meta.sh             projects.json metadata
└── utils.sh            safe_sed_inplace, prompts, validation helpers
tests/test_*.sh         Unit/e2e suites (see Testing)
```

Design rules:

- Every module has a re-entrancy guard; the loader order respects dependencies.
- **STDOUT carries data, STDERR carries UI.** Functions returning values (e.g. `project_full_backup`) never mix dialog text into their result.
- Commands are individually sourced by the router and syntax-checked (`bash -n`) before execution.

## Configuration

Settings live in `~/.config/dpx/dpx.conf` (INI-style `key = value`). A project-local `config/dpx.conf` can override individual keys; system-wide `/etc/dpx/dpx.conf` is read first when present.

```ini
ddev_projects_base_path = ~/projects/php
default_tunnel_provider = ngrok        # ngrok | cloudflare
db_user = db                           # MySQL/MariaDB credentials used by scaffolders
db_password = db
cli_lang = auto                        # auto | en | ru  (CLI output language)
default_php_version = 8.1
project_tld = lo
full_backup_path = ~/projects/backups
full_backup_keep = 3
auto_update_check = true            # daily non-blocking 'update available' notice
```

Manage it without hand-editing:

```bash
dpx config            # interactive wizard: projects root, tunnel provider,
                      # DB credentials, CLI language
dpx config --show     # print active values and the config file path
dpx config --projects-root ~/work/php --provider cloudflare --lang ru -y
```

**First-run:** the first `dpx` invocation on a machine without `~/.config/dpx/dpx.conf` automatically starts the setup wizard (interactive terminals only; non-interactive sessions get a hint pointing at `dpx config`).

## Tunnels

`dpx tunnel` publishes a running project through Cloudflare Tunnel or ngrok. For WordPress it performs three coordinated steps — DB URL replacement, injection of the `DPX_SMART_TUNNEL` block into `wp-config.php` (conditional HTTPS via `X-Forwarded-Proto`, forced Host), and an Nginx hot-patch adding `absolute_redirect off` / `port_in_redirect off` plus forwarded proxy headers — then registers cleanup traps so Ctrl+C restores everything. The ngrok driver extracts the public HTTPS URL from the local API (`127.0.0.1:4040/api/tunnels`) using a jq → python3 → grep parser chain.

## Testing & Quality Gates

```bash
./run_tests.sh                    # ShellCheck gate + all suites (Linux profile)
bash tests/test_macos_sim.sh      # macOS/BSD simulation suite standalone
```

Current state: **195 tests passing** across two platform profiles (native Linux and Darwin simulation with BSD shims for `sed`/`stat`/`readlink`/`tar`). The runner integrates a ShellCheck gate — findings fail the build. Suites: core, framework self-checks, macOS simulation, universal `new` scaffolding, tunnel patches + ngrok driver, configuration wizard, i18n locale layer.

## Roadmap

- [x] Interactive setup wizard (`dpx config`, first-run auto trigger)
- [x] Universal `dpx new` with 6 project types incl. ocStore
- [x] ngrok provider implementation
- [x] Internal comments and CLI interface translated to English (ru available via locale/config)
- [ ] Field testing of `migrate`, `deploy`, `refresh` (Ubuntu, Debian, Fedora)
- [x] Default branch is `main`; non-blocking 24h update check against `origin/main`
- [ ] Real-hardware macOS runs (Homebrew Bash) — BSD logic already covered by simulation tests
- [ ] WSL2 verification

## License

[MIT License](https://github.com/vinyardrip/dpx/blob/main/LICENSE)

Copyright (c) 2026 DPX Contributors
