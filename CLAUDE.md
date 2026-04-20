# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file zsh script (`danger-zone.zsh`) that guards against accidental mistakes when running dangerous commands against a **production** environment. Generic by design: the commands that count as "dangerous," the signals that count as "production," and the banner labels are all user-configurable arrays. Zero-config defaults protect `rails console`. It's sourced from `~/.zshrc` (or equivalent). There is no build, test, or package system for the runtime script — changes are tested by sourcing the file into a live shell. Optional `bats` tests live under `tests/`.

## Architecture

Four architectural layers, in execution order. Understanding how they fit together is the key to editing this file safely.

### 1. `chpwd` zsh hook (`_danger_zone_chpwd` + `_danger_zone_load_conf`)
On directory change, walks up from `$PWD` looking for `.danger-zone.conf`. If found and not previously loaded, **parses** it line-by-line — no `source`, no `eval`. Recognized directives: `trigger`, `prod_env`, `marker`, `label <k> = <v>`, `reset`. Each directive appends to its corresponding global array (`DANGER_ZONE_TRIGGERS`, etc.); `reset` clears all arrays so a project can start fresh. Blank lines and `#`-prefixed comments are ignored; unknown directives emit a stderr warning with `filename:lineno`. Because the file is data rather than code, there's no allowlist — a malicious repo can at worst inject meaningless triggers, never run code.

### 2. `accept-line` ZLE widget override (`_danger_zone_accept_line`)
Fires **before** the command runs, when the user hits Enter. This is where the confirmation prompt lives. It must run before `preexec` so an aborted command never spawns banners. It matches `$BUFFER` against `DANGER_ZONE_TRIGGERS` (not argv), so it catches `bundle exec rails c`, `./bin/rails console`, and inline-env variants. On confirmation it sets tmux options `@danger_zone_confirmed=1` and `@danger_zone_matched_trigger=<trigger>` so later stages (summary, audit log) know the command was user-approved and which trigger fired. Strict mode (`DANGER_ZONE_STRICT=1`) requires typing the trigger's **label** instead of `yes`.

### 3. `preexec` / `precmd` zsh hooks
- `preexec` runs after confirmation, matches the same trigger list against the executed command, and calls `_danger_zone_set_tmux_alert <label>` if `_danger_zone_is_production` returns true.
- `precmd` runs when control returns to the shell (i.e., the dangerous command exited) and tears down the alert via `_danger_zone_clear_tmux_alert`, which also writes the audit log line if `DANGER_ZONE_LOG` is set.

### 4. tmux visuals (`_danger_zone_set_tmux_alert` / `_danger_zone_clear_tmux_alert`)
State is stored as pane-scoped tmux options prefixed `@danger_zone*` so one pane's state can't leak across panes. Setup creates two 2-row banner panes (above and below the console pane) running an inline `sh` script that repaints on `WINCH`; the triggering pane gets a tinted oxblood background and the window is renamed to `▲ <label>`. Teardown kills the banner panes, restores the pane background and window name, and re-enables tmux's default `automatic-rename`. If `$TMUX` is unset, these are no-ops — the guard still works via the confirmation prompt.

## Config surfaces

Three layers, applied in order:

1. **Built-in defaults** — set in the script itself (Rails-only). Applied via `(( ${#ARRAY[@]} )) || ARRAY=(...)` so re-sourcing doesn't clobber user additions.
2. **`~/.zshrc`** — users append to `DANGER_ZONE_TRIGGERS`, `DANGER_ZONE_PROD_ENV_VARS`, `DANGER_ZONE_PROD_COMMAND_MARKERS`, `DANGER_ZONE_LABELS` after sourcing (zsh code; full expressiveness).
3. **Per-project `.danger-zone.conf`** — parsed (not sourced) by the `chpwd` hook. Data-only; safe to commit and share across a team.

Runtime knobs (env vars): `DANGER_ZONE_DISABLED`, `DANGER_ZONE_STRICT`, `DANGER_ZONE_LOG`.

## Editing notes

- **Do not name locals `path`, `status`, or any other zsh special parameter.** `path` is aliased to `$PATH` as an array; shadowing it inside a function nukes command lookup, and the error surfaces as mysterious "command not found" or downstream "no such file or directory" on redirects. We use `cfg`, `verdict`, etc. instead.
- **Pattern matching uses zsh `[[ ... == *...* ]]`**, not regex. Triggers and markers are substrings; keep them simple.
- **`${(P)var}`** is zsh's parameter-name expansion — evaluating `$var` as a var name. Used in `_danger_zone_is_production` to walk `DANGER_ZONE_PROD_ENV_VARS`. Do not "simplify" to something else.
- **Widget ordering**: `_danger_zone_accept_line` must run first (aborts before anything else), then `preexec`, then `precmd` on return. The hook registrations at the bottom encode this; don't reorder.
- **Banner `sh -c '...'` quoting**: the inline banner script is wrapped in single quotes inside the zsh string. Any single quote inside the banner body breaks the outer quoting. Prefer double quotes internally; if you must interpolate a dynamic value, pass it via `tmux split-window -e "NAME=$value"` as we do for `DZ_LABEL`.
- **Pane-scoping**: every tmux `set-option`/`show-options` uses `-p` (pane-scoped). Without this, state leaks across panes and panes interfere with each other's teardowns.
- After editing, reload with `source ./danger-zone.zsh` in each active shell. zsh does not auto-reload.
