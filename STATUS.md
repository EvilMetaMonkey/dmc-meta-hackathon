# Status

The single place to see where the hackathon build stands. **Coding agents keep this file current**;
the rules are in [AGENTS.md](AGENTS.md#session-status-statusmd).

Last updated: 2026-10-28 by Claude (timelines part 1 session)

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
- PR #2 (`hackathon/muse-verify`): CI passed on ubuntu, macOS, macOS Intel and Windows in both
  the push and pull_request runs for the code commits, including the ubuntu job that flaked on
  PR #1. A later docs-only commit hit a separate, older flake (see Broken); rerunning the failed
  jobs passed.
- Older-test CI flake resolved (approved by Mike): five test files (`checkpoint_test`,
  `checkpoint_restore_test`, `dmc_test`, `snapshot_store_test`, `watcher_hardening_test`) set the
  process-wide `Directory.current` across async gaps, which raced under plain `dart test`'s
  parallel isolates (PR #2 runs 40434543893 and 40435853311). CI's test step is now
  `dart test --concurrency=1`, the documented gate, so the files run one at a time.
- **Git-compatible ignore handling** (approved by Mike; branch `hackathon/git-ignore`). Inside a Git
  work tree, Git decides what is ignored: the protected list is
  `git -C <root> ls-files --cached --others --exclude-standard -z`, with DMC's default
  directories, `.dmcignore`, link/size rules on top, and gitlinks, submodules and nested repos
  excluded. Outside Git nothing changed. A Git work tree without a usable git fails with
  `git_unavailable`/`git_failed` (no silent fallback). The policy fingerprint (version 2) covers
  the mode and every ignore source Git reads. Checkpoint restore and redo refuse Git-ignored
  targets (`git_ignored`). The watcher batches Git checks through one `git check-ignore --stdin -z`
  per drain. `status` and `doctor` show the ignore policy. This fixes the Broken item "dmc cannot
  take a checkpoint in this repository" (`website/.gitignore`). Verified by 10 new tests in
  `test/git_ignore_test.dart` (204 total), and by these dogfood runs with the compiled bundle:
  - A fresh GitHub clone of this repo at `3cd2763`, with `website/.gitignore` in place plus
    `website/node_modules`, `dist` and `.astro`: begin → edit `HACKATHON.md` → close gave one
    closed checkpoint (119 protected, 1 modified, 0 fatal). The protected set was identical to
    `git ls-files -co --exclude-standard`, and `website/node_modules`, `dist`, `.astro` and `.dmc`
    were excluded.
  - A repo with GitHub's standard Node template at the root and the Python template in `api/`
    (github/gitignore `main` at `0e5d690`; 6 and 1 negations, and a character class each): 8
    protected files, identical to Git's list. Negation re-included `.yarn/patches` and
    `.yarn/releases`, and `node_modules`, `dist`, `.env`, `__pycache__`, `.venv`, `build` and
    `*.egg-info` were excluded. Close also succeeded after a mid-turn
    `api/.pytest_cache/.gitignore`.
- PR #3 (`hackathon/git-ignore`): CI passed on ubuntu, macOS, macOS Intel and Windows in both the
  push and pull_request runs for `408f28b` (and for `3cd2763`); Windows ran all 10 Git-mode tests.
- Prompt delay in Git mode, against that clone: `dmc agent-hook claude-code UserPromptSubmit`
  median 176 ms over 10 runs (174–179 ms); Stop 216 ms. Was 134 ms with DMC's own rules.
- **Ignore-policy drift handled per file** (Mike chose per-file handling; branch
  `hackathon/export-drift`). When the ignore policy or config changes between begin and close,
  close succeeds with a non-fatal `policy_changed` warning. Both fingerprints are recorded, and
  files whose protection changed are `left_scope` (before state kept, no after state) or
  `entered_scope` (no before state). Restore and redo list them under `skipped` and never write
  them; redo of a changed `entered_scope` file is a `workspace_drift` conflict. Schema 5 adds two
  nullable columns without rewriting rows. This fixes the Broken item "a turn in which the agent
  edits an ignore source cannot close". Verified by 6 tests in `test/policy_drift_test.dart`, a
  v4 → v5 migration test, and an end-to-end run with the compiled bundle: a real `claude -p` turn
  (hooks installed) deleted `*.log` and added `notes.txt` in `.gitignore`. Close recorded
  `debug.log` as entered_scope and `notes.txt` as left_scope; the restore preview listed both
  under Skipped; apply restored `.gitignore` and `app.txt` and left both skipped files
  byte-identical (same SHA-256).
- **`dmc checkpoint export <id> --to <dir> [--state before|after]`** (for bisect). Verified by 7
  tests in `test/checkpoint_export_test.dart` (before/after, modified/created/deleted, modes, a
  corrupted snapshot leaving nothing behind, refused targets including a link into the
  workspace, an open checkpoint, left/entered_scope, CLI JSON and capabilities). In the
  end-to-end run, diffing the before and after exports against the restored working copy showed
  only the expected differences. On a clone of this repo at `b0b8040`: 121 files, 1,157,446
  bytes (1.4 MB on disk), median 40 ms over 5 runs, identical to the working copy minus ignored
  paths.
- Gates for this branch: analyzer clean, `dart test --concurrency=1` 218 passed, Haven contract
  tests 3 passed unchanged. PR #4 CI passed on ubuntu, macOS, macOS Intel and Windows in both the
  push and pull_request runs for `c7bb435` (and the push run for `b0b8040`).
- **Worktree check** (branch `hackathon/doc-skeleton`). `muse -w` (Muse Code 1.4.13, verified on
  the Mac) creates a linked worktree inside the repository at
  `<repo>/.muse/worktrees/<YYYYMMDD>-<4 hex>`, on branch `muse/session-<uuid>`, adds
  `/.muse/worktrees/` to `.git/info/exclude`, removes a clean worktree at session end and keeps a
  dirty one. A hook there used to record the turn in the main vault. `dmc agent-hook` now does
  nothing (stderr warning, exit 0, empty stdout) when the nearest `.git` marker above its cwd is
  below the `.dmc` root, using marker positions only. `status` and `doctor` report a linked
  worktree and its main work tree, or a main work tree's linked worktrees and which have a vault.
  Verified by 5 tests in `test/worktree_test.dart`:
  - a hook from a worktree with no vault records nothing in the main vault;
  - after `dmc init` there, checkpoints go to the worktree's own vault;
  - two worktrees taking turns get independent checkpoints, each restored on its own;
  - a nested repo and a submodule are ignored;
  - status and doctor print the layout.

  dmc suite: 223 passed.
- **Doc companion skeleton** in `doc/` (separate package `dmc_doc`; dmc still runs no models).
  It has one OpenAI-compatible client (meta, baseten, local) with retries, timeouts, the one
  logged meta → baseten fallback for `restore`, budgets and usage in `~/.config/dmc-doc/`, a
  redaction module, and `doc models [--check] [--available]`, `doc summarize`, `doc usage`. It
  reads dmc only via `--json --schema-version 1`. CI analyzes and tests `doc/`. Verified by 41
  Doc tests (fake HTTP servers for every provider path, redaction cases, and a compiled dmc in a
  temp workspace), plus these real calls on the Mac:
  - The real model IDs from meta `GET /models` are `muse-spark-1.3`, `muse-wonder-1.0` and
    `muse-voice-transcribe-1.0`. Muse Glimmer is not on the Meta API.
  - `doc models --check`: baseten ok in 937 ms, meta `muse-spark-1.3` ok in 2,044 ms, local
    reports plainly that Ollama has no `muse-glimmer`.
  - `doc summarize` on a real Claude Code checkpoint from a `/tmp` repo worked on baseten (1.8 s,
    $0.0020) and on meta (2.4 s, $0.0025).
  - Real use so far: meta $0.0034 (2 calls), baseten $0.0100 (4 calls) in `usage.json`, plus
    about $0.006 of manual Baseten probes.
  - Found and fixed: Muse Spark Open spends small token limits on reasoning (`finish_reason:
    length`, null content). Doc now reports `truncated`, and sends `reasoning_effort: low` to
    Baseten too (1,403 → 537 completion tokens on the same prompt).
- Mike's `~/.zshrc` line 46 (`api.meta.ai api key=…`) was not a shell assignment. With his
  approval it was rewritten to `export MODEL_API_KEY='…'` without reading the value (backup:
  `~/.zshrc.backup-20261027-155542`, mode 600).

- Windows watcher-test flake fixed (test only): `test/watcher_hardening_test.dart` ("real create,
  rename, directory move and atomic replacement are captured") deleted `renamed.txt` while the
  watcher could still have it open (errno 32 on run 40540474040). The delete now retries up to 20
  times, 100 ms apart, before failing.
- **Doc providers `modal` and `fireworks`** (branch `hackathon/glimmer-lessons`). Provider
  request style is now configuration (reasoning effort, token-limit field, sampling, Glimmer's
  `Reasoning strength:` system line), and reasoning text is stripped from answers.
  - `modal`: Muse Glimmer on Mike's own Modal deployment. The base URL comes from the config or
    `DOC_MODAL_BASE_URL` and the key from `MODAL_GLIMMER_KEY`. It has a 600 s timeout, a wake
    notice after 10 s, and is billed by GPU time.
  - `fireworks`: `accounts/fireworks/models/muse-spark-open`, verified with `GET /models`;
    serverless at $1.25 / $4.25 per million tokens.
  - Roles: `summary` modal → baseten, `workhorse` baseten → fireworks, always logged, no second
    hop. `--local` refuses Modal.
  - Verified by Doc tests with fake providers (fallback chains, an unconfigured Modal,
    `DOC_MODAL_BASE_URL`, `--local` refusing Modal, the wake notice, reasoning stripping).
  - A real `doc models --check` on 2026-10-27: Fireworks ok in 4.2 s (151 in / 54 out, $0.0004),
    Baseten in 1.1 s, meta in 1.4 s.
- **Modal app for Muse Glimmer 30B** (`deploy/modal/glimmer.py` and its README), written but not
  deployed (see Broken).
  - Serving: Meta's official `meta-models/Muse-Glimmer-30B` (pinned `cec94fc…`) on vLLM 0.28.0
    with the `muse_glimmer` reasoning and tool parsers, per the official vLLM recipe. One L40S,
    FP8 at load, 32k context, text only.
  - Operation: weights cached in a Modal Volume; scales to zero after 5 idle minutes, with at
    most 1 container; bearer key from a Modal Secret.
  - Set up on the Mac: the Modal CLI 1.6.3 (logged in to your Modal workspace), the
    `muse-glimmer-api-key` secret, the two Volumes (empty), and `MODAL_GLIMMER_KEY` in
    `~/.zshrc` (never printed).
- **Lesson library, part 1** (Doc only). Markdown lessons with YAML front matter live in Doc's
  data dir, keyed by dmc's workspace fingerprint; drafts are kept apart. Commands: `doc lesson
  draft | edit | approve | reject | show | brief`, `doc lessons [--files] | path`, and `doc start
  <muse-code|claude-code> "<task>" [--yes]`. Matching is a fixed rule (exact path or unique
  basename, plus `--files`; score = file overlap; ties go to the newest; top 3).
  - Verified by 13 new Doc tests: front matter round trip, approval rules, matching cases,
    first-prompt composition, draft redaction, `--show-prompt` and `--local`, brief skipped on no
    match, and `start` with a fake agent for yes, no and no match.
  - Verified end to end in `/tmp/lesson-demo`:
    1. A real Claude Code turn made `apply_discount` take a 0–1 fraction, so `checkout.py`
       printed -1920.0.
    2. `dmc checkpoint restore --apply` brought back 60.0.
    3. `doc lesson draft` (Baseten) wrote the lesson, with files `[pricing.py]` from the
       checkpoint. One phrase was corrected by hand, as `doc lesson edit` allows, then the lesson
       was approved.
    4. Mike ran `doc start muse-code "Add a bulk_discount function to pricing.py …" --yes` in a
       real terminal. Muse Code's first prompt was the brief, a blank line, then the task (seen in
       its transcript and its dmc checkpoint label). Muse kept the 0–100 contract.

    The brief came from Baseten through the logged `summary` fallback, since Modal is not up.
- PR #6 (`hackathon/glimmer-lessons`): CI passed on ubuntu, macOS, macOS Intel and Windows in both
  the push and pull_request runs for `0256ab8`. dmc ran 223 tests (Windows 221 plus 2 skipped)
  and Doc 63 on every platform.
- Muse Code takes an initial interactive prompt as `muse "<prompt>"` (verified on 1.4.14;
  recorded in `docs/AGENT-HOOKS.md`).
- Mike's `~/.zshrc` lines 46 (Meta key) and 49 (Fireworks key) were not shell assignments. With
  his approval they were rewritten to `export MODEL_API_KEY='…'` and
  `export FIREWORKS_API_KEY='…'` without reading the values (backup:
  `~/.zshrc.backup-20261027-204740`, mode 600).
- Demo cleanup: Muse's `settings.json` hooks were uninstalled (same SHA-256 as before), and the
  `/private/tmp/lesson-demo` trust entry Mike accepted was removed from Muse's `trust.json`.
- **`doc restore` (rollback without amnesia) and lesson library part 2** (branch
  `hackathon/rollback-lessons`, Doc only; dmc unchanged).
  - `doc restore <id>` previews dmc's restore in plain terms and asks before anything changes.
    It applies through dmc's journaled restore and never forces a conflict or recovery. After an
    apply it offers to draft a lesson and asks, optionally, what went wrong. `--yes` is for demos
    only, and `--no-lesson` skips the lesson.
  - `doc lesson draft --last-restore` finds the latest applied restore through dmc's existing
    schema 1 JSON (`checkpoint list` operations), skipping one a later redo reapplied.
  - Drafts now include the abandoned work as a redacted diff, built from `dmc checkpoint export`
    of the before and after states in a temporary directory outside the workspace. Labels that
    dmc truncated are marked as truncated.
  - Verified by 9 tests in `doc/test/restore_cli_test.dart`: "no" changes nothing; "yes"
    applies and drafts; a conflict is not forced; `--no-lesson`; `--last-restore` (including
    after a redo); the abandoned diff is redacted; `--local` refuses hosted; a truncated label
    is marked.
  - Real check on the Mac, 2026-10-28:
    1. A Claude Code turn in `/tmp/rollback-demo` made `parse_amount` return float dollars, and
       `test_money.py` failed.
    2. `doc restore` (answers piped in) restored `money.py`, and the tests passed again.
    3. It drafted a lesson. That draft could only say the change was rolled back, which led to
       the new "What went wrong?" question.
    4. A redraft with `doc lesson draft --last-restore --note …` was approved and is listed in
       `doc lessons`.

    Cost: 2 Baseten calls, $0.0047.
- PR #7 (`hackathon/rollback-lessons`): CI passed on ubuntu, macOS, macOS Intel and Windows in
  both the push and pull_request runs for `a9818a6`. dmc ran 223 tests (Windows 221 plus 2
  skipped) and Doc 73 on every platform.
- Cleanup: stopped tracking `deploy/modal/__pycache__/` (now ignored), removed the Modal
  workspace name from the docs, and defaulted `summary` to Baseten with a Fireworks fallback.
  Modal Glimmer is an opt-in.
- PR #8 (`hackathon/bisect`): CI passed on ubuntu, macOS, macOS Intel and Windows in both the push
  and pull_request runs for `97179b8`. dmc ran 223 tests (Windows 221 plus 2 skipped) and Doc 88
  on every platform. The `macos-latest` jobs were first cancelled after waiting 15 minutes for a
  runner (no steps ran); rerunning them passed.
- Fixed a Doc test flake seen on `6f3503c` (macos-latest, push run): `cli_test.dart` asserted the
  summarize prompt did not contain `abc`, the fake `.env` value, but a random checkpoint ID
  (`…23cabcd3a866`) contained it. The fixture now uses a value that lowercase hex cannot contain.
- **`doc bisect` (time-travel bisect)** (branch `hackathon/bisect`, Doc only; dmc unchanged).
  - What it does: finds the first agent turn after which `--test` fails, by testing
    `dmc checkpoint export` states in temporary folders, never the working copy. It checks both
    ends first, then runs a pure binary search (`bisectFirstBad`). It supports `--setup`,
    `--link`, `--timeout` (a timeout is a failure), `--from`/`--to`/`--all` and `--keep`.
  - Output: the first bad turn, the last good point, the failing output tail and a workhorse
    explanation (unless `--no-explain`). Then a restore is offered through the `doc restore`
    flow. `--json` prints one result object.
  - Verified by 3 pure tests and 12 CLI tests with a compiled dmc and fake providers:
    - first bad turn in the middle, first and last;
    - both-ends checks, with no model call;
    - invalid checkpoints skipped;
    - a timeout counted as a failure;
    - `--link`, `--setup`, and a suggested setup never run without a yes;
    - temporary folders removed on success, on failure and on a crashing test;
    - the working copy byte-identical afterwards;
    - a failed explanation still printing the result;
    - `--local` refusing hosted providers;
    - the JSON shape;
    - an accepted restore.
  - Real check on the Mac, 2026-10-28: six real turns in a `/tmp` Python repo, alternating
    Claude Code (1, 3, 5) and Muse Code `muse exec` (2, 4, 6). Turn 3 made `round_money` round to
    one decimal.
    - `doc bisect --test "python3 -m unittest -q"` found turn 3 in 5 probes (probes 0.2 s, run
      5 s).
    - The explanation was correct.
    - The accepted restore put back `money.py`, and all 6 tests passed with the later turns
      intact.
    - Cost: one Baseten call, $0.0029.
    - Afterwards both hooks were uninstalled (Muse `settings.json` back to the same SHA-256) and
      the repo was removed.

- **Bisect `--link` cleanup test** (branch `hackathon/glimmer-nl-restore`): cleanup removes only
  the symlink; the linked working-copy folder and its nested files survive a successful bisect,
  one whose tests already fail, and one whose test command crashes. Verified by a new test in
  `doc/test/bisect_cli_test.dart`.
- **Muse Glimmer deployed on Modal** as written: Meta's official `meta-models/Muse-Glimmer-30B`
  (pinned revision), vLLM 0.28.0 with the `muse_glimmer` parsers, one L40S with FP8 (it fits:
  28.6 GiB of weights, 12 GiB of KV cache), at most 1 container, scale to zero after 5 idle
  minutes. The A100 fallback was not needed.
  - The URL is only in `DOC_MODAL_BASE_URL` in Mike's `~/.zshrc` (backup
    `~/.zshrc.backup-20261028-151453`, mode 600), never printed or committed.
  - Measured: cold `doc models --check` 94.1 s; warm 2.4 s and 2.1 s; a warm `doc summarize` on
    a real Muse Code checkpoint 11.1 s (245 in / 233 out); 0 containers about 6 minutes after
    the last request, seen twice (`modal app list`, `modal container list`). Spend: $0.93
    metered, $0.00 billed after credit.
  - Found and fixed: Modal's web proxy answered Doc's chunked request bodies with HTTP 500, so
    Doc now sends a Content-Length.
  - `summary` is back on modal Glimmer by default, with a logged Baseten fallback (also when no
    deployment is configured).
- **Fireworks unavailable handling.** A fallback whose key is missing or rejected (401/403) is
  logged as "`<provider>` unavailable (…)", skipped for the rest of the run, and the primary's
  error is reported. `doc models --check` reports "fireworks unavailable" without failing when
  Fireworks is only a fallback. Verified by 3 router tests and 1 CLI test (missing and rejected
  key). Mike's current Fireworks key is still accepted (checked with `GET /models`).
- **Meta accepts `response_format`** with a strict JSON schema (2026-10-28, `muse-spark-1.3`:
  HTTP 200, the answer in the schema's shape). Baseten accepts it too and enforces it (it kept
  to the schema when the prompt asked for plain text). Fireworks, Modal and local are not sent
  it.
- **Natural-language restore** (`doc restore "<request>"`; Doc only, dmc unchanged). Candidates,
  the model's JSON answer, the pure validation (`planNaturalRestore`), the choice screen
  (never skipped by `--yes`), per-step dmc previews combined by `combineStepPreviews` (pure)
  with line counts from exports, one confirmation, newest-first apply through dmc, the redo
  offer after a failure, and the lesson offer. Verified by 15 pure tests
  (`doc/test/nl_restore_test.dart`) and 12 CLI tests with a compiled dmc and fake providers
  (`doc/test/nl_restore_cli_test.dart`): an id not offered is refused after one retry; a
  malformed answer is retried; low confidence shows the choices and nothing is applied without
  a pick; go_back_before applies newest first; undo_turn applies one step; a preview conflict
  blocks; a failure mid-apply stops and the offered redo puts it back; "no" leaves the working
  copy byte-identical; truncated labels are marked; the request and labels are redacted;
  `--local` refuses hosted; the JSON shape; a checkpoint ID keeps the old flow.
  - Real check on the Mac, 2026-10-28, in `/tmp/nl-demo` with both agents' hooks: six real
    turns (Claude Code `slugify` in `utils.py`; Muse Code `hmac.compare_digest` in `auth.py`;
    Claude Code README; Muse Code `health()` in `app.py`; Claude Code `test_utils.py`, once with
    no change and once created). `doc restore "take me back to before it touched auth"` picked
    the Muse auth turn at confidence 0.95 and planned 5 steps; the applied result was
    byte-identical to `dmc checkpoint export --state before` of that turn, with turn 1 kept.
    `doc restore "undo what claude did"` came back at 0.55 and showed the four Claude Code
    turns; Enter cancelled it. The undone work was put back with `dmc checkpoint redo --apply`.
    Hooks were uninstalled (Muse `settings.json` back to the same SHA-256), the demo lesson
    draft was rejected and the repo removed. Cost: meta $0.022 (incl. two manual probes),
    baseten $0.0056, fireworks $0.0020, Modal GPU time as above.
  - Gates on the Mac: dmc analyzer clean, `dart test --concurrency=1` 223 passed, Haven contract
    tests 3 passed; Doc `dart analyze --fatal-infos` clean, 121 tests passed.
  - PR #9 (`hackathon/glimmer-nl-restore`): CI passed on ubuntu, macOS, macOS Intel and Windows in
    both the push and pull_request runs for `303d296`. dmc ran 223 tests (Windows 221 plus 2
    skipped), the Haven contract 3 and Doc 121 on every platform.
  - The agents ran without blanket approval: Claude Code with `--allowedTools Read
    "Edit(<file>)"` and Muse Code with its defaults plus `--disable-shell --disable-web-tools`
    (a blanket-approval launch was refused by this session's permission check).

- **Lesson drafts no longer invent reasons** (branch `hackathon/voice`). A real draft after an NL
  restore had been titled "Do not modify protected auth.py" for what was a good security fix.
  Without a "What went wrong?" note the prompt now says the reason is not stated and must not be
  guessed, the title describes the undone work, Doc sets "Why it failed" to "Not stated — add the
  reason before approving." whatever the model writes, and `doc lesson approve` refuses that
  draft until it is edited. Verified by a new test in `doc/test/lesson_cli_test.dart` (fake
  provider; checks the prompt text for the no-note case, the replaced section, the refused
  approval, and that a note still goes through).
- **"Hey Doc" push-to-talk** (`doc talk`, alias `doc hey`; Doc only, dmc unchanged).
  - Meta's realtime docs, read on 2026-10-28, differ from what we expected:
    - The key goes in a JSON handshake frame (`authorization.accessToken: "Bearer …"`,
      `audioEncoding` `PCM_16KHZ`/`PCM_24KHZ`, `model`, `mode: PUSH_TO_TALK`, `partialMode`,
      `keywords`); the Authorization header is ignored. The reply is `{sessionId}`.
    - Audio goes as raw binary PCM16 frames (Doc sends 80 ms, as Meta's example does), paced in
      real time (1008 on backlog or slow ingress).
    - `{"type":"endStream"}` ends input.
    - Events are `transcript` (`transcript`, `final`, `audioProcessedMs`), `audioProgress`,
      `speechStart`/`speechEnd`/`speechComplete`, `speaker` and `error`.
    - There is no `session.update`, `input_audio_buffer.*`, `…transcription.delta`/`completed`
      or usage event.
    - A buffered upload endpoint does exist (`POST /v1/asr/transcribe`, multipart WAV ≤ 10 min);
      Doc does not use it.
    - Price: $0.18 per hour of audio, whole seconds, rounded down.
    - All of this is recorded in `doc/README.md`.
  - Behaviour:
    - Space or Enter starts and stops (30 s at most), Esc cancels without `endStream`, and the
      terminal is restored on every path.
    - `--file` streams at real-time pace (PCM16 WAV read directly, else sox or ffmpeg converts).
    - File names from recent checkpoints are sent as recognition `keywords`.
    - The redacted transcript is routed by the workhorse role (JSON schema, one retry).
      `planVoiceAction` (pure) maps it to one command, and nothing runs without "Run it? [y/N]"
      (`--yes` never answers it for restore or bisect).
    - Restore gets the transcript itself.
    - `--local` is refused.
    - Usage records billed audio seconds.
    - Also new: `doc status` and a per-workspace `bisectTest` config.
  - Verified by 7 client tests against a fake realtime server (handshake fields, paced 80 ms
    frames ≤ 4 s, `endStream`, partials, final transcript, error event, 1008, refused handshake,
    cancel sends nothing more), 9 pure routing tests, and 10 CLI tests:
    - `--file` streaming;
    - "no" runs nothing;
    - "yes" runs NL restore with the transcript;
    - `--yes` refused for restore but used for lessons;
    - unknown and low confidence;
    - redaction;
    - bisect from config and summarize_latest;
    - `--local`;
    - live turn with the terminal restored;
    - Esc before and during a turn;
    - a 1008 error with the terminal restored and the pending key drained.
  - Real check on the Mac, 2026-10-28, in `/tmp/voice-demo` (both hooks; four real turns, Muse
    Code's turn 2 rewrote `auth.py`):
    - `doc talk --file` on a 2.3 s `say -v Karen` WAV of "take me back to before it touched
      auth". The transcript came 188 ms after the end of the audio (149–195 ms over 7 runs) and
      was exact, so Doc ran NL restore. Muse Spark picked the auth turn at 0.95 and planned 3
      steps; "n" at apply changed nothing. Whole run 8.1 s.
    - With the default `say` voice "auth" came back as "off" (keywords did not fix it). The
      restore then went to the choice screen at 0.40, and nothing changed.
  - Cost: 7 transcriptions, 14 s billed ($0.0007); 7 Baseten routing calls ($0.0097); 2 Meta
    restore calls ($0.0088).
  - Hooks uninstalled (Muse `settings.json` back to the same SHA-256), repo removed.
  - Gates on the Mac: dmc analyzer clean, 223 tests, Haven contract 3; Doc analyze clean, 148
    tests. PR #10 (`hackathon/voice`): CI passed on ubuntu, macOS, macOS Intel and Windows in
    both the push and pull_request runs for `bf3d9fe`. dmc ran 223 tests (Windows 221 plus 2
    skipped), the Haven contract 3 and Doc 148 on every platform.

- **Parallel timelines, part 1** (`doc timelines`, branch `hackathon/timelines-1`; Doc only,
  dmc unchanged): base from `dmc checkpoint export`, Muse Wonder plans exactly N approaches
  (validated JSON), one confirmation with a cost estimate, one Git worktree per approach under
  Doc's data dir (synced to the base and committed as "timeline base: …", with its own dmc
  vault), N `muse exec` agents in parallel, each result committed and tested, a side-by-side
  comparison, run JSON, and `pick` / `list` / `show` / `clean` (branches never deleted). Bisect's
  shell runner is now shared (`probe_runner.dart`).
  - Muse Code 1.4.14 headless, verified on the Mac:
    - Muse's defaults (approval `on-request` with its approval judge, sandbox on, untrusted
      workspace) let `muse exec` edit files and run sandboxed shell commands, so Doc uses
      neither `--disable-approval` nor `--trust-workspace`, and never `--yolo`.
    - `--max-model-steps N` ends with exit 1 and `run.terminal.failed` "… within N step(s)".
    - `--json` gives `run.usage` (steps, tokens by model) and `run.terminal.*`.
    - The user-scope dmc hooks fire in worktrees outside the repository.
    - Muse Wonder accepts a strict `response_format` schema.
  - Verified by 9 pure tests (`doc/test/timelines_test.dart`: approach validation, tree sync,
    Muse events and cost, the estimate, numstat, run JSON with archived marks, the comparison
    table) and 5 CLI tests (`doc/test/timelines_cli_test.dart`). The CLI tests use a compiled
    fake `muse`, a compiled dmc and temp Git repos:
    - exactly N approaches, and invalid output rejected after one retry;
    - worktrees outside the repo with exact base trees;
    - the working copy and the main `.dmc` vault byte-identical before and after;
    - one fix, one step-limit failure and one timeout in parallel;
    - tests per timeline and the comparison text;
    - pick printing commands and changing nothing; list and show;
    - clean keeping branches;
    - Ctrl-C stopping all agents and keeping the worktrees;
    - "no" starting nothing; `--local` refused; `--from … --state before` and the JSON shape.
  - Real check on the Mac, 2026-10-28, in a `/tmp` Python repo with both hooks:
    - Four real turns: Claude Code `subtract_discount`; Muse Code made `round_money` round to one
      decimal (the bug); then a Claude Code and a Muse Code README edit.
    - `doc bisect` found the Muse turn in 4 probes.
    - `doc timelines … --from <it> --state before --max-steps 10`, as specified: tests already
      pass at that state, so timelines 1 and 3 changed nothing and 2 switched to `Decimal`. All
      passed; 5/9/8 steps; Muse Code $0.0151, Wonder $0.0251; 1:24 wall time.
    - The same from `--state after` (the broken state): three different fixes (+1 −1 `round(…, 2)`,
      +3 −1 `Decimal`, +7 −1 integer cents), all passing; 5/6/8 steps; Muse Code $0.0110,
      Wonder $0.0162; 0:52 wall time.
    - `pick 1` printed the diff and commands; the working copy was unchanged and the patch
      passed `git apply --check`.
    - Each worktree vault got one agent-turn checkpoint, and the main vault stayed at 4.
    - `clean` removed the six worktree folders and kept the six branches. Then the repo (and with
      it the branches) and the run records were removed. Hooks were uninstalled; Muse
      `settings.json` was back to the same SHA-256.
  - Other real spend: two Muse Code probes ($0.0072), one Wonder probe ($0.0084), the bisect
    explanation on Baseten (about $0.002), and the demo turns (2 Claude Code, 2 Muse Code).

## In progress

- Nothing yet.

## Broken

- A `left_scope` file the agent changed after ignoring it keeps the agent's edits after a
  restore: its after state is never captured, so a restore cannot undo them. This is by design
  (restore never touches it). The before snapshot is in the vault, and `checkpoint export
  --state before` recovers it.
- Git ignores are checked by checkpoint begin/close, checkpoint restore/redo, `snap` and the
  watcher. Not by legacy file restores (`dmc undo|restore|redo <file>`, `--burst`), which never
  consulted ignore rules, and not by `checkpoint recover --resume|--rollback`, which finishes an
  already-journaled operation.
- Git mode on Windows is verified only by CI (`windows-latest`), not on a real Windows machine.
- Muse Glimmer on Modal is deployed and measured (see Done), which fixes the old "not deployed"
  item. Still true: Glimmer is not on this Mac (24 GiB, Apple M5; no Glimmer model in Ollama,
  LM Studio or llama.cpp), so `doc --local` has no Glimmer. A cold Modal start takes about 90 s,
  and Modal's spending limit (keep it at $100) is the only cost guard, since Doc cannot see
  GPU time.
- Natural-language restore: a request for a checkpoint older than the 30 most recent needs
  `--limit`. `go_back_before` includes manual (non-agent) checkpoints in its range, by design.
  The model's choice is only as good as the labels: dmc keeps the first 100 characters of a
  prompt.
- The Modal workspace name is gone from the docs but still in the history of earlier commits
  (`deploy/modal/README.md` and `STATUS.md` before `f8c2d8f`). Rewriting published history needs
  Mike's decision.
- Bisect assumes that once the tests fail, they keep failing until the end. It tests agent-turn
  states only, so edits made by hand between turns are not probed on their own. On POSIX, a
  timed-out test command is killed through its shell, and processes it started may outlive it.
  Some bisect CLI tests (timeout, `--link`, a crashing command) are POSIX-only; Windows CI covers
  the rest.
- Lesson drafts can only explain *why* a change failed if someone says so (the "What went
  wrong?" answer or `--note`); dmc records what changed, not why. Without it the draft now says
  "Not stated" and cannot be approved until edited.
- Timelines: the planner is told the task, but "fix the bug" from the *before*-state of the first
  bad turn has nothing to fix, since that state passes by definition (seen in the real run).
  From the before-state, ask for the bad turn's goal done in a way the tests accept; from the
  after-state, ask for the fix. A timed-out agent is killed with SIGTERM/SIGKILL on its own
  process; shell children it started may outlive it. The cost estimate is based on two probes
  (about 28k input tokens per step) and Muse Code bills its own account, so Doc only reports
  costs, it does not budget them. `pick`'s `git merge` option also brings the "timeline base"
  commit; the patch option moves only the timeline's change. Timelines need the dmc workspace to
  be the Git top level. The timelines CLI tests run on Windows CI, but Muse Code on Windows
  is not verified.
- **Voice, not yet verified with a person:** no live `doc talk` with the microphone was run (this
  session had no interactive terminal and nobody spoke), so the macOS microphone permission
  prompt, the raw-mode key handling and the live partial line are tested with fakes only. The
  real transcription was verified with `--file` on synthetic speech (`say`). SoX is not installed
  on the Mac, so the mic path is ffmpeg/AVFoundation (`:0`, MacBook Pro Microphone). On Linux and
  Windows only `rec` is used for the mic. Ctrl-C in raw mode relies on the terminal still
  sending SIGINT.
- Voice recognition misheard "auth" as "off" for most synthetic voices, even with `auth` in the
  recognition keywords. NL restore's confidence check caught it (choice screen, nothing
  changed).
- **The Fireworks key was exposed once.** Before line 49 of `~/.zshrc` was fixed, a new zsh
  printed it in an error message, and that appeared in one tool output in this session. Mike
  should rotate the Fireworks key.
- One unexplained Doc test failure: during the final gates on the Mac, one
  `dart test --concurrency=1` run in `doc/` reported a failure (the output was cut to its last
  line, so the failing test is unknown). It did not reproduce in 15 later runs, including the same
  sequence (dmc suite, bundle rebuild, Doc suite). A suspect, not confirmed: `closedBaseUrl()` in
  `doc/test/support/fake_provider.dart` frees a port that the OS could hand to a later fake server.
- The worktree hook rule and `doc` are verified on macOS and by CI only; `doc` on Windows is
  covered by CI tests, not a real Windows run.
- Not verified: whether Claude Code fires `Stop` when a turn is cancelled with Esc (dmc closes it
  on the next prompt either way); whether Muse trust of a parent folder covers the folders inside
  it; whether Muse honors `XDG_DATA_HOME` (it is not passed to hooks).

## Next

Submissions are due Nov 4 at 9:00 PM ET. The build started on Oct 26.

1. Timelines part 2: Muse Wonder judges the diffs and test results (the `judge` role), and demo
   integration (bisect → timelines → pick in one flow, with the lesson).
2. A live `doc talk` with Mike at the microphone (first-run permission prompt, Space/Enter,
   Esc), ideally with SoX installed (`brew install sox`).
3. Then, per the spec's schedule: demo and README (Nov 3), submit (Nov 4).

### Before the demo

- Warm Glimmer with `doc models --check` a few minutes before recording (a cold start takes
  about 90 s).
- Keep the $100 spending limit on the Modal workspace.

## Session log

Newest first. One entry per session: date, agent, what changed, and anything left half-done.

- 2026-10-28 · Claude · Timelines part 1 (branch `hackathon/timelines-1`): verified Muse Code's
  headless flags and JSON events, added `doc timelines` (Wonder plans, worktrees from dmc exports,
  parallel `muse exec`, tests, comparison, pick/list/show/clean) and the shared probe runner.
  Verified with tests and two real 3-timeline runs after a real bisect (about $0.09 in all,
  including probes). Left open: Wonder judging (part 2).

- 2026-10-28 · Claude · Voice (branch `hackathon/voice`): lesson drafts stop inventing reasons;
  `doc talk` push-to-talk on Meta's realtime transcription (protocol checked against Meta's docs,
  which differ from the brief), pure routing to Doc commands with a yes before anything runs,
  `--file`, `doc status`. Verified with tests and a real `--file` run through the NL-restore plan
  ($0.02 in all). Left open: a live microphone run with a person.

- 2026-10-28 · Claude · Glimmer and natural-language restore (branch
  `hackathon/glimmer-nl-restore`): the bisect `--link` cleanup test; Muse Glimmer deployed on
  Modal (L40S, FP8; cold 94 s, warm 2.2 s, scale to zero confirmed, $0.93 metered) with the
  Content-Length fix, and `summary` back on it; fireworks-unavailable handling;
  `doc restore "<request>"` with pure planning and combining, verified with tests and a real
  six-turn Claude Code + Muse Code run. Left open: rotating the Fireworks key.

- 2026-10-28 · Claude · Bisect (branch `hackathon/bisect`): `doc bisect` with a pure search,
  export-based probes, setup/link handling, an explanation and the restore offer. Verified with
  tests and a real six-turn Claude Code + Muse Code run (5 probes, $0.0029). Nothing left
  half-done.
- 2026-10-28 · Claude · Rollback lessons (branch `hackathon/rollback-lessons`): cleanup
  (`__pycache__`, the Modal workspace name, `summary` defaulting to Baseten), `doc restore`,
  `doc lesson draft --last-restore`, abandoned-work diffs and truncated-label markers. Verified
  with tests and a real Claude Code → `doc restore` → approved lesson run ($0.0047). Left open:
  the workspace name in old commits, and rotating the Fireworks key.
- 2026-10-28 · Claude · Glimmer, Fireworks and lessons (branch `hackathon/glimmer-lessons`):
  fixed the Windows watcher-test flake, added the Modal app for Muse Glimmer (not deployed: no
  payment method), added Doc's `modal` and `fireworks` providers and fallbacks, and built lesson
  library part 1 with `doc start`. Verified with tests and a real Claude Code → restore → lesson →
  Muse Code run. Left open: the Modal deployment, and rotating the Fireworks key.
- 2026-10-27 · Claude · Worktree check and Doc skeleton (branch `hackathon/doc-skeleton`):
  probed `muse -w`, kept agent hooks inside their own work tree, added worktree reporting to
  status and doctor, and built the `doc/` package: model client, redaction, router, and the
  models, summarize and usage commands. Verified with tests and real baseten and meta calls.
  Left open: a local Muse Glimmer.
- 2026-10-27 · Claude · Export and policy drift (branch `hackathon/export-drift`): per-file
  handling of ignore-policy drift (schema 5, `left_scope`/`entered_scope`, `skipped` in plans)
  and `dmc checkpoint export`. Verified with tests, a real Claude Code turn that edited
  `.gitignore`, and an export of a clone of this repo (121 files, 40 ms). Nothing left half-done.
- 2026-10-27 · Claude · Git ignore session (branch `hackathon/git-ignore`): CI now runs
  `dart test --concurrency=1`; added Git-mode ignore handling (Git's file list, no silent
  fallback, fingerprinted ignore sources, Git-ignored restore/redo refusal, batched watcher
  checks), 10 tests, dogfood on this repo and on the Node/Python templates, and re-timed the hook
  (176 ms). Left open: the `.gitignore`-edited-mid-turn behaviour (Broken) for Mike to decide.
- 2026-10-26 · Claude · Muse verification on the Mac (branch `hackathon/muse-verify`): fixed the
  fixture-path CI flake, probed Muse Code 1.4.13 (both config paths, StopFailure and Interrupt
  captured), replaced the synthetic Muse fixtures, fixed uninstall byte restoration and turn
  matching on close, ran both agents end to end, and measured the hook at 134 ms. Found the
  nested `.gitignore` blocker and an older cwd race flake in CI. Left open: both.
- 2026-10-26 · Claude · Agent hooks (tasks 1–2): probed Claude Code 2.1.310 (Muse Code not
  installed here), added `docs/AGENT-HOOKS.md` and fixtures, the schema 4 agent-context migration,
  `dmc agent-hook` and `dmc hooks install|uninstall|status`. Verified with tests and a real
  Claude Code turn. Left open: the Muse verification on a machine with Muse Code. Not pushed.

- 2026-10-26 · Claude · Planning session: finalized the build plan, audited existing dmc
  features, and updated `HACKATHON.md` and this file. No code changes.
- 2026-10-26 · Claude · Created the hackathon repository, marked it, added this file, and
  published it to GitHub.
