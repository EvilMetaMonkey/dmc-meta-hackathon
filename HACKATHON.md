# Meta AI Developer Hackathon 2026: dmc entry

This repository is Mike Hood's ([@EvilMetaMonkey](https://github.com/EvilMetaMonkey)) entry in the
**Meta AI Developer Hackathon (October–November 2026), indie developer track**.

The entry adds a recovery loop for AI coding agents, powered by Meta's Muse models, on top of
[dmc](https://github.com/EvilMetaMonkey/dmc). dmc is an existing open-source project by the same
author. The hackathon proposal said it would build on dmc, and the proposal was accepted.

## Pre-existing work

Everything up to and including the commit tagged **`pre-hackathon`** was written before the
hackathon started.

| | |
|---|---|
| Baseline tag | `pre-hackathon` |
| Baseline commit | `d177c4bf73901cfac0a4ba7ef068cf24b95a2cb0` |
| Baseline commit date | 2026-10-25 19:00 UTC |
| Tag created | 2026-10-25 19:14 UTC |
| Hackathon kickoff | 2026-10-26 |
| Version at baseline | `1.1.0-dev.5.1` |
| Source of the baseline | [EvilMetaMonkey/dmc](https://github.com/EvilMetaMonkey/dmc) `main` at the same commit |

The baseline commit history was carried over unchanged, so every pre-existing commit keeps its
original author and date. The older `v1.0.0` release tag is also pre-existing.

The baseline already includes:

- local recording of eligible file versions into a project's `.dmc/` folder
- bursts, tasks and marks for grouping saved versions
- `checkpoint begin`/`close` interval checkpoints
- preview-first, journaled restore and redo with conflict checks
- recovery from interrupted operations
- the Haven machine contract
- the terminal UI, the CLI, the install scripts and the project website

## Hackathon work

**Every commit after `pre-hackathon` is hackathon work.** To see exactly what was added during the
event:

```sh
git log --oneline pre-hackathon..main
git diff --stat pre-hackathon..main
```

Or compare on GitHub:
<https://github.com/EvilMetaMonkey/dmc-meta-hackathon/compare/pre-hackathon...main>

### Planned scope

This list is the plan, not a record of finished work. The commit history is the record. The full
plan is the "dmc Hackathon Feature Spec": <https://claude.ai/artifact/P8wKzevNHctpaCvdpw89NY>.

The headline is one recovery loop:

1. **Find it.** Time-travel bisect runs your tests across agent-turn checkpoints to find the turn
   where things broke, without touching your working copy.
2. **Fix it.** Parallel timelines: from the last good checkpoint, three Muse Code agents try three
   different approaches in separate worktrees. You see the test results side by side and pick one.
   The other two are archived, never deleted.
3. **Remember it.** The lesson library saves what went wrong as an approved lesson and offers it to
   any agent that later works on the same files.

Supporting features:

- "Hey Doc" push-to-talk voice (no wake word) and a plain CLI. The terminal UI is set aside for
  the hackathon.
- Natural-language restore ("take me back to before it touched auth"), always with a diff preview
  and a confirmation step
- Agent-turn checkpoints from hooks for Muse Code and Claude Code
- Plain-English per-checkpoint summaries, and `doc --local` to run every model step on the
  user's machine
- Parity work: secret redaction, agent info in `status`, clean `disable`, and a worktree check

If time allows: chat rollback, Codex CLI and Aider support, selective `--path` restore, and a local
web page.

### Meta models

| Model or tool | Where | Job |
|---|---|---|
| Muse Code | local CLI | The demo agent, and the agent in each parallel timeline (`muse exec` headless, one per Git worktree; live since 2026-10-28) |
| Muse Spark 1.3 (`muse-spark-1.3`) | Meta Model API (Baseten Muse Spark Open as the logged fallback) | Natural-language restore: picks a checkpoint and a mode as JSON (`response_format` schema); Doc validates it and dmc previews and applies |
| Muse Spark Open (`meta-models/muse-spark-open-1026`) | Baseten, with Fireworks (`accounts/fireworks/models/muse-spark-open`) as the logged backup (skipped, and reported, when its key is missing or rejected) | The workhorse: lesson drafts and bisect explanations; also the fallback for summaries, briefs and restore |
| Muse Wonder (`muse-wonder-1.0`) | Meta Model API | Plans the three timelines as structured JSON (live since 2026-10-28); judging the results is part 2 |
| Muse Glimmer 30B (`meta-models/Muse-Glimmer-30B`) | A private deployment on Modal (vLLM 0.28.0, one L40S, FP8; `deploy/modal/`), with a logged Baseten fallback; this Mac for `doc --local` | Per-checkpoint summaries and lesson briefs. Lesson matching itself is a fixed rule, not a model |
| Muse Voice Transcribe (`muse-voice-transcribe-1.0`) | Meta Model API, realtime WebSocket (`wss://api.meta.ai/v1/asr/realtime`); live since 2026-10-28 | "Hey Doc" push-to-talk (`doc talk`): speech to text, then the workhorse role picks a Doc command, which runs only after a yes |

Model IDs were confirmed with `GET /models` on 2026-10-27. Role routing, prices and budgets are
in [doc/README.md](doc/README.md).

Theme: **Push the Frontier**.

### How the build is organized

- **dmc, the engine:** stays deterministic, with no models inside it. Hackathon changes are small
  and deterministic, such as a new `checkpoint export` command.
- **Doc, the companion:** a separate program in this repository that runs every AI feature. It
  talks to dmc only through dmc's versioned JSON interface (machine schema 1), and every file change
  goes through dmc's preview-first, journaled restore. The AI never touches your files directly.

### Design rules that still apply

- **Awareness over agency.** Doc suggests; the user decides. Nothing is restored, rolled back,
  forked into timelines or sent to a model without the user asking.
- **Secrets are redacted** before anything is sent to a hosted model.
- **Local-first.** History stays on the user's machine, and `doc --local` keeps model work there too.

## License

MIT, the same as dmc. See [LICENSE](LICENSE).
