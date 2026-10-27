# Status

The single place to see where the hackathon build stands. **Coding agents keep this file current**;
the rules are in [AGENTS.md](AGENTS.md#session-status-statusmd).

Last updated: 2026-10-26 by Claude (Muse verification session)

## Done

- Repository created from dmc at the `pre-hackathon` tag (commit `d177c4b`). Everything before the
  tag is pre-existing work; see [HACKATHON.md](HACKATHON.md).
- Repository marked as the hackathon entry: `HACKATHON.md`, README banner, clone instructions,
  agent notes in `CLAUDE.md`.
- `STATUS.md` added, with update rules in `AGENTS.md` and `CLAUDE.md`.
- Published to GitHub as public `EvilMetaMonkey/dmc-meta-hackathon`: `main`, the `pre-hackathon`
  and `v1.0.0` tags, description and topics. Verified with `git ls-remote` and the GitHub API.
- Build plan finalized in the "dmc Hackathon Feature Spec"
  (<https://claude.ai/artifact/P8wKzevNHctpaCvdpw89NY>) and summarized in `HACKATHON.md`: the find /
  fix / remember recovery loop, the Meta model roles, Doc as a separate companion, the schedule and
  the cut order.
- Audited what dmc already has against the plan (recorded in the spec's Tier 1 section). Done
  already: preview-first journaled restore and redo, `status`, `doctor`, `gc`, versioned JSON.
- Agent hook surfaces checked (tasks 1–2 step 1). Claude Code 2.1.310 was **verified** by a probe
  hook in a throwaway repo: `.claude/settings.local.json` fires in `claude -p`, `Stop`,
  `StopFailure` and `SessionEnd` exist (no `Interrupt`), `prompt_id` stands in for `turn_id`, and the
  payload `cwd` is the launch subdirectory. **Muse Code is not installed on this machine** (Linux
  cloud container, not the Mac), and dev.meta.ai is blocked by its network policy, so Muse was built
  against the research and marked unverified. Recorded in `docs/AGENT-HOOKS.md`, with scrubbed
  fixtures (Claude captured, Muse synthetic) in `test/fixtures/agent_hooks/`.
- Schema 3 → 4 migration with agent-turn context per checkpoint (agent, session, turn, transcript
  path, and transcript bytes/SHA-256 at close). Additive `agent` object in machine schema 1 JSON;
  shown in `checkpoint show`, `checkpoint list` and `status`. Verified by a new v3 → v4 migration
  test and by the Haven contract tests passing unchanged.
- `dmc agent-hook <muse-code|claude-code> <event>` (task 2): begin on UserPromptSubmit, close on
  Stop/StopFailure/SessionEnd (plus Muse Interrupt) only for the same agent and session, closes a
  missed Stop on the next prompt, leaves foreign checkpoints alone, retries the lock, always exits 0
  with empty stdout. Verified by 15 tests in `test/agent_hooks_test.dart`, a compiled-bundle smoke
  run (a stdin pipe held open is cut off at 2 s), and **a real Claude Code turn end to end** (one
  closed checkpoint with `greeting.txt: created`, session, turn and transcript hash).
- `dmc hooks install|uninstall|status --agent <agent> [--scope] [--apply] [--dmc-command]`: preview
  by default, idempotent merge, exact-match uninstall. Verified by 7 tests in
  `test/hook_installer_test.dart` and a manual install → re-apply (same hash) → status → uninstall run
  that kept a foreign hook.
- CI flake fixed: `test/agent_hooks_test.dart` read fixtures by a cwd-relative path, and other test
  files change `Directory.current` in the same `dart test` process (PR #1's ubuntu job failed with
  `PathNotFoundException` on `stop_failure.json`). Fixtures now resolve from the package root via
  `Isolate.resolvePackageUriSync`. Verified with plain `dart test` three times in a row (192
  passed each time).
- Root-only test failure confirmed environmental: Cowork ran the full suite as a non-root user
  (192 passed, analyzer clean, contract tests 3 passed).
- **Muse Code 1.4.13 verified on the Mac** (probe in `/tmp`, `docs/AGENT-HOOKS.md`): both
  `~/.config/muse/settings.json` and `.muse/hooks.json` fire; the project file only in a trusted
  workspace (trusted per run by `--trust-workspace`, or saved in `~/.config/muse/trust.json` by
  the TUI prompt), and it is skipped silently otherwise. StopFailure (via
  `--base-url http://127.0.0.1:9`) and Interrupt (Mike pressed Esc in an interactive turn) were
  captured. Stop does not fire after Esc. `transcript_path` is always null. `HOME` is in the hook
  environment and the transcript is at `~/.local/share/muse/sessions/YYYY/MM/DD/<id>/session.jsonl`
  (local date). User `settings.json` and `trust.json` were restored byte-for-byte (SHA-256
  checked). The Muse fixtures are now scrubbed captures, and the default Muse scope stays `user`.
- `dmc hooks uninstall` now restores exact bytes (drops an emptied `hooks` object, keeps the file
  layout and final newline) and deletes a config file it created. A close event's turn ID must
  match the checkpoint's, so a late async Muse Interrupt cannot close the next turn. Verified by
  tests (8 in `test/hook_installer_test.dart`, 16 in `test/agent_hooks_test.dart`).
- **End to end on macOS with the compiled bundle, both agents:** in fresh `/tmp` repos,
  `dmc hooks install --agent <agent> --apply`, then one real turn that created `hello.txt`
  (`claude -p` on 2.1.311, `muse exec` on 1.4.13). Each produced exactly one closed checkpoint with
  the agent as source, the session ID, the turn ID, the transcript bytes and SHA-256, and
  `hello.txt: created` (checked with `checkpoint list --json`, `checkpoint show` and `status`).
  Uninstall removed the created `.claude/settings.local.json` and restored Muse's `settings.json`
  to the same SHA-256.
- Prompt delay measured: `dmc agent-hook claude-code UserPromptSubmit` on a `dmc init`'d clone of
  this repository took a 134 ms median (165 ms on the first run, about 294 ms when it also closed
  a missed Stop).

## In progress

- Nothing yet.

## Broken

- dmc cannot take a checkpoint in this repository as it stands. `checkpoint begin` (and so the
  agent hooks) fails with `Nested .gitignore is not supported. Move protection rules to the root
  .dmcignore before starting DMC.` because of `website/.gitignore`. Each failed begin also leaves
  an `invalid` checkpoint row. Found while timing the hook on a `dmc init`'d clone; the timing
  used a clone with `website/.gitignore` moved into a root `.dmcignore`. This matters for a
  dogfooding demo; not fixed.
- Not verified: whether Claude Code fires `Stop` when a turn is cancelled with Esc (dmc closes it
  on the next prompt either way); whether Muse trust of a parent folder covers the folders inside
  it; whether Muse honors `XDG_DATA_HOME` (it is not passed to hooks).

## Next

Submissions are due Nov 4 at 9:00 PM ET. The build started on Oct 26.

1. Decide how to handle the nested `website/.gitignore` (move its rules into a root `.dmcignore`,
   or support nested ignore files) so dmc can protect this repository for the demo.
2. A new deterministic `dmc checkpoint export <id> --to <dir>` command, for bisect.
3. A worktree check, and the Doc companion skeleton: plain CLI, secret redaction, and one model
   client for Meta Model API and a local Glimmer.
4. Then, per the spec's schedule: lesson library (Oct 29–30), bisect (Oct 31), push-to-talk voice
   (Nov 1), parallel timelines (Nov 1–2), demo and README (Nov 3), submit (Nov 4).

## Session log

Newest first. One entry per session: date, agent, what changed, and anything left half-done.

- 2026-10-26 · Claude · Muse verification on the Mac (branch `hackathon/muse-verify`): fixed the
  fixture-path CI flake, probed Muse Code 1.4.13 (both config paths, StopFailure and Interrupt
  captured), replaced the synthetic Muse fixtures, fixed uninstall byte restoration and turn
  matching on close, ran both agents end to end, and measured the hook at 134 ms. Found the
  nested `.gitignore` blocker. Left open: that blocker.
- 2026-10-26 · Claude · Agent hooks (tasks 1–2): probed Claude Code 2.1.310 (Muse Code not
  installed here), added `docs/AGENT-HOOKS.md` and fixtures, the schema 4 agent-context migration,
  `dmc agent-hook` and `dmc hooks install|uninstall|status`. Verified with tests and a real
  Claude Code turn. Left open: the Muse verification on a machine with Muse Code. Not pushed.

- 2026-10-26 · Claude · Planning session: finalized the build plan, audited existing dmc
  features, and updated `HACKATHON.md` and this file. No code changes.
- 2026-10-26 · Claude · Created the hackathon repository, marked it, added this file, and
  published it to GitHub.
