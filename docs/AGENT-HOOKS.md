# Agent hooks: verified integration facts

This page records what is known about the hook surfaces of the coding agents that dmc integrates
with, how each fact was established, and where the research disagrees with what was observed. dmc
builds on these facts in `dmc agent-hook` and `dmc hooks` (see "Using it" at the end).

Status key: **verified** = observed on a real install; **researched** = from vendor docs or a
third-party spike, not observed here; **assumed** = a design choice made without evidence.

## Verification runs

| | Claude Code | Muse Code |
|---|---|---|
| Date | 2026-10-26 | 2026-10-26 |
| Machine | Linux x86_64 cloud container, as root | macOS 27.0 (arm64), Mike's Mac, as a normal user |
| Version | 2.1.310 (re-run end to end on 2.1.311 on the Mac) | 1.4.13 (`1.4.13-R6996.1`) |

Probe method: a throwaway git repository under `/tmp` with a Python probe hook that appended
`{event, argv, cwd, stdin, env}` to a log for each event. Scrubbed payloads are in
`test/fixtures/agent_hooks/`. For Muse, `~/.config/muse/settings.json` and `trust.json` were backed
up first and restored byte-for-byte afterwards (checked with `shasum -a 256`).

## Claude Code 2.1.310 (verified)

**Config path that fired:** project-local `<repo>/.claude/settings.local.json` →
`"hooks"`, with `{"<Event>":[{"matcher":"*","hooks":[{"type":"command","command":"…","timeout":10}]}]}`.
It fired in `claude -p` (non-interactive) mode with no trust prompt. It also fired when Claude
Code was launched from a subdirectory of the repository: the settings file at the repository root
was loaded and the payload `cwd` was the subdirectory.

Hook events in this build (from the binary's event table): `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `PostToolBatch`, `PermissionRequest`, `PermissionDenied`, `UserPromptSubmit`,
`UserPromptExpansion`, `SessionStart`, `SessionEnd`, `Stop`, `StopFailure`, `SubagentStart`,
`SubagentStop`, `Notification`, `PreCompact`, `PostCompact`, `Setup`, `TeammateIdle`,
`TaskCreated`, `TaskCompleted`, `Elicitation`, `ElicitationResult`, `WorktreeCreate`,
`WorktreeRemove`, `InstructionsLoaded`, `CwdChanged`, `FileChanged`, `ConfigChange`.
**There is no `Interrupt` event.**

Observed sequences:

- successful turn: `SessionStart` → `UserPromptSubmit` → `Stop` → `SessionEnd`
- API failure (endpoint refused connections): `SessionStart` → `UserPromptSubmit` →
  `StopFailure` → `SessionEnd`. `Stop` did not fire.

Stdin payload fields (all snake_case):

| Event | Fields |
|---|---|
| all | `hook_event_name`, `session_id`, `transcript_path`, `cwd` |
| SessionStart | + `source` (`startup`) |
| UserPromptSubmit | + `prompt`, `prompt_id`, `permission_mode` |
| Stop | + `prompt_id`, `permission_mode`, `effort` (`{"level":…}`), `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons` |
| StopFailure | + `prompt_id`, `effort`, `error` (e.g. `server_error`), `last_assistant_message` |
| SessionEnd | + `prompt_id`, `reason` (`other` for `-p` exit) |

- There is no `turn_id`. `prompt_id` identifies the turn, and dmc stores it as the turn ID.
- `transcript_path` is `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`. It is set even when
  the file does not exist: after the failed run, no transcript was ever written.
- Environment: the hook inherits Claude Code's environment (it is **not** cleared), plus
  `CLAUDE_CODE_SESSION_ID` (= `session_id`), `CLAUDE_PROJECT_DIR` (the repo root) and, on
  SessionStart only, `CLAUDE_ENV_FILE`. Hooks run in the session cwd.

End to end: with hooks written by `dmc hooks install --agent claude-code --apply` (local scope,
compiled bundle), a real `claude -p` turn that wrote `greeting.txt` produced one closed checkpoint
labelled with the prompt, with `greeting.txt: created`, the session ID, the `prompt_id` as turn
ID, and the transcript's size and SHA-256 at Stop. Repeated on macOS with Claude Code 2.1.311 (a
turn that created `hello.txt`): same result, and `dmc hooks uninstall --agent claude-code --apply`
removed the `settings.local.json` it had created (an empty `.claude/` directory is left).

