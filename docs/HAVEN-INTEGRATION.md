# Haven integration contract

This document defines machine schema version 1 for launching DMC as a subprocess. Haven must use the compiled executable through an argument array, set the working directory to the project root, and never assemble a shell command string. Haven must not import DMC's Dart internals or read `.dmc/dmc.db`.

## Compatibility check

Run this before enabling checkpoint controls for a workspace:

```text
[dmcExecutable, capabilities, --json, --schema-version, 1]
```

The command must exit `0`, return `ok: true`, identify `contract: haven-checkpoint-v1`, list machine schema `1`, list checkpoint manifest `1`, and advertise every command Haven needs. An unknown flag or unsupported schema exits `2` with one JSON error object. Haven must treat missing capabilities, an unknown envelope schema, or a different workspace fingerprint as incompatible.

Every JSON command emits exactly one object on stdout, encoded as UTF-8 on every platform (decode stdout as UTF-8; on Windows do not rely on the console code page):

```json
{
  "schemaVersion": 1,
  "dmcVersion": "1.1.0-dev.5.1",
  "ok": true,
  "exitCode": 0,
  "command": "checkpoint.begin",
  "workspace": {
    "path": "/canonical/project/path",
    "fingerprint": "sha256:..."
  },
  "data": {},
  "warnings": [],
  "errors": []
}
```

The workspace path is the canonical local path. The fingerprint is SHA-256 over that canonical path; it identifies the invocation target and is not a content hash. Haven must compare both values across one run. Warnings and errors contain stable `code` and human-readable `message` fields plus an optional relative `path`.

Machine output includes paths, hashes, modes, labels, sources, counts, and lifecycle metadata. It never includes captured file contents. Haven should still treat the JSON as private local project metadata and avoid routine telemetry collection.

## Command data fields

All fields listed here are part of machine schema 1. Additive fields may appear in later DMC builds using the same schema; Haven must ignore fields it does not use. Removing a field, changing its type or meaning, or renaming an enum value requires a new machine schema version.

| Command | Required fields inside `data` |
|---|---|
| `capabilities` | `contract`, `machineSchemaVersions`, `checkpointManifestVersions`, `commands`, `features`, `cancellation` |
| `checkpoint begin` | `checkpoint`, `issues` |
| `checkpoint close` | `checkpoint`, `issues` |
| `checkpoint list` | `limit`, `count`, `checkpoints`; every item includes checkpoint summary fields and `operations` |
| `checkpoint show` | `checkpoint`, `files`, `issues`, `operations` |
| `checkpoint diff` | `checkpoint`, `files`, `issues` |
| `checkpoint restore` / `redo` | `checkpointId`, `direction`, `mode`, `canApply`, `actions`, `conflicts`, `dataErrors`, `applied`, `operationId` |
| `checkpoint recover` | `mode`, `operationId`, `operation`; a blocked recovery also includes `conflicts` |
| `checkpoint recover --preview` | On a valid pending operation: `preview`, `applied`, `canRecover`, `mode`, `operationId`, `checkpointId`, `operation`, `actions`, `conflicts` |
| `checkpoint release` | `checkpoint`, `issues` |

A checkpoint summary includes `id`, nullable `label`, `source`, `status`, `manifestVersion`, millisecond timestamps, `policyFingerprint`, `protectedFileCount`, `changedFileCount`, `exclusionCount`, `fatalErrorCount`, and `agent`. `agent` is additive and null unless an agent hook began the checkpoint; otherwise it holds `name`, `sessionId`, `turnId`, `transcriptPath`, `transcriptBytes` and `transcriptSha256` (the last two set at close). See `docs/AGENT-HOOKS.md`. Status values are `creating`, `open`, `closing`, `closed`, `invalid`, and `released`.

File entries contain a relative `path`, `before` and nullable `after` states, and a nullable `change`. State objects contain `kind`, nullable `snapshotId`, nullable SHA-256 `hash`, and nullable POSIX `mode`. Kind values are `file` and `absent`; change values are `unchanged`, `modified`, `created`, and `deleted`.

Operation summaries include `id`, `checkpointId`, `direction`, `status`, timestamps, and nullable `failureMessage`. Direction values are `restore` and `redo`. Status values are `planned`, `applying`, `completed`, `failed`, `rolling_back`, and `rolled_back`.

Recovery preview is additive in `1.1.0-dev.5.1`, advertised by
`features.operationRecoveryPreview: true`. Use `checkpoint recover <id>
--rollback --preview --json --schema-version 1` (or `--resume`). The command name
remains `checkpoint.recover`; `mode` remains `rollback` or `resume`.
`preview: true` and `applied: false` distinguish this from execution. Every
scoped action includes `sequence`, relative `path`, nullable `current`, `pre`,
`target`, and `noOp`. State objects contain only `kind`, `hash`, and `mode`;
no snapshot IDs, recovery storage names, or contents are included in actions.
Rollback `target` is the journal's **pre-operation state**, not an inferred
checkpoint endpoint. A no-op path remains in scope. Null `current` means the
path could not be inspected, not that it is absent.

