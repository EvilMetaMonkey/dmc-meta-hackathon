# Doc

Doc is the AI companion for dmc. It is a separate Dart package (`dmc_doc`, executable `doc`) in
this repository. **dmc stays deterministic and never runs a model; every model call lives here.**

## Boundary

- Doc talks to dmc **only** by running the dmc executable with `--json --schema-version 1`. It
  never opens `.dmc/dmc.db`, imports dmc's Dart code, or reads or writes workspace files itself.
- Doc writes only to its own directory in the user config dir: `config.json` (optional) and
  `usage.json`. That is `$DOC_CONFIG_DIR`, else `$XDG_CONFIG_HOME/dmc-doc`, `~/.config/dmc-doc`,
  or `%APPDATA%\dmc-doc` on Windows.
- Any file change Doc proposes later goes through dmc's preview-first, journaled restore.

**Finding dmc:** `--dmc <path>`, then `DMC_BIN`, then each `dmc` on `PATH`. Every candidate must
pass `dmc capabilities --json --schema-version 1` (contract `haven-checkpoint-v1`, schema 1, and
`checkpoint show|diff|list`). On macOS, Apple's unrelated `/usr/bin/dmc` (Disk Mount
Conditioner) is skipped without being run, and older dmc builds without `capabilities` are
skipped with the reason. An explicit `--dmc` or `DMC_BIN` that fails the check is an error.

## Commands

```sh
dart run bin/doc.dart <command> [options]      # from doc/; or compile:
dart compile exe bin/doc.dart -o ../build/doc
```

| Command | What it does |
|---|---|
| `doc models` | Each role's provider and model, and whether its key is set (never the key). |
| `doc models --check` | Sends one tiny prompt per provider in use and shows latency, tokens and cost. A missing local server or model is said plainly. |
| `doc models --available` | Lists each provider's model IDs (`GET {baseUrl}/models`). |
| `doc summarize <checkpoint-id>` | Reads `checkpoint show` and `checkpoint diff` JSON from dmc, redacts, and asks the `summary` role for a 2–3 sentence plain-English summary: what changed, which files, anything risky. |
| `doc usage` | Tokens, audio seconds and estimated cost per provider against the budgets (Modal: calls and tokens; billed by GPU time). |
| `doc status` | The latest checkpoints (time, agent, status, changed files, undone or not), from `dmc checkpoint list` JSON. |
| `doc talk [--file <audio>] [--yes]` (alias `doc hey`) | "Hey Doc" push-to-talk: speak a request, Doc says what it heard and which Doc command it would run, and runs it only after a yes. See "Hey Doc". |
| `doc bisect --test "<command>" [--setup …] [--link <dir>]… [--from <cp>] [--to <cp>] [--all] [--timeout <s>] [--keep] [--no-explain] [--json]` | Time-travel bisect: find the agent turn where the tests started failing, by testing exported checkpoint states. See "Bisect". |
| `doc restore <checkpoint-id> [--yes] [--no-lesson]` | Rollback without amnesia: preview dmc's restore, ask, apply it through dmc, then offer to draft a lesson from the undone work. See "Restore". |
| `doc restore "<request>" [--limit <n>] [--diff] [--yes] [--no-lesson] [--json]` | Natural-language restore ("take me back to before it touched auth"): the restore role picks a checkpoint and a mode, Doc validates it, previews every step with dmc and asks once. See "Natural-language restore". |
| `doc lesson draft <checkpoint-id> [--note "..."]`, `doc lesson draft --last-restore` | Drafts a lesson from a checkpoint, or from the most recent applied restore (workhorse role). See "Lesson library". |
| `doc lesson edit\|approve\|reject <draft>`, `doc lesson show <id>` | Review a draft in `$VISUAL`/`$EDITOR`, add it to the library, delete it, or show an approved lesson. |
| `doc lessons [--files <path>...]`, `doc lessons path` | List the library (approved lessons only), or show where it is kept. |
| `doc lesson brief --task "<text>" [--files <path>...]` | Match lessons by file overlap and condense them into a brief (summary role). |
| `doc start <muse-code\|claude-code> "<task>" [--files <path>...] [--yes]` | Show the brief, ask before adding it, then launch the agent with it as the first prompt. |

Options: `--dmc <path>`, `--workspace <dir>` (default: current directory), `--local` (every role
uses this Mac's model server; any hosted or Modal call is refused), `--role-provider <role>=<provider>` (one
run only, for example `summary=baseten`), `--show-prompt` (print exactly what would be sent,
after redaction, and send nothing).

## Providers

One OpenAI-compatible Chat Completions client (`POST {baseUrl}/chat/completions`) serves every
provider. Each provider's request style is configuration: whether `reasoning_effort` is sent,
the token-limit field, sampling parameters, and Muse Glimmer's `Reasoning strength: <value>`
system-prompt line.