Not verified: whether `Stop` fires when a turn is cancelled with Esc. With no `Interrupt` event,
dmc treats the next `UserPromptSubmit` from the same session as the close for a cancelled turn
(see "Missed Stop" below).

## Muse Code 1.4.13 (verified on macOS)

Research sources, now checked against a real install: dev.meta.ai/docs/muse-code/extending,
/interactive and /changelog (1.4.13), and the third-party spike pj-tmt/tmt#2936 (1.4.7). Each
fact below is marked **verified 1.4.13** (observed by the probe) or **researched** (still
unverified).

**Config paths (verified 1.4.13).** Both fire, with the same file shape: a top-level
`{"hooks":{"<Event>":[{"matcher":"*","hooks":[{"type":"command","command":"…","timeout":10}]}]}}`.

- `~/.config/muse/settings.json` → `"hooks"` fires in `muse exec` and the TUI, in any workspace,
  trusted or not.
- Project `<root>/.muse/hooks.json` fires **only in a trusted workspace**. In an untrusted one,
  `muse exec` printed `Agent delegation: auto unavailable: workspace is untrusted.` and skipped
  the hooks without any warning. Two ways to trust:
  - `muse exec … --trust-workspace` (or `--yolo`) trusts it for that run only and prints
    `workspace trust: trusted source=run-flag`. Nothing is saved.
  - The interactive TUI asks whether to trust the folder on first launch. Accepting adds
    `"<canonical path>": {"decision": "trusted"}` under `"projects"` in
    `~/.config/muse/trust.json`. The path is canonical: `/tmp/muse-probe` was saved as
    `/private/tmp/muse-probe`.
  - Not verified: whether trusting a parent folder (for example `~/Projects`) also covers the
    folders inside it.

**Events (verified 1.4.13 for the ones probed).** Sequences observed:

- `muse exec` success: `SessionStart` → `UserPromptSubmit` → `Stop` → `SessionEnd`.
- Unreachable endpoint (`muse exec … --base-url http://127.0.0.1:9`, four transport retries,
  about 4 s): `SessionStart` → `UserPromptSubmit` → `StopFailure` (twice, see below) →
  `SessionEnd`. `Stop` did not fire.
- Interactive turn cancelled with Esc, then a second prompt: `SessionStart` →
  `UserPromptSubmit` → `Interrupt` → `UserPromptSubmit` → `Stop` → `SessionEnd`. **Stop does not
  fire for the cancelled turn**, and the Interrupt carries that turn's `turn_id`. The probe
  registered Interrupt with `"async": true`, as the docs require.
- The failed run fired a second `StopFailure` with a **different `session_id`** (whose
  `turn_id` equals that session ID, and which has no `sessions/` folder), before the real
  session's StopFailure. It looks like an internal helper session. dmc ignores it because the
  session does not own the checkpoint.
- An interactive launch that stopped at the login screen fired only `SessionEnd`, with
  `"model":"unknown"` and no SessionStart.
- The other researched events (PreToolUse, PostToolUse, PreLLMCall, …) were not probed.

**Stdin payload (verified 1.4.13), snake_case:**

| Event | Fields |
|---|---|
| all | `hook_event_name`, `session_id`, `cwd`, `transcript_path` (**always `null`** in every run), `model`, `permission_mode` (`default`), `model_provider` (`meta`; missing on Interrupt) |
| SessionStart | + `source` (`startup`) |
| UserPromptSubmit | + `prompt`, `turn_id` |
| Stop | + `turn_id`, `stop_hook_active`, `last_assistant_message` |
| StopFailure | + `turn_id`, `error` (`unknown` for a transport error), `last_assistant_message` (the error text) |
| Interrupt | + `turn_id` (no `model_provider`) |
| SessionEnd | + `reason` (`other`); no `turn_id` |

