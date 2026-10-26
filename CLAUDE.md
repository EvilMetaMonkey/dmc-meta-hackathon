# CLAUDE.md

Read **[AGENTS.md](AGENTS.md)** before working in this repository. It is the
authoritative, current guide to dmc's architecture, phase status, safety rules,
database schema, commands, and verification gates. This file used to describe
the original single-table prototype; that description is obsolete.

**This is the Meta AI Developer Hackathon 2026 repository.** Read
**[HACKATHON.md](HACKATHON.md)** too. Everything up to the `pre-hackathon` tag is
pre-existing dmc work; everything after it is hackathon work and must stay that way
(never rewrite or squash history before the tag).

Quick reference (details in AGENTS.md):

```bash
dart pub get --enforce-lockfile
dart run tool/check_analyzer.dart                     # analyzer gate (fails on any diagnostic)
dart test --concurrency=1                             # full test suite
dart test tool/haven_contract_test.dart --concurrency=1   # compiled-bundle contract tests
dart run bin/dmc.dart --help
```

Non-negotiables:
- Awareness over agency: dmc acts on deterministic signals only. No model or
  autonomous inference runs inside dmc.
- All logic lives in `lib/src/`; `bin/dmc.dart` is the only entry point.
- Use the `path` package for every file path (Windows compatibility).
- Restores go through the preview-first, journaled checkpoint path. Do not add
  write paths that bypass it.