| Provider | Base URL | Key (env var only) | Notes |
|---|---|---|---|
| `meta` | `https://api.meta.ai/v1` | `MODEL_API_KEY` | Sends `reasoning_effort` (default `low`, never `none`) and `max_completion_tokens`. Never `stop`, `n`>1, `logit_bias`, penalties, `max_tokens` or a temperature. |
| `baseten` | `https://inference.baseten.co/v1` | `BASETEN_API_KEY` | Model `meta-models/muse-spark-open-1026`. Sends `reasoning_effort` and `max_tokens`. `reasoning_content` is dropped; only `message.content` is used. |
| `fireworks` | `https://api.fireworks.ai/inference/v1` | `FIREWORKS_API_KEY` | Backup for Muse Spark Open: `accounts/fireworks/models/muse-spark-open`, serverless, $1.25 / $4.25 per million tokens (cached input $0.15), budget $100. Sends `reasoning_effort` and `max_tokens`. |
| `modal` | From the config or `DOC_MODAL_BASE_URL` (never committed) | `MODAL_GLIMMER_KEY` | "Your private deployment" of Muse Glimmer 30B on Modal (`deploy/modal/`), model `muse-glimmer`, on one L40S with FP8. Meta's recommended sampling (temperature 1.0, top_p 0.95, top_k 64) and `Reasoning strength: low.` in the system prompt. 600 s timeout; prints "Waking Muse Glimmer on Modal (can take a couple of minutes)…" after 10 s. Billed by GPU time, so no price or budget check. Deployed 2026-10-28: cold start 94 s, warm about 2.2 s (see "Muse Glimmer on Modal"). |
| `local` | `http://127.0.0.1:11434/v1` (Ollama; LM Studio is usually `:1234`, llama.cpp's `llama-server` `:8910`) | none | This Mac only. Model name configurable (Muse Glimmer). Never falls back to a hosted provider. |

**Structured answers:** `meta` and `baseten` take `response_format` with a JSON schema (checked
on 2026-10-28: Meta answered in the schema's shape, and Baseten kept to the schema even when the
prompt asked for plain text). Only providers with `jsonSchema: true` get it; Doc parses every
answer strictly either way.

Reasoning text is never shown: `reasoning_content` is dropped, and any reasoning a server leaves
in `content` (Glimmer's `to=self` channel, `<think>` blocks) is stripped.

Keys are read only from environment variables. They are sent only in the `Authorization`
header, and they are never logged, printed, stored or included in error messages.

**Retries:** 429 and 5xx (and timeouts) are retried up to `maxRetries` (default 3) with
exponential backoff and jitter, honouring `Retry-After` up to 30 s. Connect timeout is 10 s;
response timeouts are 90 s for hosted providers and 180 s for local.

**Fallback:** one explicit, logged fallback per role, with no second hop. The log line starts
with `FALLBACK:`. A fallback happens when the provider fails *after retries* (unreachable,
timeout, 429/5xx, bad response) or, for Modal, when no deployment is configured. Defaults:
`summary` modal → baseten, `workhorse` baseten → fireworks, `restore` meta → baseten. There is
no fallback for a missing or rejected key, a used-up budget, an answer cut off by the token
limit, or from `local`, and none under `--local`.

**An unavailable fallback is skipped, not an error.** If a fallback's key is missing, or the
fallback rejects it (HTTP 401 or 403), Doc logs "`<provider>` unavailable (…)", skips the
fallback for the rest of the run, and reports the primary provider's own error. A command
whose primary provider works never touches its fallback. `doc models` marks such a fallback
"unavailable, skipped", and `doc models --check` reports "fireworks unavailable (…)" without
failing when Fireworks is only a fallback. An unset Modal is "not configured" there, since
`summary` then falls back to Baseten.

### Verified on 2026-10-27 (Mike's Mac)

- **Meta `GET /models`:** `muse-image-1.0`, `muse-spark-1.1`, `muse-spark-1.2`,
  `muse-spark-1.2-contributor`, `muse-spark-1.3`, `muse-spark-1.3-contributor`,
  `muse-voice-transcribe-1.0`, `muse-wonder-1.0`, `sam-3.1`. So Muse Spark 1.3 is
  `muse-spark-1.3`, Muse Wonder is `muse-wonder-1.0`, and Muse Voice Transcribe is
  `muse-voice-transcribe-1.0`. **Muse Glimmer is not served by the Meta API**; it is the local
  model, and its name in Ollama or llama.cpp is whatever it was loaded as.
- **Baseten `GET /models`** lists both `meta-models/muse-spark-open` and
  `meta-models/muse-spark-open-1026`. Doc uses the dated `-1026`.
- **Muse Spark Open reasons before answering, even for "ok".** With `max_tokens: 32` Baseten
  returned `finish_reason: length` and `content: null` (all tokens went to reasoning). With 400
  tokens it answered `ok` using 88 completion tokens, 77 of them reasoning. Doc reports an answer
  cut off this way as `truncated` (and still records the billed tokens), and allows 600 tokens
  for `--check` and 1500 for a summary.
- **Baseten accepts `reasoning_effort`.** On the same summary prompt, the default effort used
  1,403 completion tokens; `low` used 537. Doc sends `low`.
- **Fireworks (2026-10-27):** `GET /models` lists `accounts/fireworks/models/muse-spark-open`
  (with `supports_chat: false` in its metadata, but chat works). `doc models --check`: ok in
  4,166 ms, 151 in / 54 out, $0.0004.
- Measured: `doc models --check` took 937 ms on baseten (152 in / 143 out) and 2,044 ms on meta
  `muse-spark-1.3` (15 in / 191 out). A real `doc summarize` took 1.8 s on baseten (350 in / 365
  out, $0.0020) and 2.4 s on meta (217 in / 533 out, $0.0025).

## Roles

Defaults, overridable in `config.json` under `roles`:

| Role | Provider | Model | Use |
|---|---|---|---|
| `summary` | modal | `muse-glimmer` (fallback baseten `meta-models/muse-spark-open-1026`) | Per-checkpoint summaries, lesson briefs |
| `workhorse` | baseten | `meta-models/muse-spark-open-1026` (fallback fireworks) | Bisect explanations, lesson drafts |
| `restore` | meta | `muse-spark-1.3` (fallback baseten) | Natural-language restore |
| `planner`, `judge` | meta | `muse-wonder-1.0` | Parallel timelines |
| `voice` | meta | `muse-voice-transcribe-1.0` | "Hey Doc" push-to-talk (`doc talk`), over the realtime WebSocket |

## Bisect: find the turn that broke the tests

Spec: time-travel bisect runs your tests across agent-turn checkpoints to find the turn where
things broke, without touching your working copy. The workhorse role (Muse Spark) explains the
result.

**How it searches.**
- **Candidates:** closed checkpoints from `dmc checkpoint list --json`, oldest first. Only agent
  turns are included unless `--all`, and `--from`/`--to` limit the range. Invalid or released
  checkpoints are skipped and listed.
- **Probe points:** the *before* state of the first candidate is the good end, and every
  candidate's *after* state is a probe point.
- **Ends first:** the good end must pass and the latest after state must fail. If not, Doc says
  "The tests already fail before the first turn" or "The tests pass at the latest turn", with no
  model call, and exits 1.
- **Binary search:** for n turns, the two ends plus about log2(n) probes. The search is the pure
  function `bisectFirstBad` in `lib/src/bisect.dart`. It assumes that once the tests fail, they
  keep failing.

**Each probe.**
- `dmc checkpoint export <id> --state before|after --to <temp>` writes the state into a
  temporary folder outside the workspace.
- Then the optional `--setup` and the `--test` command run there (POSIX `/bin/sh -c`, Windows
  `cmd /c`), with the export as cwd and a per-probe timeout (`--timeout`, default 300 s). Exit 0
  is a pass. A timeout or failed setup counts as a failure.
- Each probe prints a line as it runs (checkpoint, agent, label, PASS/FAIL, seconds).
- The working copy and `.dmc/` are never touched, apart from dmc's own export reads.
- Temporary folders are deleted on success, on failure and on Ctrl-C, unless `--keep`.

**Dependencies.** Exports hold only protected files, so ignored dependencies are missing.
- `--link <dir>` (repeatable) symlinks that working-copy folder into each export, for example
  `--link node_modules`, `--link .venv` or `--link .dart_tool`. Doc warns that tests could write
  into it.
- `--setup "<command>"` runs in each export instead.
- With neither, Doc suggests a setup for files it recognises: `pubspec.yaml` → `dart pub get`,
  `package.json` → `npm ci` (or `npm install`), and `requirements.txt` / `pyproject.toml` → a pip
  install into a `.venv` in the export.
- It asks "Run this setup in each probe? [y/N]" and never runs a suggestion without a yes.

**The result** is the first bad turn (id, label, agent, session, close time, changed files), the
last good point, and the tail of the failing test output (40 lines). A label dmc cut to 100
characters says "(truncated by dmc)"; dmc does not keep the full prompt.

**The explanation.** Unless `--no-explain`, the redacted diff of the first bad turn (the
abandoned-work export diff) and the redacted failing output go to the `workhorse` role for 3 or
4 plain sentences. `--show-prompt` prints that request instead, and `--local` keeps it on this
Mac. If the call fails, the result above still stands.

**Next step, never automatic.** "Restore to before this turn? [y/N]" runs the `doc restore` flow
on that checkpoint: dmc's preview, conflicts never forced, and the lesson offer. **`--yes`
answers yes to the setup and restore questions; use it only for scripted demos.**

**`--json`** prints one object on stdout, with progress on stderr and no questions:
`{command, test, setup, suggestedSetup, links, candidates[], skipped[], probes[{index,
checkpointId, state, passed, timedOut, setupFailed, seconds}], seconds, result{status: found |
firstAlreadyFails | lastPasses, firstBad{…, changedFiles}, lastGood{checkpointId, state},
failingOutputTail}, explanation}`. It's meant for parallel timelines.

A real run on 2026-10-28 in a `/tmp` Python repo. Six real turns alternated between Claude Code
(1, 3, 5) and Muse Code (`muse exec`; 2, 4, 6). Turn 3 made `round_money` round to one decimal:

```text
Bisecting 6 checkpoint(s) in /private/tmp/bisect-demo with: python3 -m unittest -q
[probe 1] before cp_mvs8j0xv_… (claude-code): Add a function subtract_discount(amount, discount) to money.py that returns round_money(amount - di… (truncated by dmc)  PASS  0.1s
[probe 2] after cp_mvs8l6k7_… (muse-code): In README.md, add a short Running tests section that says to run: python3 -m unittest. Only edit RE… (truncated by dmc)  FAIL  0.0s
[probe 3] after cp_mvs8jrja_… (claude-code): In money.py, change round_money to round to 1 decimal place instead of 2, so displayed prices are s… (truncated by dmc)  FAIL  0.0s
[probe 4] after cp_mvs8j0xv_… (claude-code): Add a function subtract_discount(…)  PASS  0.0s
[probe 5] after cp_mvs8jhj2_… (muse-code): Add a section to README.md that lists the functions in money.py, one line each. Only edit README.md.  PASS  0.0s

First bad turn: cp_mvs8jrja_7bfe15990a4f8dea035a3f849ab73555
  claude-code, session db08a43f-…, closed 2026-10-28T09:54:59.977
  Changed: money.py (modified)
Last good point: after cp_mvs8jhj2_… (muse-code)
Failing test output (tail): … AssertionError: 20.0 != 19.99 … FAILED (failures=2)
5 probe(s) for 6 turn(s), 0.2s.

Why (baseten meta-models/muse-spark-open-1026; 669 in / 498 out; 0 item(s) redacted):
The turn changed money.py so round_money now rounds to 1 decimal place instead of 2. That change caused test_round_money_keeps_cents to get 20.0 instead of 19.99 and test_add_tax to get 21.6 instead of 21.64. Check whether round_money should be restored to 2 decimal places to satisfy the cent-precision expectations.

Restore to before this turn? [y/N] y
Restore would change 1 file(s):
  - money.py: put back the version from before the turn
Restore these files? [y/N] y
Restored 1 file(s) through dmc (operation op_mvs8mgpl_2d3cc5d4a20520bbe3763aad).
```

Afterwards all 6 tests passed, and the later turns' changes were untouched. Cost: one Baseten
call, $0.0029.

## "Hey Doc": push-to-talk voice

Spec: "Hey Doc" push-to-talk voice, no wake word, using Muse Voice Transcribe.

`doc talk` (or `doc hey`) prints "Press Space or Enter to talk (Esc to cancel)…". **Nothing is
recorded or sent until a key is pressed.** Then it records and streams while you talk, showing
the partial transcript live, until Space or Enter again (or 30 seconds), and prints the final
transcript. Esc cancels: the socket is closed without `endStream` and nothing more is sent. The
terminal is put in raw mode (no echo, no line buffering) only for the keys, and restored on every
path, including errors and Ctrl-C. Keys are read in a helper isolate with `readByteSync`, so
later questions (Run it?, restore's questions) still read whole lines normally.

`doc talk --file <audio>` streams a recording instead, at real-time pace, for repeatable demos
and tests. A 16-bit mono WAV at 16 or 24 kHz is read directly; anything else is converted to
PCM16 mono 16 kHz with `sox` (preferred) or `ffmpeg`.

**Microphone.** Doc records through an installed tool and is the only program that talks to
Meta: `rec` from SoX (`rec -q -t raw -b 16 -e signed -c 1 -r 16000 -`), else on macOS
`ffmpeg -f avfoundation -i :0 -ac 1 -ar 16000 -f s16le -` (`DOC_MIC_DEVICE` picks another
AVFoundation input; list them with `ffmpeg -f avfoundation -list_devices true -i ""`). If neither is
installed, Doc says: install SoX (`brew install sox`, which provides `rec`) or FFmpeg (`brew install
ffmpeg`). **The first recording makes macOS ask whether the terminal app may use the
microphone** (System Settings → Privacy & Security → Microphone); if it was denied, the tool
records silence or fails until it is allowed there. On Mike's Mac SoX is not installed, so
ffmpeg 8.1.2 is used (input `:0` is the MacBook Pro Microphone).

**Meta's realtime transcription, as documented** (dev.meta.ai/docs/api-reference/voice/realtime,
voice schemas and the Speech to text page, read on 2026-10-28). Doc follows these names exactly:

- **Endpoint:** `wss://api.meta.ai/v1/asr/realtime?sessionId=<optional id>`, model
  `muse-voice-transcribe-1.0`. Doc derives it from the `meta` base URL (`https` → `wss`).
- **Handshake:** the first JSON text frame, within 10 seconds of connecting. **The key goes in the
  frame, not in an `Authorization` header** (the header is ignored):
  `{"authorization": {"accessToken": "Bearer <MODEL_API_KEY>"}, "audioEncoding": "PCM_16KHZ",
  "model": "muse-voice-transcribe-1.0", "mode": "PUSH_TO_TALK", "partialMode": "CUMULATIVE",
  "keywords": [...]}`. `audioEncoding` is required (`PCM_16KHZ` or `PCM_24KHZ`, the native rate);
  `mode` is `PUSH_TO_TALK` (also `ENDPOINTING`, `DIARIZATION`); `keywords` and `languageBias` bias
  recognition. The reply is `{"sessionId": "…"}`, the only server frame without a `type`.
- **Audio:** raw signed 16-bit little-endian mono PCM in **binary frames** (not base64 JSON
  events). Meta's example sends 80 ms frames, and Doc does too (2,560 bytes at 16 kHz). **Paced in
  real time:** a backlog, or audio arriving slower than real time, closes the socket with 1008.
- **End of input:** `{"type": "endStream"}`. Realtime has no other turn commit; in
  `PUSH_TO_TALK` the client ends the turn by ending the stream. Keep reading until the server
  closes with 1000.
- **Server events** (dispatch on `type`, ignore unknown ones): `transcript` (`transcript`,
  `final`, `audioProcessedMs`; with `CUMULATIVE` each partial replaces the last, and `final: true`
  marks completion in `PUSH_TO_TALK`), `audioProgress` (`audioProcessedMs`), `speechStart`,
  `speechEnd` and `speechComplete` (`turnId`, `transcript`), `speaker` (`label`) and `error`
  (`message`, `sessionId`, optional `errorType`, `errorCode`, `errorParam`), sent just before the
  server closes.
- **Close codes:** 1000 normal, 1008 invalid request or pacing (retrying unchanged fails again),
  1011 server failure (retry with backoff; also "Max session duration reached"), 1013 rate
  limited. A session lasts at most 60 minutes.
- **There is no usage event.** Doc takes the processed audio from the highest `audioProcessedMs`.
  Meta bills **$0.18 per hour of audio processed, metered in whole seconds and rounded down**
  (pricing page), so Doc records `floor(ms / 1000)` seconds at $0.00005 per second
  (`providers.meta.audioPrices`; a model without a price is shown as "cost unknown"). Limits: 256
  concurrent streams and 16,000 streams per hour.
- These differ from what we expected before reading the docs: no `session.update`, no base64
  `input_audio_buffer.append` (and no 4-second chunk limit: Doc's frames are 80 ms), no
  `input_audio_buffer.commit`, and no `…transcription.delta` / `…completed` events. Meta also has
  a buffered upload endpoint, `POST /v1/asr/transcribe` (multipart WAV, up to 10 minutes, with the
  usual `Authorization` header). Doc does not use it: `--file` goes through the same realtime
  path as the microphone.

**Recognition hints.** Doc sends the names of files changed in the 10 most recent closed
checkpoints (without extensions: `auth.py` → `auth`) plus "Doc" and "dmc" as `keywords`. Names
only, never contents.

**From transcript to action, never acting without a yes.** The transcript, redacted, goes to the
`workhorse` role with a `response_format` JSON schema: `{command: "restore" |
"summarize_latest" | "lesson_brief" | "lessons" | "bisect" | "status" | "unknown", text,
confidence}`, parsed strictly with one retry. `planVoiceAction` (pure) validates it:

| Command | Runs | Notes |
|---|---|---|
| `restore` | `doc restore "<the transcript>"` | The transcript itself, not the model's rewording, goes to natural-language restore, with all its previews and questions |
| `summarize_latest` | `doc summarize <newest closed checkpoint>` | |
| `lesson_brief` | `doc lesson brief --task "<text>"` | |
| `lessons` | `doc lessons` | |
| `bisect` | `doc bisect --test "<command>"` | The test command comes from `{"workspaces": {"<workspace root>": {"bisectTest": "…"}}}` in Doc's config, or Doc asks for one |
| `status` | `doc status` | |

Doc prints `I heard: "<transcript>" → I'll run: doc <command> … Run it? [y/N]` and runs the
command in-process only on yes. An `unknown` command, confidence below 0.6, or an empty
transcript runs nothing: Doc says what it heard and lists what it can do. **`--yes` answers "Run
it?" for the read-only commands, never for restore or bisect**, and it is never passed on to the
command itself.

**Privacy.** Audio goes only to Meta, and only while recording (or while `--file` streams).
`--local` refuses `doc talk`: there is no local transcription, so it says so and records nothing.
`--show-prompt` is refused too, because a transcript needs audio sent first.

A real run on 2026-10-28 in a `/tmp` repo after four real turns (Claude Code `slugify` in
`utils.py`; Muse Code `hmac.compare_digest` in `auth.py`; Claude Code README; Muse Code
`health()` in `app.py`). The recording is a 2.3 s WAV made with macOS `say -v Karen` (SoX's `rec`
is not installed here, and nobody spoke into the microphone):

```text
$ doc talk --file auth-karen.wav
Streaming auth-karen.wav (2.3 s) to Muse Voice Transcribe at real-time pace…
  … take
  … take me
  … take me back to
  … take me back to before
  … take me back to before it
  … take me back to before it touched
  … take me back to before it touched auth.
(meta muse-voice-transcribe-1.0; 2.3 s of audio sent, 2 s billed; final transcript 188 ms after the end of the audio; $0.000100)
I heard: "take me back to before it touched auth." → I'll run: doc restore "take me back to before it touched auth."
Run it? [y/N] y
Doc's reading (meta muse-spark-1.3; 1121 in / 403 out; $0.003114; 0 item(s) redacted; confidence 0.95):
  go back to before cp_mvsn7oni_… (muse-code, 2026-10-28 16:45:18): Checkpoint 3 is the only one that modified auth.py.

Plan: go back to before cp_mvsn7oni_… (muse-code, 2026-10-28 16:45:18) (3 step(s), newest first):
  1. cp_mvsnadvg_…  2026-10-28 16:47:18  muse-code: In app.py, add a function health() … (truncated by dmc)
  2. cp_mvsna0c3_…  2026-10-28 16:47:09  claude-code: In README.md, add a short Usage section … (truncated by dmc)
  3. cp_mvsn7oni_…  2026-10-28 16:45:18  muse-code: In auth.py, make check_password compare passwords with hmac.compare_digest … (truncated by dmc)
Files that will change (against the working copy):
  - README.md  +0 −6  put back the version from before step 2
  - app.py     +0 −5  put back the version from before step 1
  - auth.py    +1 −6  put back the version from before step 3
Apply this restore (3 step(s), 3 file(s))? [y/N] n
Nothing was changed.
```

The whole run took 8.1 s, of which 2.3 s was streaming at real-time pace. With the default macOS
voice, "auth" came back as "off" even with `auth` in `keywords`. The restore role then answered
at confidence 0.40 and showed the choice screen, and nothing changed. Four `say` voices were
tried; Karen's came through as "auth".

## Natural-language restore

Spec: natural-language restore ("take me back to before it touched auth"), always with a diff
preview and a confirmation step. It uses the `restore` role (Muse Spark 1.3 on Meta, with the
logged Baseten fallback). dmc stays model-free.

`doc restore "<request>"`: an argument that is a checkpoint ID (`cp_…`) keeps the checkpoint
flow below unchanged; anything else (several words are joined) is a request.

1. **Candidates (no model).** The most recent closed checkpoints (default 30, `--limit`), newest
   first: id, time, agent, session, the label (a label dmc cut to 100 characters is sent with
   the truncation marker) and changed file paths. Labels and paths only, never file contents;
   the whole message is redacted before it is sent. A checkpoint whose latest operation is a
   restore is marked "already undone".
2. **The model answers in JSON:** `{mode: "go_back_before" | "undo_turn", checkpoint_id,
   confidence: 0..1, reason, alternatives: [ids]}`. Providers that take it get a
   `response_format` JSON schema whose ids are an enum of the candidates. Doc parses strictly; a
   malformed or invalid answer is retried once with the reason, then refused.
3. **Validation (`planNaturalRestore`, pure and tested).** The id and every alternative must be
   candidates, or Doc refuses. `undo_turn` is that one checkpoint; `go_back_before` is it and
   every later candidate, newest first, so each step's after state matches the working copy.
   Already-undone checkpoints are skipped. The model never chooses files or actions.
4. **The user picks when Doc is unsure.** Below 0.6 confidence, or with alternatives, Doc lists
   the choices (number, time, agent, label, id, files) and waits for a number; Enter cancels.
   **`--yes` never answers this.**
5. **Preview (nothing changes).** `dmc checkpoint restore <id>` runs as a preview for every step,
   and `combineStepPreviews` (pure) makes one plan: the steps, each file that will change with
   +/− line counts and what happens to it, skipped files and conflicts. dmc previews each step
   against the current working copy, so an older step reports drift on a file a newer step
   also restores; Doc follows the file through the steps instead, and it is only a conflict if
   the newer step will not put back exactly what the older step expects (`chain_mismatch`, the
   file changed between the turns). Line counts and `--diff` use `dmc checkpoint export` into
   a temporary directory outside the workspace: "now" is the after state of the newest step
   touching the file, which the preview has just verified matches the working copy (SHA-256),
   and "after" is the before state of the oldest. Doc still never reads the workspace. **Any
   conflict stops here**; Doc does not offer to apply.
6. **One confirmation:** "Apply this restore (N steps, M files)? [y/N]". The steps run in order
   with `dmc checkpoint restore <id> --apply`. If one fails, Doc stops, lists the applied steps,
   prints dmc's `checkpoint recover` command if a journal was left incomplete, and asks "Put
   back the steps already applied? [y/N]" (`dmc checkpoint redo --apply`, in reverse order).
   It never forces anything.
7. **The lesson offer**, as below, for the oldest checkpoint in the plan, with the other undone
   steps given as context.

`--show-prompt`, `--local` and `--json` work as elsewhere (`--json`: one object with
`candidates`, `answer`, `model` (provider, tokens, cost, whether `response_format` was sent),
`choice`, `plan`, `preview` and `result`; questions go to stderr). **`--yes` answers the apply
and lesson questions, for scripted demos only.**

A real run on 2026-10-28 in `/tmp/nl-demo`, after six real turns: Claude Code added `slugify`
to `utils.py`, Muse Code (`muse exec`) rewrote `check_password` in `auth.py` with
`hmac.compare_digest`, Claude Code added a README section, Muse Code added `health()` to
`app.py`, and Claude Code created `test_utils.py` (one attempt changed nothing):

```text
$ doc restore "take me back to before it touched auth"
Doc's reading (meta muse-spark-1.3; 1494 in / 340 out; $0.003312; 0 item(s) redacted; confidence 0.95):
  go back to before cp_mvsk7r9r_… (muse-code, 2026-10-28 15:21:25): Checkpoint 5 is the only one that modified auth.py.

Plan: go back to before cp_mvsk7r9r_… (muse-code, 2026-10-28 15:21:25) (5 step(s), newest first):
  1. cp_mvskbx9q_…  2026-10-28 15:24:40  claude-code: Create test_utils.py with a unittest test for slugify … (truncated by dmc)
  2. cp_mvskbf07_…  2026-10-28 15:24:14  claude-code: Create test_utils.py with a unittest test for slugify … (truncated by dmc)
  3. cp_mvsk9tg7_…  2026-10-28 15:22:59  muse-code: In app.py, add a function health() that returns the string ok, … (truncated by dmc)
  4. cp_mvsk9bl7_…  2026-10-28 15:22:43  claude-code: In README.md, add a short Usage section … (truncated by dmc)
  5. cp_mvsk7r9r_…  2026-10-28 15:21:25  muse-code: In auth.py, make check_password compare passwords with hmac.compare_digest … (truncated by dmc)
Files that will change (against the working copy):
  - README.md      +0 −6  put back the version from before step 4
  - app.py         +0 −5  put back the version from before step 3
  - auth.py        +1 −6  put back the version from before step 5
  - test_utils.py  +0 −14  delete it
Apply this restore (5 step(s), 4 file(s))? [y/N] y
Step 1 of 5: restored cp_mvskbx9q_… through dmc (operation op_mvskjkvf_…).
…
Step 5 of 5: restored cp_mvsk7r9r_… through dmc (operation op_mvskjl0h_…).
Restored 4 file(s) in 5 step(s) through dmc.
Draft a lesson from the work you just undid? [Y/n] y
```

Afterwards the working copy was byte-identical to `dmc checkpoint export cp_mvsk7r9r_… --state
before` (`diff -r` and per-file SHA-256), and turn 1's `slugify` was kept. An ambiguous request
(`doc restore "undo what claude did"`) came back at confidence 0.55 and showed the four Claude
Code turns to pick from; Enter cancelled it and nothing changed.

## Restore: rollback without amnesia

Spec: after any rollback, Doc sends the abandoned work, redacted, to Muse Spark (Muse Glimmer in
local mode) and drafts a short note: what was tried, why it failed, what to avoid. The user
approves or edits it, nothing is injected silently, and approved lessons go to the library.

`doc restore <checkpoint-id>` runs dmc's preview (`dmc checkpoint restore <id> --json`), shows it
in plain terms and asks before anything changes. A real run on 2026-10-28, after a Claude Code
turn changed `parse_amount` to return float dollars and broke `test_money.py`:

```text
Checkpoint cp_mvrsb1hb_… (closed, claude-code turn): In money.py, change parse_amount to return a float number of dollars (for example 12.5) instead of…
Restore would change 1 file(s):
  - money.py: put back the version from before the turn
Restore these files? [y/N] y
Restored 1 file(s) through dmc (operation op_mvrsbszz_1a05069692c66f8a27d3b45e).
Draft a lesson from the work you just undid? [Y/n] y
What went wrong? (optional, press Enter to skip)
---
id: "2026-10-28-keep-parse-amount-returning-integer-cent-440c"
…
Draft saved: ~/.local/share/dmc-doc/lessons/<workspace>/drafts/….md
Review it with "doc lesson edit …", then "doc lesson approve …" or "doc lesson reject …".
```

- **Every file change goes through dmc's journaled restore** (`--apply`). Doc never writes
  workspace files.
- **Conflicts are shown and never forced.** A file edited after the turn (`workspace_drift`)
  means nothing is changed and dmc's reason is shown; an interrupted apply prints dmc's
  `checkpoint recover <op> --resume|--rollback` guidance.
- Files that changed protection during the turn (`left_scope`/`entered_scope`) are listed as left
  alone, as dmc never writes them.
- After a successful apply it asks "Draft a lesson from the work you just undid? [Y/n]", then one
  optional "What went wrong?" (only the person who undid it knows; without it the draft can only
  say the change was rolled back). **`--yes` answers yes to both questions and skips the "what
  went wrong" question; use it only for scripted demos.** `--no-lesson` skips the lesson.
- **Restores done directly with dmc** are caught by `doc lesson draft --last-restore`. It finds
  the most recent completed `restore` operation through dmc's existing machine schema 1 JSON
  (`checkpoint list --limit 1000` carries each checkpoint's operations with `direction`,
  `status` and `completedAt`), skipping one that a later completed `redo` reapplied. No dmc
  change was needed.

**What the draft sees.** dmc's facts (labels, paths, change kinds, issues) plus **the abandoned
work as a diff**. dmc's JSON never carries file contents, so Doc runs `dmc checkpoint export
<id> --state before` and `--state after` into a temporary directory outside the workspace,
diffs the changed files there (two lines of context), and deletes the copies. Files named
`.env*`, `*.pem`, `*.key` or `id_rsa*` are named only; binary files and files over 64 KiB are
not shown; the diff is cut at 8,000 characters. The whole prompt is redacted before it is sent.
dmc records an agent's prompt as its first line cut to 100 characters with "…". Such a label is
sent as `… [truncated by dmc: the full prompt is not available; do not quote or complete it]`,
and the drafting prompt tells the model never to quote or complete truncated text (the first
real draft had echoed "0 to [truncated]"). `files` always comes from the manifest.

## Lesson library

Spec: every approved lesson is saved as markdown, tagged with the files it covers. When an agent
starts a task, Doc matches lessons by file overlap (a fixed rule), condenses them into a short
brief, and offers it to the agent. It is never injected silently: the brief becomes the agent's
first prompt only if the user says yes.

**Storage.** One markdown file per lesson, in Doc's data dir (`$DOC_DATA_DIR`, else
`$XDG_DATA_HOME/dmc-doc`, `~/.local/share/dmc-doc`, or `%LOCALAPPDATA%\dmc-doc`), under
`lessons/<first 24 hex of dmc's workspace fingerprint>/`. Approved lessons are in `library/` and
drafts in `drafts/`. Never in the repository or `.dmc/`. `doc lessons path` shows where. A real
example, drafted by Muse Spark Open from a Claude Code turn that broke checkout, then restored and
approved:

```markdown
---
id: "2026-10-28-keep-discount-callers-and-implementation-7b0f"
title: "Keep discount callers and implementation in sync"
files:
  - "pricing.py"
created: "2026-10-28T02:26:28.823790Z"
source:
  checkpoint: "cp_mvrht1v3_71af192a2c5a710ee465edad968ad841"
  agent: "claude-code"
  session: "f56b3ba3-22eb-4740-a6a1-addd9de5488c"
status: "approved"
---

## What was tried
In pricing.py, apply_discount was changed to expect percent as a fraction between 0 and 1 instead of 0 to 100.
## Why it failed
checkout.py still passed 25 for 25%, which made prices negative (-1920.0). Callers were not updated, and the change was rolled back via restore.
## What to do instead
Update all callers together with the implementation, or maintain backward compatibility and add validation to reject out-of-range values before changing the contract.
```

**Drafting.** `doc lesson draft` sends dmc's `checkpoint show` and `checkpoint diff` facts (and
the note), redacted, to the workhorse role, which writes a title and the three sections (at most
150 words). The title describes the work that was undone, never a rule. **Without a note the
reason is unknown:** the prompt says so ("Reason it was undone: not stated … Do not guess"),
Doc writes "Why it failed" as "Not stated — add the reason before approving." whatever the
model answered, and `doc lesson approve` refuses the draft until that line is edited. (A real
draft after a natural-language restore had been titled "Do not modify protected auth.py",
inventing a reason for undoing what was a good security fix.) `files` always comes from the checkpoint's changed paths, never from the model. The
saved title and body are redacted again, and `approve` refuses anything that still looks like a
secret.

**Matching (no model).** Candidate files are path-like tokens in the task that resolve to files
dmc knows (the latest checkpoint's manifest, plus lesson files that still exist): an exact
workspace-relative path, or a basename that matches exactly one file. `--files` adds more.
Score = how many of a lesson's files are candidates; ties go to the newest; the top 3 with score
≥ 1 match. Drafts never match. No match means no model call.

**Starting an agent.** `doc start <agent> "<task>"` prints the brief and asks "Add this to the
agent's first prompt? [y/N]". The first prompt is the brief, a blank line, then the task (or the
task alone). The agent is launched interactively: `muse "<prompt>"` (Muse Code 1.4.14:
`muse [OPTIONS] [PROMPT]` starts the TUI with that prompt submitted) or `claude "<prompt>"`. The
agent's own hooks create the checkpoints. **`--yes` skips the question; use it only for scripted
demos.** `DOC_MUSE_BIN` and `DOC_CLAUDE_BIN` override the executables.

Verified on 2026-10-28: in `/tmp/lesson-demo`, `doc start muse-code "Add a bulk_discount function
to pricing.py for orders of 10 or more items" --yes` launched Muse Code, whose first prompt (from
its transcript, and from the checkpoint its dmc hook labelled) was:

```text
Before you start: When adding bulk_discount to pricing.py avoid changing apply_discount to expect percent as a fraction 0 to 1 instead of 0 to 100 while checkout.py still passes 25 for 25%. That mismatch made prices negative -1920.0 and was rolled back via restore. Instead update pricing.py and checkout.py together or keep backward compatibility and add validation to reject out-of-range values before changing the contract.

Add a bulk_discount function to pricing.py for orders of 10 or more items
```

Muse kept the 0–100 contract, added range validation and `bulk_discount`, and `checkout.py`
still printed `60.0`. The brief came from Muse Spark Open on Baseten through the logged
`summary` fallback, because the Modal Glimmer deployment was not up then.

### Muse Glimmer on Modal (`summary`)

`summary` uses Mike's private Muse Glimmer deployment (`deploy/modal/`). Doc needs its URL with
`/v1`, either as `DOC_MODAL_BASE_URL` (on Mike's Mac it is exported in `~/.zshrc`) or in
`~/.config/dmc-doc/config.json` as `{"providers": {"modal": {"baseUrl": "https://…modal.run/v1"}}}`.
Never commit it. Without it, or when Modal fails, `summary` falls back to Baseten, logged.

Measured on 2026-10-28 (one L40S, FP8, vLLM 0.28.0):

| | Result |
|---|---|
| Cold `doc models --check` (from zero containers) | ok in 94,097 ms (34 in / 53 out) |
| Warm `doc models --check`, twice | 2,419 ms and 2,132 ms |
| `doc summarize` on a real Muse Code checkpoint, warm | 11,082 ms, 245 in / 233 out |
| Scale to zero | 0 containers about 6 minutes after the last request |

The summary Glimmer wrote for the Muse Code turn that rewrote `auth.py`:

> Checkpoint cp_mvsk7r9r_3364f0be738dd6706628a7feae65339c is closed from source muse-code by
> agent muse-code. The only change is auth.py was modified to make check_password compare
> passwords with hmac.compare_digest with hmac imported. No files were deleted and no fatal
> issues were reported.

**Before recording a demo, warm Glimmer with `doc models --check` a few minutes ahead**, so the
first summary does not wait about 90 seconds for a cold start.

## Safety

- **Redaction before any hosted call** (`lib/src/redaction.dart`): provider key formats (Meta
  `LLM|…`, Baseten, OpenAI `sk-`, Anthropic `sk-ant-`, AWS `AKIA…`/`ASIA…`, GitHub
  `ghp_`/`github_pat_`, Slack `xox*` and webhooks, Google `AIza…`), bearer tokens, PEM private-key
  blocks, credentials in URLs, secret-looking `NAME=value` lines (every assignment in env-style
  files), and the exact values of the API keys Doc holds. Each result reports how many items were
  redacted. Files named `.env*`, `*.pem`, `*.key` and `id_rsa*` are never sent, only their names.
- **`--show-prompt`** prints the exact request body (after redaction, without the key) and sends
  nothing.
- **Budgets:** every per-token call needs a configured per-model price, and is blocked once the
  provider's recorded cost reaches its budget (defaults: meta $150, baseten $100, fireworks
  $100). Modal is billed by GPU time, which Doc cannot see; set a spending limit in Modal's
  billing settings instead (keep the $100 workspace limit). Default
  prices are the published ones (USD per million tokens): meta `muse-spark-1.3` $1.25 in / $4.25
  out, `muse-wonder-1.0` $4.00 / $20.00 (dev.meta.ai/docs/pricing-rate-limits); baseten
  `meta-models/muse-spark-open-1026` $1.25 / $4.25 (Baseten's model library); fireworks
  `accounts/fireworks/models/muse-spark-open` $1.25 / $4.25 (Fireworks' model page). Cached-input
  discounts are not applied, so estimates err high.

## Tests

```sh
cd doc
dart pub get --enforce-lockfile
dart analyze --fatal-infos
DMC_TEST_BIN=../build/dmc/bundle/bin/dmc dart test --concurrency=1
```

Without `DMC_TEST_BIN`, the CLI tests build dmc with `dart build cli` first. Fake HTTP servers
stand in for every provider; no test makes a real model call.
