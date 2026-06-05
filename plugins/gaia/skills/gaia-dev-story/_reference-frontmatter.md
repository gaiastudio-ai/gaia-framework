# Reference Frontmatter — gaia-dev-story

This is the canonical reference for the hooks-in-skill-frontmatter pattern,
copied verbatim from the GAIA Native Conversion feature brief.
Future skill conversions that need PostToolUse hooks should copy from this file.

```yaml
---
name: gaia-dev-story
description: Implement a user story end-to-end -- validate, dev, test, PR. Use when "dev this story" or /gaia-dev-story.
argument-hint: [story-key]
context: fork
allowed-tools: Read Write Edit Grep Glob Bash
hooks:
  PostToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: ${CLAUDE_PLUGIN_ROOT}/skills/gaia-dev-story/scripts/checkpoint.sh write gaia-dev-story
---
```

## Pattern Notes

- `context: fork` ensures the skill runs in an isolated subagent context so the PostToolUse hook's tool-matching is scoped to this skill's execution only.
- `allowed-tools` lists the canonical minimum for a dev workflow. The frontmatter linter should reject additions or removals without documented rationale.
- The `PostToolUse` hook fires `checkpoint.sh` after every `Edit` or `Write` tool invocation, providing automatic checkpointing of file mutations.
- `${CLAUDE_PLUGIN_ROOT}` is the substrate-supplied substitution variable resolved by Claude Code at runtime to the plugin's root directory. Reference skill files as `${CLAUDE_PLUGIN_ROOT}/skills/<skill-name>/...`. Do NOT use a per-skill-dir variable — no such substrate variable exists; using one silently expands to empty string and produces bogus bare-root paths.
- `checkpoint.sh` must be idempotent and use atomic writes (temp file + rename) to survive rapid Edit sequences.
