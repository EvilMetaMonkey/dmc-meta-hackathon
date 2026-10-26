# Meta AI Developer Hackathon 2026: dmc entry

This repository is Mike Hood's ([@EvilMetaMonkey](https://github.com/EvilMetaMonkey)) entry in the
**Meta AI Developer Hackathon (October–November 2026), indie developer track**.

The entry adds a recovery layer for AI coding agents, powered by Meta's Muse Spark models, on top of
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

This list is the plan, not a record of finished work. The commit history is the record.

- Plain-English checkpoint summaries from Muse Spark (intent, outcome, friction, open items)
- Natural-language restore through Doc ("take me back to before it touched auth"), always with a
  diff preview and a confirmation step
- Chat rollback that forks the agent's session instead of changing it, with an approved "lesson
  note" so the resumed agent doesn't repeat the mistake
- `dmc why file:line` to trace a line back to the burst, prompt, agent and session that changed it
- Doc as both a terminal UI and a local web page, with optional "Hey Doc" voice input
- Parity work: selective restore, secret redaction, `status`, `doctor`, `clean`, clean `disable`,
  `--json` output, and hooks for Claude Code, Codex CLI and Aider

### Design rules that still apply

- **Awareness over agency.** Doc suggests; the user decides. Nothing is restored, rolled back or
  sent to a model without the user asking.
- **Secrets are redacted** before anything is sent to Muse Spark.
- **Local-first.** History stays on the user's machine.

## License

MIT, the same as dmc. See [LICENSE](LICENSE).
