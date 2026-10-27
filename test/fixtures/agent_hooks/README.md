# Agent hook payload fixtures

Stdin payloads for `dmc agent-hook`. See `docs/AGENT-HOOKS.md` for how each was obtained.

- `claude_code/`: **captured** from Claude Code 2.1.310 on Linux on 2026-10-26 with a probe hook
  in a throwaway repository's `.claude/settings.local.json`. `stop_failure.json` comes from a run
  whose API endpoint refused connections. Scrubbed: session and prompt UUIDs replaced, home
  directory and project path replaced with `/home/dev` and `/home/dev/project`.
- `muse_code/`: **captured** from Muse Code 1.4.13 on macOS on 2026-10-26 with a probe hook
  (`.muse/hooks.json` in a trusted throwaway repository, and `~/.config/muse/settings.json`).
  `session_start`, `user_prompt_submit`, `stop` and `session_end` come from one
  `muse exec "reply with the word ok"` run; `stop_failure.json` from a run with `--base-url`
  pointing at a closed local port; `interrupt.json` from an interactive turn cancelled with Esc.
  Scrubbed: session and turn UUIDs replaced, `cwd` replaced with `/Users/dev/project`.

Tests overwrite `cwd` with a temporary workspace, so the paths here are placeholders.
