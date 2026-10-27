---
title: Getting started
description: Install a dmc build, start the watcher, and verify protection.
---

:::caution[Development preview]
dmc `1.1.0-dev.5.1` is an unreleased development preview. Use a disposable
project first, and keep Git commits and independent backups. See
[Status & support](/docs/status/) for the exact build guidance.
:::

## 1. Get a build

For an invited trial, use the **exact archive and checksum** supplied by the
maintainer. Extract the whole bundle into a permanent folder — keep `bin/` and
`lib/` together; the SQLite native library is part of the app.

Verify before opening any project:

```sh
dmc --version   # should print dmc version 1.1.0-dev.5.1
dmc --help
```

:::note
On Windows, the executable is `bin\dmc.exe`; never copy only the EXE out of the
bundle. On macOS, if the `dmc` command resolves to Apple's `/usr/bin/dmc`,
refresh your shell (`rehash`) or use the full path to the bundle executable.
:::

### Building from source

You need the source revision, Git, and the Dart SDK (CI uses Dart 3.11.5):

```sh
git clone https://github.com/EvilMetaMonkey/dmc.git
cd dmc
dart pub get --enforce-lockfile
dart test
dart build cli -o build/dmc
./build/dmc/bundle/bin/dmc --version
```

## 2. Protect a folder

Open a terminal in the project folder:

```sh
dmc init      # creates .dmc/ — also adds .dmc/.gitignore for Git repos
dmc start     # captures a baseline, then watches; wait for Ready
dmc status    # expect: Protection: ready
```

`start` runs in the foreground. It first records the eligible files already
present, then watches for changes with a 500 ms debounce. If status says
"not ready", run `dmc doctor` and resolve the reported problem before editing.

## 3. What gets protected

- **Included:** eligible text files under the project root, up to the size
  limit (default 2048 KiB), not excluded by ignore policy.
- **Excluded by default:** `.git/`, `.dmc/`, `.dart_tool/`, `build/`,
  `node_modules/`, binaries, oversized files, and all links.

**In a Git repository, Git decides what is ignored.** dmc protects exactly
the files `git ls-files --cached --others --exclude-standard` lists: nested
`.gitignore` files, negation, character classes and `.git/info/exclude` all
work as in Git, and tracked files stay protected. The default exclusions and
`.dmcignore` apply on top, and submodules are skipped. Git must be installed;
if dmc can't run it, checkpoints stop with `git_unavailable` rather than
guess. `dmc status` shows which mode is active.

**Outside Git**, the ignore language is a deliberate subset (names, root
anchoring, `/dir/`, `*`, `**`, `?`). Negation, character classes and nested
`.gitignore` files are **rejected** rather than silently accepted.
`.dmcignore` always uses this subset. Ignore files are loaded when the
watcher starts — restart after policy changes.

## 4. Day-to-day commands

| Command | What it does |
| --- | --- |
| `dmc log` | Ten most recent saved versions with snapshot IDs |
| `dmc diff <file>` | Compares the working file to its latest snapshot |
| `dmc undo <file>` | Restores the most recent different version |
| `dmc redo <file>` | Restores the state before the latest undo/restore |
| `dmc checkpoint begin/close` | Records a verified whole-run interval |
| `dmc gc --dry-run` | Previews removal of expired, unprotected history |

Cleanup runs only through explicit `dmc gc` — never automatically at startup.

## 5. Stop cleanly

```sh
dmc stop   # waits for pending captures to drain
```

Only one watcher may own a vault. A saved PID is not ownership — dmc uses an
authenticated local control endpoint, and refuses to signal arbitrary PIDs.
