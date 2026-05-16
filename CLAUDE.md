# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A single-file Neovim plugin (`lua/neogit-ai-commit/init.lua`) that hooks into Neogit's `gitcommit` filetype to generate AI-powered commit messages via any OpenAI-compatible API.

## Running tests

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/neogit_ai_commit_spec.lua" -c "qa!"
```

Requires plenary.nvim installed via lazy.nvim (standard `~/.local/share/nvim/lazy/plenary.nvim`).

## Architecture

The entire plugin lives in one module (`M`). `M.setup()` wires up two things:
- An autocmd on `FileType gitcommit` that sets buffer-local keymaps (`<C-c><C-m>` / `<C-c><return>`)
- One user command: `:NeogitAICommit`

`M.generate_commit_message` follows the flow:
1. Call `neogit.lib.git.cli.diff.cached.call().stdout` to get staged diff
2. Read lines before the first comment-char line as optional user-provided prefix
3. POST to the configured OpenAI-compatible API with the appropriate system prompt
4. Run `clean_commit_message()` to strip markdown fences
5. Replace buffer content: AI message + blank separator + original comment block preserved

## Key behaviours to preserve

- **Comment section preservation**: The buffer always ends with the original git comment lines (lines starting with `core.commentChar`, default `#`). Never discard them.
- **User prefix**: If the user typed text before the comment section, it is forwarded to the API as context ("already started writing…"). The AI response replaces that text rather than appending to it.
- `clean_commit_message` enforces that the second line is a truly empty string (no whitespace), which git requires for the subject/body separator.

## Dependencies (runtime)

- `neogit.lib.git` — for diff and config (commentChar)
- `plenary.curl` — synchronous HTTP POST (`curl.post`)

No build step, no linter configuration in this repo.
