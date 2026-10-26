# Agent hook payload fixtures

Stdin payloads for `dmc agent-hook`. See `docs/AGENT-HOOKS.md` for how each was obtained.

- `claude_code/`: **captured** from Claude Code 2.1.310 on Linux on 2026-10-26 with a probe hook
  in a throwaway repository's `.claude/settings.local.json`. `stop_failure.json` comes from a run
  whose API endpoint refused connections. Scrubbed: session and prompt UUIDs replaced, home
  directory and project path replaced with `/home/dev` and `/home/dev/project`.
- `muse_code/`: **synthetic**. Muse Code was not installed on the machine that wrote these, so
  they follow the researched 1.4.x field list (snake_case `hook_event_name`, `session_id`, `cwd`,
  `transcript_path` (null here), `model`, `permission_mode`, plus `prompt`/`turn_id` on
  UserPromptSubmit, `turn_id`/`last_assistant_message`/`stop_hook_active` on Stop, and `reason` on
  SessionEnd). The StopFailure and Interrupt field sets are a guess. Replace them with captured
  payloads once a probe runs against a real Muse Code install.

Tests overwrite `cwd` with a temporary workspace, so the paths here are placeholders.