Require exit 0, `ok: true`, `canRecover: true`, expected identity/mode/scope and
an empty conflict list. Missing/terminal operations and other early errors need
not have preview data fields. Conflicts include integrity errors (exit 5) and
unsafe/drift conditions (exit 4). Display the preview, obtain explicit approval,
recheck it, then execute without `--preview`. Execution re-runs the shared
preflight; preview is a point-in-time observation, not a reservation against
external writers. See [recovery preview details](RECOVERY-PREVIEW.md).

Restore actions contain `sequence`, relative `path`, expected state, and intended state. Conflicts and data errors contain `code`, `message`, and an optional relative `path`. Haven must decide whether a restore can be offered from `canApply`; it must not infer safety from an empty-looking action list alone.

## Required lifecycle

1. Check `capabilities` and workspace identity.
2. Ensure the workspace has been initialized. If `checkpoint begin` returns `not_initialized`, run `dmc init`, then repeat compatibility and begin checks.
3. Run `checkpoint begin --label <text> --source haven --json --schema-version 1`.
4. Start the agent only when the process exits `0`, `ok` is true, and `data.checkpoint.status` is `open`. Display exclusions and refuse the run when fatal errors are present.
5. Stop the agent and all other automated writers.
6. Run `checkpoint close <id> --json --schema-version 1`. Proceed only when the checkpoint is `closed`.
7. Use `checkpoint diff <id>` or `checkpoint show <id>` to present the result.
8. Before recovery, stop DMC's watcher and every writer. Run `checkpoint restore <id>` without `--apply`. This is a read-only preview.
9. Require a clear user action before invoking the same command with `--apply`. Never add a force option or apply automatically.
10. Use checkpoint redo through the same preview and approval sequence.
11. Keep the checkpoint unreleased while the user may need restore or redo. Release it only through an explicit retention decision.

`checkpoint list --limit <1-1000>` returns recent checkpoints with protection counts, status, exclusions, fatal errors, and operation records. `checkpoint show` returns the selected manifest plus its operation history. These commands let Haven discover IDs after a caller restart without opening SQLite.

## Exit classes

| Exit | Meaning | Haven response |
|---|---|---|
| `0` | Command completed successfully. | Validate `ok`, command name, workspace identity, and expected data state. |
| `1` | Runtime, initialization, database, or unexpected failure. | Stop the run and show the returned error. |
| `2` | Invalid arguments or incompatible requested machine schema. | Treat as an integration/configuration error. Do not retry unchanged. |
| `3` | Checkpoint or operation is missing, invalid, incomplete, or in the wrong lifecycle state. | Refresh with `checkpoint list`/`show` and choose the documented lifecycle action. |
| `4` | Workspace conflict, active watcher, or unsafe current state blocks mutation. | Preserve current files and show the conflict. Never force. |
| `5` | Required stored snapshot data is missing or corrupt. | Perform zero workspace writes, preserve `.dmc`, and report the integrity failure. |
| `6` | A journaled operation is incomplete or another recovery operation is active. | Discover the operation ID and offer resume or rollback. |

The JSON `exitCode` must equal the subprocess exit status. Haven should reject a mismatch.

## Timeouts and cancellation

DMC does not impose a fixed duration on project scans. Haven should use configurable limits based on repository size rather than treating these suggestions as completion guarantees:

- `capabilities`, `checkpoint list`, and `checkpoint show`: allow at least 30 seconds.
- `checkpoint begin`, `close`, `diff`, and restore/redo preview: allow at least five minutes for an initial implementation, with visible progress in Haven when added.
- restore/redo `--apply` and `checkpoint recover`: do not enforce a short hard timeout. Once a journal exists, interruption may leave a temporary mixture of states that requires recovery.

Cancellation has two defined outcomes:

- If begin or close is forcibly terminated, DMC does not write project files. The checkpoint may remain `creating` or `closing`. Run `checkpoint list`, then retry a `closing` checkpoint with `checkpoint close <id>` or explicitly abandon it with `checkpoint release <id>`. A `creating` checkpoint cannot resume and must be released before beginning another.
- If restore, redo, or recovery is forcibly terminated after its journal is created, run `checkpoint show <checkpoint-id>` or `checkpoint list` and find an operation in `planned`, `applying`, `failed`, or `rolling_back`. Stop all writers, then call `checkpoint recover <operation-id> --resume` or `--rollback`. If rollback had started, continue with `--rollback`.

Haven should first request graceful cancellation of its agent and wait for DMC to return. If the DMC process must be killed, Haven must enter a recovery-required state and run discovery on the next invocation before allowing more agent writes.

## Reference harness

After building a native bundle, run:

```bash
dart run tool/haven_reference.dart build/dmc/bundle/bin/dmc
```

Use `build/dmc/bundle/bin/dmc.exe` on Windows. The harness creates and removes a disposable workspace, invokes the compiled executable with argument arrays, and verifies capabilities, schema rejection, paths with spaces/quotes/Unicode, begin/close/list/show/diff, preview, restore, redo, release, workspace identity, and the absence of fixture file contents in JSON.