`turn_id` is a UUIDv7 and is the same on a turn's UserPromptSubmit and its Stop, StopFailure or
Interrupt. `model_provider` was not in the research. Interrupt and StopFailure are now
documented here.

**Environment (verified 1.4.13).** Hooks run in the session cwd with a **cleared environment**:
a variable set in the shell that launched `muse` did not reach the hook. The hook received
exactly `HOME`, `LANG`, `LOGNAME`, `MUSE_SESSION_ID`, `MUSE_THREAD_ID`, `OLDPWD`, `PATH`, `PWD`,
`SHELL`, `SHLVL`, `TERM`, `TMPDIR`, `TRACEPARENT` (not on SessionEnd), `USER`, `_` and
`__CF_USER_TEXT_ENCODING`. So:

- **`HOME` is set**, so dmc's transcript fallback works. `XDG_DATA_HOME` is **not** passed
  through. A user who moves Muse's data with it would get no transcript hash, if Muse honors it at
  all (not verified).
- `PATH` was the user's full login `PATH` (`$SHELL` is zsh here). The installer still writes an
  absolute path.
- `MUSE_SESSION_ID` and `MUSE_THREAD_ID` both equal `session_id`.
- Researched, not verified: `$SHELL -c` as the runner, and a fish startup file eating stdin.

**Transcript (verified 1.4.13 on macOS).** It lives at
`~/.local/share/muse/sessions/YYYY/MM/DD/<session-id>/session.jsonl`, the same path as on Linux
(not `~/Library/…`). The date is the **local** date: a session started at 20:17 CDT on Oct 26
(01:17 UTC on Oct 27) went under `2026/10/26`. The file already exists at UserPromptSubmit. A
`.msp-view-g6/<session-id>/` folder of binary indexes sits next to the date folders. Because
`transcript_path` is always null, dmc always uses the fallback search, which looks in every date
folder.

**Researched, not verified:** resume (`muse resume <uuid|name>`, `muse resume --last`; never
`muse exec --session-id <unknown>`, which silently starts a new session), hook output (exit 2 can
block the turn; unknown output keys fail the hook), and the handler fields `statusMessage` and
`if`.

**Other observations:**

- The interactive TUI asked to log in or enter an API key even though `muse exec` already ran
  with the stored key. `muse usage` reports `No subscription allowance`.
- An older `muse-bin-1.4.10` process from another session was running on the Mac during the
  probe. `muse` on `PATH` is 1.4.13.

End to end (verified 1.4.13): after `dmc hooks install --agent muse-code --apply` (user scope,
compiled bundle), `muse exec "Create a file named hello.txt …" --disable-approval` in an untrusted
`/tmp` repo produced one closed checkpoint with source `muse-code`, the session ID, the
`turn_id`, the `session.jsonl` path with its size and SHA-256, and `hello.txt: created`.
`dmc hooks uninstall --agent muse-code --apply` restored `~/.config/muse/settings.json` to its
exact original bytes (same SHA-256).

**Session worktrees, `muse -w` (verified 1.4.13 on macOS, 2026-10-27).** `muse exec -w create
…` (a bare `-w` means `create`) makes a **linked Git worktree inside the repository folder**:

- Path: `<repo>/.muse/worktrees/<YYYYMMDD>-<4 hex>` (for example `.muse/worktrees/20261027-0d52`).
- Branch: `muse/session-<session-uuid>`, created from `HEAD` (or `--worktree-base <ref>`).
- The worktree's `.git` is a file, `gitdir: <repo>/.git/worktrees/<name>`.
- Muse appends `/.muse/worktrees/` to `.git/info/exclude`, so the main work tree's Git (and so
  dmc's Git mode) ignores it. It also keeps reservation state under
  `.muse/worktrees/.session-worktree-reservations/`.
