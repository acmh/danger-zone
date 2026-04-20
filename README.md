# danger-zone

A zsh guard against mistakes in a production shell. Intercepts dangerous commands, requires an explicit confirmation, and paints the tmux pane blood-red for as long as the session lasts. Language- and tool-agnostic: you register the commands that count as dangerous and the signals that count as production.

## Install

```zsh
# Clone somewhere stable
git clone <this-repo> ~/.zsh/danger-zone

# Add one line to ~/.zshrc
source ~/.zsh/danger-zone/danger-zone.zsh
```

Open a new shell. That's it.

## Out of the box

With no configuration, `danger-zone` protects the Rails console case:

- Triggers: `rails console`, `rails c`
- Prod signals: `RAILS_ENV=production`, `RACK_ENV=production`, kubectl namespace containing `prod`

```
$ RAILS_ENV=production rails console
▲ DANGER ▲  You are about to enter a PRODUCTION RAILS CONSOLE.
Any mistake here will affect real users and real data.

Type yes to continue, anything else to abort:
```

Typing anything other than `yes` aborts. Typing `yes` proceeds, and a red banner appears above and below the pane until the console exits.

## Configure for your stack

### In `~/.zshrc` (after sourcing)

```zsh
DANGER_ZONE_TRIGGERS+=( "python manage.py shell" "flask shell" "psql" )
DANGER_ZONE_PROD_ENV_VARS+=( DJANGO_ENV APP_ENV NODE_ENV )
DANGER_ZONE_PROD_COMMAND_MARKERS+=( "NODE_ENV=production" "-h prod-db" )
DANGER_ZONE_LABELS+=(
  "python manage.py shell" "PRODUCTION DJANGO SHELL"
  "psql"                   "PRODUCTION DATABASE"
)
```

> Note: the bracket-subscript form (`DANGER_ZONE_LABELS[key with spaces]=val`) trips zsh's glob parser when the key contains spaces. Use the `+=( "key" "value" ... )` list form above instead.

### Per-project `.danger-zone.conf`

Drop a `.danger-zone.conf` file at your repo root. `danger-zone` walks up from `$PWD` on every directory change, parses the nearest one it finds, and loads it. Teams can check this file in, and every member's shell picks it up automatically — no allowlist, no prompt, no code execution.

```
# myrepo/.danger-zone.conf (Django example)
trigger  python manage.py shell
trigger  ./manage.py dbshell
prod_env DJANGO_ENV
label    python manage.py shell = PRODUCTION DJANGO SHELL
```

`examples/` contains starter configs for Python and Node.

**Format.** One directive per line. `#` starts a comment. Unknown directives produce a stderr warning but don't abort.

| Directive | Effect |
| --- | --- |
| `trigger <substring>` | Append to `DANGER_ZONE_TRIGGERS`. |
| `prod_env <VAR>` | Append to `DANGER_ZONE_PROD_ENV_VARS`. Trigger fires when this var's value is `production`. |
| `marker <substring>` | Append to `DANGER_ZONE_PROD_COMMAND_MARKERS`. Literal substring that also means prod (e.g. `-h prod-db`). |
| `label <trigger> = <banner text>` | Set the banner label shown when this trigger fires. |
| `reset` | Clear all four arrays (drop the built-in Rails defaults for this project). |

**Why a custom format?** The file is **data, not code**. Earlier versions sourced a `.danger-zone.zsh`; that needed a direnv-style allowlist because a malicious repo could ship an arbitrary-code payload. A parsed config can't execute anything, so the allowlist goes away and teams can just commit the file.

## Runtime knobs

| Var | Effect |
| --- | --- |
| `DANGER_ZONE_DISABLED=1` | Bypass the guard entirely. Useful in CI or when debugging the script. |
| `DANGER_ZONE_STRICT=1` | Requires typing the full label (e.g., `PRODUCTION RAILS CONSOLE`) instead of `yes`. Harder to muscle-memory past. |
| `DANGER_ZONE_LOG=~/.danger-zone.log` | Append `ISO-timestamp \| user \| host \| trigger \| duration` to the given file after each confirmed session. |

## Config arrays

| Array | Meaning |
| --- | --- |
| `DANGER_ZONE_TRIGGERS` | Substrings that, if present in the command buffer, arm the guard. |
| `DANGER_ZONE_PROD_ENV_VARS` | Env var names whose value == `production` means you're in prod. |
| `DANGER_ZONE_PROD_COMMAND_MARKERS` | Substrings in the command (e.g. `-h prod-db`) that also mean prod. |
| `DANGER_ZONE_LABELS` | Assoc array — trigger substring → banner label. Missing keys fall back to `PRODUCTION COMMAND`. |

Inside a `.danger-zone.conf`, use the `reset` directive to start from empty arrays (drops the built-in Rails defaults for that project).

## Limitations

- Only catches commands submitted via `accept-line` (the normal Enter key). Commands fed in as scripts (`zsh -c '...'`, heredocs from other tools, etc.) bypass the guard.
- Matching is literal substring, not regex. `psql` as a trigger will match every `psql` command — narrow with `DANGER_ZONE_PROD_COMMAND_MARKERS` if your dev DB also uses `psql`.
- tmux visuals only render inside tmux. Outside tmux you still get the confirmation prompt; that's the load-bearing piece anyway.
- The kubectl-namespace check runs a subprocess on every `accept-line` evaluation of a trigger. If it's slow for you, drop the relevant section of `_danger_zone_is_production`.

## Tests

```zsh
brew install bats-core
bats tests/
```

Tests cover the pure detection logic. Widget/tmux behavior is tested by hand.
