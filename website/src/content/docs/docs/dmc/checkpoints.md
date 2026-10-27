---
title: Checkpoints
description: Record a verified before/after manifest of one agent run.
---

A **checkpoint** covers one serialized run — an agent session, a refactor, a
formatter pass. It is the strongest guarantee dmc offers: a verified
before-state, a verified after-state, and a recovery path that refuses to guess.

## Begin

```sh
dmc checkpoint begin --label "refactor auth" --source haven
```

Begin scans the workspace and records the presence and hash of every eligible
file. It only succeeds in a clean state:

- The workspace must be initialized (`dmc init`).
- No other checkpoint may be active in a blocking state.
- Any fatal scan issue fails the begin — resolve it and start a new checkpoint.

The result is a checkpoint ID (`cp_…`) in `open` state, plus a list of
**exclusions**: ignored, binary, oversized, and linked paths that are outside
the checkpoint guarantee. Exclusions are shown, never hidden.

## Work, then close

Do the work — with the agent, or by hand — then stop all writers and close:

```sh
dmc checkpoint close <checkpoint-id>
dmc checkpoint show <checkpoint-id>
dmc checkpoint diff <checkpoint-id>
```

`diff` classifies each path as `modified`, `created`, or `deleted`. A rename
appears as one deletion plus one creation.

Agents often edit `.gitignore`. If the ignore rules (any `.gitignore`,
`.dmcignore`) or the config changed between begin and close, the close still
succeeds with a `policy_changed` warning, and the new rules decide what is
protected. Files whose protection changed are marked per file:

- **left scope** — protected at begin, ignored at close. Its before-state is
  kept, but restore and redo never touch it.
- **entered scope** — ignored at begin, protected at close. It has no
  before-state, so restore never deletes or overwrites it.

The restore and redo previews list both under **Skipped**. Everything else,
including the edited ignore files themselves, restores as usual.

## Lifecycle

| Status | Meaning |
| --- | --- |
| `creating` | Begin is capturing the before-state |
| `open` | Work may proceed; the after-state is pending |
| `closing` | Close is verifying the after-state |
| `closed` | Verified before/after manifest; ready to restore or redo |
| `invalid` | Capture or verification failed; cannot restore |
| `released` | Retention pins detached after an explicit release |

Only `invalid`, `closed`, and `released` checkpoints allow a new begin.

## Listing and inspecting

```sh
dmc checkpoint list                      # recent checkpoints + protection counts
dmc checkpoint list --limit 100          # accepted range: 1–1000
dmc checkpoint show <checkpoint-id>      # manifest + operation history
```

`show` includes the operation history, so an interrupted apply can be found
even after a restart.

## Export a checkpoint

```sh
dmc checkpoint export <checkpoint-id> --to /tmp/at-checkpoint            # after state
dmc checkpoint export <checkpoint-id> --to /tmp/before --state before
```

Export writes the project as it was at a checkpoint to a new or empty folder
outside the project, verifying every file's SHA-256 and restoring its mode. It
never touches the working copy, and a failed export leaves nothing behind.
Only files dmc protects are exported: ignored dependencies such as
`node_modules` or build output are not.

## Retention

While a checkpoint may still be restored or redo'ed, its snapshots are pinned
against garbage collection. `dmc gc` preserves them. Release only when you no
longer need the checkpoint:

```sh
dmc checkpoint release <checkpoint-id>
```

Release detaches the retention pins (keeping small audit metadata), and is
refused while a restore or recovery operation is incomplete.

## Machine-readable output

Every checkpoint command supports `--json --schema-version 1` and emits exactly
one JSON object on stdout — metadata and hashes, never file contents. See the
[Haven integration contract](/docs/imported/haven-integration/).
