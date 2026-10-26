# Status

The single place to see where the hackathon build stands. **Coding agents keep this file current**;
the rules are in [AGENTS.md](AGENTS.md#session-status-statusmd).

Last updated: 2026-10-26 by Claude (agent hooks session)

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

## In progress

- Nothing yet.

## Broken

- `dart test --concurrency=1` on 2026-10-26 in this repository (Linux container, Dart 3.11.5, as
  root): 191 passed, 1 failed. The failure is
  `test/recovery_preview_test.dart: unreadable target blocks preview and retains bytes and modes`
  (expected exit 4, got 0). The test makes a file unreadable with `chmod 000`, but root can still
  read it. It fails the same way on the untouched baseline (168 passed, 1 failed), so it is
  environmental, not a regression. It should pass as a normal user and in CI; not yet confirmed.
  `dart run tool/check_analyzer.dart` and `dart test tool/haven_contract_test.dart --concurrency=1`
  (3 passed) are clean. CI has not run on this repository yet.
- Muse Code hooks are untested against a real Muse install: which config path fires, the
  `.muse/hooks.json` file shape, and the StopFailure/Interrupt payloads are unverified. Steps are
  in `docs/AGENT-HOOKS.md` ("To verify on a machine with Muse Code").

## Next

Submissions are due Nov 4 at 9:00 PM ET. The build started on Oct 26.

1. On the Mac with Muse Code installed: run the Muse probe in `docs/AGENT-HOOKS.md`, replace the
   synthetic Muse fixtures with captures, fix any payload or config differences, and change the
   default Muse scope if `.muse/hooks.json` works. Then run `dmc hooks install --agent muse-code`
   and one real Muse turn end to end. Also run the full suite as a non-root user to confirm the
   recovery-preview failure is root-only.
2. A new deterministic `dmc checkpoint export <id> --to <dir>` command, for bisect.
3. A worktree check, and the Doc companion skeleton: plain CLI, secret redaction, and one model
   client for Meta Model API and a local Glimmer.
4. Then, per the spec's schedule: lesson library (Oct 29–30), bisect (Oct 31), push-to-talk voice
   (Nov 1), parallel timelines (Nov 1–2), demo and README (Nov 3), submit (Nov 4).

## Session log

Newest first. One entry per session: date, agent, what changed, and anything left half-done.

- 2026-10-26 · Claude · Agent hooks (tasks 1–2): probed Claude Code 2.1.310 (Muse Code not
  installed here), added `docs/AGENT-HOOKS.md` and fixtures, the schema 4 agent-context migration,
  `dmc agent-hook` and `dmc hooks install|uninstall|status`. Verified with tests and a real
  Claude Code turn. Left open: the Muse verification on a machine with Muse Code. Not pushed.

- 2026-10-26 · Claude · Planning session: finalized the build plan, audited existing dmc
  features, and updated `HACKATHON.md` and this file. No code changes.
- 2026-10-26 · Claude · Created the hackathon repository, marked it, added this file, and
  published it to GitHub.