- Muse treats the worktree as the workspace root: hooks run there, and the payload `cwd` is the
  worktree path.
- A clean worktree is removed when the session ends. A dirty one is kept and Muse prints
  `session worktree retained at … (dirty worktree retained)`; remove it with
  `git worktree remove` and delete the `muse/session-…` branch.

Because the worktree sits inside the repository, a hook there used to walk up into the main work
tree's `.dmc/` and record the turn in the wrong vault. See "Other work trees" below.

### To re-verify on a new Muse Code version

1. `muse --version`.
2. In a throwaway git repo, install a probe for SessionStart, UserPromptSubmit, Stop,
   StopFailure, SessionEnd and Interrupt (`"async": true`) in `.muse/hooks.json` only, and run
   `muse exec "reply with the word ok" --max-model-steps 1 --trust-workspace`. Then repeat with
   `~/.config/muse/settings.json` only (back it up and restore it byte-for-byte afterwards).
3. For StopFailure, add `--base-url http://127.0.0.1:9`. For Interrupt, run `muse` and press Esc
   partway through a long reply.

## Contradictions and surprises

- The research gave `turn_id` as a common turn field. That is Muse-only: Claude Code 2.1.310
  sends `prompt_id` instead.
- Claude Code does not clear the hook environment. Muse Code does (verified 1.4.13).
- Claude Code reports a `transcript_path` for a file that does not exist when the turn failed
  before anything was written. dmc records no size or hash when the file is missing.
- Muse Code 1.4.13 sends `transcript_path: null` in every event, so the session-ID fallback is
  the only way dmc finds the Muse transcript.
- Muse's project `.muse/hooks.json` is skipped **silently** in an untrusted workspace, including
  under `muse exec`. That is why the installer's Muse default stays `user`.
- Muse Interrupt handlers are async, so an Interrupt can arrive after the next prompt has begun.
  dmc closes only the checkpoint whose turn ID matches.
- Muse sends `model_provider`, which the research did not list.
- The first Claude Code probe ran on Linux as root. The Muse probe and both end-to-end runs ran
  on the Mac as a normal user.

## Using it

The rest of this page describes what dmc builds on these facts.

### `dmc agent-hook <agent> <event>`

`agent` is `muse-code` or `claude-code`. The event comes from argv; stdin JSON is optional.

| Event | Action |
|---|---|
| UserPromptSubmit | `checkpoint begin --source <agent>`, labelled with the prompt's first line (≤ 100 characters) |
| Stop, StopFailure, SessionEnd (both agents), Interrupt (Muse) | close the active checkpoint if this agent and session own it and, when the event has a turn ID, it is the same turn |
| SessionStart and anything else | nothing |

- **Other work trees:** if the nearest `.git` marker (directory or file) at or above the start
  directory is below the `.dmc/` root found, the turn belongs to another work tree: a linked
  worktree (such as a `muse -w` session), a nested repository or a submodule. The hook records
  nothing and warns on stderr. It uses marker positions only; no git process runs in the hook.
  Each worktree needs its own `dmc init`, and then has its own vault and checkpoints. `status`
  and `doctor` show whether the workspace is a linked worktree, its main work tree, and which
  linked worktrees have a vault.
- **Workspace:** walk up from payload `cwd` (else the process cwd) to the nearest directory that
  contains `.dmc/`. With no workspace, the hook does nothing.
- **Missing stdin:** if stdin is empty, invalid or not an object, the hook rebuilds a minimal
  payload from argv, the process cwd and the session env (`MUSE_SESSION_ID`, then
  `MUSE_THREAD_ID` for Muse; `CLAUDE_CODE_SESSION_ID` for Claude Code).
- **Missed Stop:** on UserPromptSubmit, an active checkpoint owned by the same agent and session
  is closed first. One owned by anything else (a manual checkpoint, Haven, another session) is
  left alone, the new checkpoint is skipped, and a warning goes to stderr.
