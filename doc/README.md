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
| `doc usage` | Tokens and estimated cost per provider against the budgets. |

Options: `--dmc <path>`, `--workspace <dir>` (default: current directory), `--local` (every role
uses the local provider; any hosted call is refused), `--role-provider <role>=<provider>` (one
run only, for example `summary=baseten`), `--show-prompt` (print exactly what would be sent,
after redaction, and send nothing).

## Providers

One OpenAI-compatible Chat Completions client (`POST {baseUrl}/chat/completions`) serves all
three providers.

| Provider | Base URL | Key (env var only) | Notes |
|---|---|---|---|
| `meta` | `https://api.meta.ai/v1` | `MODEL_API_KEY` | Sends `reasoning_effort` (default `low`, never `none`) and `max_completion_tokens`. Never `stop`, `n`>1, `logit_bias`, penalties, `max_tokens` or a temperature. |
| `baseten` | `https://inference.baseten.co/v1` | `BASETEN_API_KEY` | Model `meta-models/muse-spark-open-1026`. Sends `reasoning_effort` and `max_tokens`. `reasoning_content` is dropped; only `message.content` is used. |
| `local` | `http://127.0.0.1:11434/v1` (Ollama; llama.cpp's `llama-server` is usually `http://127.0.0.1:8910/v1`) | none | Model name configurable (Muse Glimmer). Never falls back to a hosted provider. |

Keys are read only from environment variables. They are sent only in the `Authorization`
header, and they are never logged, printed, stored or included in error messages.

**Retries:** 429 and 5xx (and timeouts) are retried up to `maxRetries` (default 3) with
exponential backoff and jitter, honouring `Retry-After` up to 30 s. Connect timeout is 10 s;
response timeouts are 90 s for hosted providers and 180 s for local.

**Fallback:** exactly one explicit, logged fallback. A role may name a hosted
`fallbackProvider`; by default `restore` (meta Muse Spark 1.3) falls back to baseten (Muse Spark
Open) when meta fails *after retries* (unreachable, timeout, 429/5xx, bad response). The log line
starts with `FALLBACK:`. There is no fallback for a missing or rejected key, a used-up budget, or
from `local`, and none under `--local`.

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
- Measured: `doc models --check` took 937 ms on baseten (152 in / 143 out) and 2,044 ms on meta
  `muse-spark-1.3` (15 in / 191 out). A real `doc summarize` took 1.8 s on baseten (350 in / 365
  out, $0.0020) and 2.4 s on meta (217 in / 533 out, $0.0025).

## Roles

Defaults, overridable in `config.json` under `roles`:

| Role | Provider | Model | Use |
|---|---|---|---|
| `summary` | local | `muse-glimmer` | Per-checkpoint summaries |
| `workhorse` | baseten | `meta-models/muse-spark-open-1026` | Bisect explanations, lesson-note drafts |
| `restore` | meta | `muse-spark-1.3` (fallback baseten) | Natural-language restore |
| `planner`, `judge` | meta | `muse-wonder-1.0` | Parallel timelines |
| `voice` | meta | `muse-voice-transcribe-1.0` | Push-to-talk (configured only; not wired up yet) |

## Safety

- **Redaction before any hosted call** (`lib/src/redaction.dart`): provider key formats (Meta
  `LLM|…`, Baseten, OpenAI `sk-`, Anthropic `sk-ant-`, AWS `AKIA…`/`ASIA…`, GitHub
  `ghp_`/`github_pat_`, Slack `xox*` and webhooks, Google `AIza…`), bearer tokens, PEM private-key
  blocks, credentials in URLs, secret-looking `NAME=value` lines (every assignment in env-style
  files), and the exact values of the API keys Doc holds. Each result reports how many items were
  redacted. Files named `.env*`, `*.pem`, `*.key` and `id_rsa*` are never sent, only their names.
- **`--show-prompt`** prints the exact request body (after redaction, without the key) and sends
  nothing.
- **Budgets:** every hosted call needs a configured per-model price, and is blocked once the
  provider's recorded cost reaches its budget (defaults: meta $150, baseten $100). Default
  prices are the published ones (USD per million tokens): meta `muse-spark-1.3` $1.25 in / $4.25
  out, `muse-wonder-1.0` $4.00 / $20.00 (dev.meta.ai/docs/pricing-rate-limits); baseten
  `meta-models/muse-spark-open-1026` $1.25 / $4.25 (Baseten's model library). Cached-input
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
