# Agent hooks: verified integration facts

This page records what is known about the hook surfaces of the coding agents that dmc integrates
with, how each fact was established, and where the research disagrees with what was observed. dmc
builds on these facts in `dmc agent-hook` and `dmc hooks` (see "Using it" at the end).

Status key: **verified** = observed on a real install; **researched** = from vendor docs or a
third-party spike, not observed here; **assumed** = a design choice made without evidence.

## Verification run

| | |
|---|---|
| Date | 2026-10-26 |
| Machine | Linux x86_64 cloud container (not the planned Mac), running as root |
| Claude Code | 2.1.310, verified with a probe hook |
| Muse Code | **not installed**. `muse --version` → `command not found`. The Muse probe was skipped, and `~/.config/muse/settings.json` was never touched. `dev.meta.ai` is blocked by this container's network policy, so the docs could not be re-read either. |

Probe method: a throwaway git repository under `/tmp` with a Python probe hook that appended
`{event, argv, cwd, stdin, selected env}` to a log for each event. Scrubbed payloads are in
`test/fixtures/agent_hooks/`.

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

Not verified: whether `Stop` fires when a turn is cancelled with Esc. With no `Interrupt` event,
dmc treats the next `UserPromptSubmit` from the same session as the close for a cancelled turn
(see "Missed Stop" below).

## Muse Code 1.4.x (researched, unverified on this machine)

Sources: dev.meta.ai/docs/muse-code/extending, /interactive and /changelog (1.4.13), and the
third-party spike pj-tmt/tmt#2936 (1.4.7). None of it could be re-checked here.

- **Events:** SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse,
  PostToolUseFailure, PostToolBatch, PreLLMCall, PostLLMCall, PreCompact, PostCompact,
  SubagentStart, SubagentStop, Notification, Stop, StopFailure, SessionEnd, and Interrupt (Esc or
  cancel; the handler must be `async: true`). Stop does not fire on cancelled turns.
- **Config:** the docs name project `<root>/.muse/hooks.json` (runs only once the folder is
  trusted) and user settings. The spike verified only `~/.config/muse/settings.json` → `"hooks"`,
  in the Claude-style shape above. Event names are PascalCase only. Handler fields: `command`,
  `timeout`, `statusMessage`, `async`, `if`. The top-level shape of `.muse/hooks.json` is not
  documented in the research; dmc **assumes** it matches settings (`{"hooks":{…}}`).
- **Stdin (snake_case):** `hook_event_name`, `session_id`, `cwd`, `transcript_path` (may be
  null), `model`, `permission_mode`; UserPromptSubmit adds `prompt`, `turn_id`; Stop adds
  `turn_id`, `last_assistant_message`, `stop_hook_active`; SessionEnd adds `reason`. The
  StopFailure and Interrupt field sets are not documented in the research.
- **Environment:** runs as `$SHELL -c '<command>'` in the session cwd with a cleared environment
  plus a small allowlist. `MUSE_SESSION_ID` and `MUSE_THREAD_ID` hold the session UUID. `PATH`
  may not include dmc, so the installer writes an absolute path. A shell startup file can eat
  stdin (seen with fish), which is why dmc falls back to `MUSE_SESSION_ID`.
- **Transcript:** `~/.local/share/muse/sessions/YYYY/MM/DD/<session-id>/session.jsonl` (JSONL
  envelopes; subagents under `subagent/<id>/`). Not a stability promise.
- **Resume:** `muse resume <uuid|name>`, or `muse resume --last` (TTY only). Never use
  `muse exec --session-id <unknown>` to resume: it silently starts a new session.
- **Hook output:** exit 2 can block the agent's turn, and unknown keys in hook output make the
  hook fail. dmc always exits 0 and prints nothing on stdout.

The Muse fixtures in `test/fixtures/agent_hooks/muse_code/` are synthetic, built from this list.

### To verify on a machine with Muse Code

1. `muse --version`.
2. In a throwaway git repo, install a probe for SessionStart, UserPromptSubmit, Stop,
   StopFailure, SessionEnd and Interrupt (`"async": true`) in `.muse/hooks.json` only, then run
   `muse exec "reply with the word ok" --max-model-steps 1`. Then repeat with
   `~/.config/muse/settings.json` only (back it up and restore it byte-for-byte afterwards).
3. Record which file fired, the real payload fields (especially StopFailure and Interrupt), and
   the env. Replace the synthetic fixtures with scrubbed captures, and change the installer's
   default Muse scope if `project` turns out to work.

## Contradictions and surprises

- The research gave `turn_id` as a common turn field. That is Muse-only: Claude Code 2.1.310
  sends `prompt_id` instead.
- Claude Code does not clear the hook environment, unlike the researched Muse behavior.
- Claude Code reports a `transcript_path` for a file that does not exist when the turn failed
  before anything was written. dmc records no size or hash when the file is missing.
- The verification ran on Linux as root, not on the planned Mac.