- **Ownership:** the active checkpoint is checked and closed under one workspace lock, so another
  dmc process cannot swap it in between.
- **Turn match:** a close event with a turn ID (Muse `turn_id`, Claude Code `prompt_id`) leaves a
  checkpoint from a different turn open. That way a late async Muse Interrupt cannot close the
  next turn. SessionEnd has no turn ID and closes any turn in its session.
- **Lock:** a busy workspace lock is retried for up to 5 seconds. Capture itself is not
  interruptible, so the hook timeout must cover a full workspace scan; the installer sets 60
  seconds.
- **Never blocks the agent:** the command always exits 0, prints nothing on stdout, and sends
  warnings to stderr.

Agent context is stored per checkpoint (schema 4 and later): `agent`, `sessionId`, `turnId`,
`transcriptPath` and, at close, `transcriptBytes` and `transcriptSha256` of the transcript
bytes read at that moment. For Muse, a missing `transcript_path` (always, in 1.4.13) falls back
to the session's `session.jsonl`, found by session ID under `$XDG_DATA_HOME` or
`$HOME/.local/share`. It appears as an additive `agent` object (null for non-agent checkpoints)
in machine schema 1 output, and in `checkpoint show`, `checkpoint list` and `status`.

**Git in the hook environment.** In a Git work tree, every hook begin and close runs git (see
AGENTS.md, ignore section). Muse Code 1.4.13 passes the user's full login `PATH` to hooks (see
"Environment" above), and dmc also looks in `/usr/bin`, `/opt/homebrew/bin` and
`/usr/local/bin`. If git still cannot be found, the hook's begin records `git_unavailable` and the
warning goes to stderr; the agent turn is never blocked.

**Prompt delay (macOS arm64, compiled bundle, `dmc agent-hook claude-code UserPromptSubmit` with
the captured fixture piped in, against a `dmc init`'d clone of this repository):**

| Date | Ignore mode | Median | Notes |
|---|---|---|---|
| 2026-10-26 | DMC rules (clone with `website/.gitignore` moved into `.dmcignore`) | 134 ms (8 runs) | 165 ms first run; about 294 ms when it also closed a missed Stop; Stop 174 ms |
| 2026-10-27 | Git mode (fresh clone at `3cd2763` as is, `website/.gitignore` in place, plus `website/node_modules`, `dist` and `.astro`) | 176 ms (10 runs) | range 174–179 ms; Stop 216 ms |

Process startup (`dmc --version`) is about 9 ms. Git mode adds about 40 ms: begin runs git for
detection, the file list and the ignore sources (about nine short git processes in all).

### `dmc hooks install|uninstall|status --agent <agent> [--scope …] [--apply]`

| Agent | `project` | `local` | `user` | Default |
|---|---|---|---|---|
| claude-code | `<root>/.claude/settings.json` | `<root>/.claude/settings.local.json` | `~/.claude/settings.json` | `local` (verified) |
| muse-code | `<root>/.muse/hooks.json` (verified 1.4.13; trusted workspaces only) | not supported | `~/.config/muse/settings.json` (verified 1.4.13) | `user` (always fires) |

- `install` and `uninstall` preview the exact change and write only with `--apply`.
- Uninstall restores the original bytes: it drops a `hooks` object it emptied, writes the file
  in its original layout (single-line or its indent, and its final newline), and deletes a file
  left empty, which is one dmc created. Verified on Muse's `settings.json` (same SHA-256 after
  install and uninstall) and on a created `.claude/settings.local.json` (removed).
- Entries call an absolute path to the running dmc executable. Under `dart run`, pass
  `--dmc-command "<shell command>"`; the same value must be passed to `uninstall` and `status`.
- Install merges into existing config and is idempotent. Uninstall removes only handlers whose
  `command` exactly matches the one dmc would write, and leaves every other hook untouched.
- Muse's Interrupt handler is registered with `"async": true`.
