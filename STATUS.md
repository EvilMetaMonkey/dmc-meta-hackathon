# Status

The single place to see where the hackathon build stands. **Coding agents keep this file current**;
the rules are in [AGENTS.md](AGENTS.md#session-status-statusmd).

Last updated: 2026-10-26 by Claude (planning session)

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

## In progress

- Nothing yet.

## Broken

- Nothing known yet. The full test suite (`dart test --concurrency=1`) passed on Oct 26 in the
  dmc repository at the same baseline commit, `d177c4b`. It has not been run in this repository
  yet, and neither has CI.

## Next

Submissions are due Nov 4 at 9:00 PM ET. The build starts when Mike says "let's proceed".

1. Find Muse Code's hook events, transcript location and resume command. The demo and the parallel
   timelines depend on them.
2. Agent hooks for Muse Code and Claude Code that call the existing `checkpoint begin` and `close`.
3. A new deterministic `dmc checkpoint export <id> --to <dir>` command, for bisect.
4. A worktree check, and the Doc companion skeleton: plain CLI, secret redaction, and one model
   client for Meta Model API and a local Glimmer.
5. Then, per the spec's schedule: lesson library (Oct 29–30), bisect (Oct 31), push-to-talk voice
   (Nov 1), parallel timelines (Nov 1–2), demo and README (Nov 3), submit (Nov 4).

## Session log

Newest first. One entry per session: date, agent, what changed, and anything left half-done.

- 2026-10-26 · Claude · Planning session: finalized the build plan, audited existing dmc
  features, and updated `HACKATHON.md` and this file. No code changes.
- 2026-10-26 · Claude · Created the hackathon repository, marked it, added this file, and
  published it to GitHub.
