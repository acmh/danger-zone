# ~/.zsh/danger-zone.zsh
#
# Guard against accidental dangerous commands against production. Generic:
# triggers, prod-signal env vars, and labels are user-configurable arrays.
# Zero-config defaults protect `rails console` under RAILS_ENV=production.

# ── Configuration ─────────────────────────────────────────────────────────────
: ${DANGER_ZONE_DISABLED:=0}
: ${DANGER_ZONE_STRICT:=0}
: ${DANGER_ZONE_LOG:=""}

typeset -gaU DANGER_ZONE_TRIGGERS
typeset -gaU DANGER_ZONE_PROD_ENV_VARS
typeset -gaU DANGER_ZONE_PROD_COMMAND_MARKERS
typeset -gA  DANGER_ZONE_LABELS

(( ${#DANGER_ZONE_TRIGGERS[@]} ))             || DANGER_ZONE_TRIGGERS=( "rails console" "rails c" )
(( ${#DANGER_ZONE_PROD_ENV_VARS[@]} ))        || DANGER_ZONE_PROD_ENV_VARS=( RAILS_ENV RACK_ENV )
(( ${#DANGER_ZONE_PROD_COMMAND_MARKERS[@]} )) || DANGER_ZONE_PROD_COMMAND_MARKERS=( "RAILS_ENV=production" "--environment=production" )
(( ${#DANGER_ZONE_LABELS[@]} ))               || DANGER_ZONE_LABELS=(
  "rails console" "PRODUCTION RAILS CONSOLE"
  "rails c"       "PRODUCTION RAILS CONSOLE"
)

# Internal per-shell state
typeset -g _DANGER_ZONE_LOADED_FILE=""

# Convenience: let a per-project config start from a clean slate.
danger_zone_reset() {
  DANGER_ZONE_TRIGGERS=()
  DANGER_ZONE_PROD_ENV_VARS=()
  DANGER_ZONE_PROD_COMMAND_MARKERS=()
  DANGER_ZONE_LABELS=()
}

# ── Detection logic ───────────────────────────────────────────────────────────
_danger_zone_is_production() {
  local cmd="$1"

  [[ "$DANGER_ZONE_DISABLED" == "1" ]] && return 1

  local var
  for var in "${DANGER_ZONE_PROD_ENV_VARS[@]}"; do
    [[ "${(P)var}" == "production" ]] && return 0
  done

  if command -v kubectl &>/dev/null; then
    local ns
    ns=$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null)
    [[ "$ns" == *prod* || "$ns" == *production* ]] && return 0
  fi

  local marker
  for marker in "${DANGER_ZONE_PROD_COMMAND_MARKERS[@]}"; do
    [[ "$cmd" == *"$marker"* ]] && return 0
  done

  return 1
}

_danger_zone_match_trigger() {
  local cmd="$1"
  local trigger
  for trigger in "${DANGER_ZONE_TRIGGERS[@]}"; do
    [[ "$cmd" == *"$trigger"* ]] && { printf "%s" "$trigger"; return 0; }
  done
  return 1
}

_danger_zone_label_for() {
  local trigger="$1"
  printf "%s" "${DANGER_ZONE_LABELS[$trigger]:-PRODUCTION COMMAND}"
}

# ── Per-project config loader ─────────────────────────────────────────────────
# Walks up from $PWD for `.danger-zone.conf` and parses it line-by-line. The
# file is DATA, not code — each line is `<directive> <value>`. No eval, no
# source, so a malicious repo can't ship a config that executes code.
#
# Directives:
#   trigger  <substring>                      append to DANGER_ZONE_TRIGGERS
#   prod_env <VAR>                            append to DANGER_ZONE_PROD_ENV_VARS
#   marker   <substring>                      append to DANGER_ZONE_PROD_COMMAND_MARKERS
#   label    <trigger> = <label>              set DANGER_ZONE_LABELS[trigger]
#   reset                                     clear all four arrays (drop defaults)
#
# Blank lines and lines starting with `#` are ignored. Unknown directives
# produce a stderr warning but don't abort.

_danger_zone_find_project_config() {
  local dir="${1:-$PWD}"
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if [[ -f "$dir/.danger-zone.conf" ]]; then
      printf "%s" "$dir/.danger-zone.conf"
      return 0
    fi
    dir="${dir:h}"
  done
  return 1
}

_danger_zone_load_conf() {
  local conf="$1"
  local line directive rest key val
  local lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    (( lineno++ ))
    # Strip leading whitespace via read-into-split (IFS default trims leading)
    read -r directive rest <<< "$line"
    [[ -z "$directive" || "$directive" = \#* ]] && continue
    case "$directive" in
      trigger)  [[ -n "$rest" ]] && DANGER_ZONE_TRIGGERS+=( "$rest" ) ;;
      prod_env) [[ -n "$rest" ]] && DANGER_ZONE_PROD_ENV_VARS+=( "$rest" ) ;;
      marker)   [[ -n "$rest" ]] && DANGER_ZONE_PROD_COMMAND_MARKERS+=( "$rest" ) ;;
      label)
        if [[ "$rest" = *" = "* ]]; then
          key="${rest%% = *}"
          val="${rest#* = }"
          DANGER_ZONE_LABELS+=( "$key" "$val" )
        else
          print -u2 "danger-zone: $conf:$lineno: label needs 'key = value', got: $rest"
        fi
        ;;
      reset) danger_zone_reset ;;
      *) print -u2 "danger-zone: $conf:$lineno: unknown directive: $directive" ;;
    esac
  done < "$conf"
}

_danger_zone_chpwd() {
  local conf
  conf=$(_danger_zone_find_project_config) || return
  [[ "$conf" == "$_DANGER_ZONE_LOADED_FILE" ]] && return
  _danger_zone_load_conf "$conf"
  _DANGER_ZONE_LOADED_FILE="$conf"
}

# ── tmux visual alert ─────────────────────────────────────────────────────────
_danger_zone_set_tmux_alert() {
  [[ -z "$TMUX" ]] && return
  local label="${1:-PRODUCTION COMMAND}"

  local pane_id
  pane_id=$(tmux display-message -p '#{pane_id}')

  tmux set-option -p @danger_zone "1"
  tmux set-option -p @danger_zone_pane "$pane_id"

  # Save window name, rename to a danger marker (propagates to terminal tab too)
  local orig_window_name
  orig_window_name=$(tmux display-message -p '#{window_name}')
  tmux set-option -p @danger_zone_orig_window_name "$orig_window_name"
  tmux rename-window "▲ $label"

  # Record session start for post-exit duration summary
  tmux set-option -p @danger_zone_start_epoch "$(date +%s)"

  # Dedicated 2-row banner panes above AND below the triggering pane
  # Layout (2 rows each): text row + bevel row, with the bevel adjacent to the console
  local existing_banner
  existing_banner=$(tmux show-options -pqv @danger_zone_banner_pane 2>/dev/null)
  if [[ -z "$existing_banner" ]]; then
    local banner_cmd='
badge="▌ ▲ DANGER ▲ ▐"
msg="${DZ_LABEL:-PRODUCTION COMMAND} — DO NOT MESS AROUND"
render() {
  cols=${COLUMNS:-$(tmux display -p "#{pane_width}" 2>/dev/null)}
  [ -z "$cols" ] && cols=80
  blen=$(printf "%s" "$badge" | wc -m | tr -d " ")
  clen=$(printf "%s" "$msg"   | wc -m | tr -d " ")
  total=$((blen + blen + clen))
  printf "\033[48;2;139;0;0m\033[38;2;255;229;229m\033[1m"
  if [ $total -gt $cols ]; then
    pad=$(( (cols - clen) / 2 ))
    [ $pad -lt 0 ] && pad=0
    printf "%*s%s%*s" "$pad" "" "$msg" "$((cols - pad - clen))" ""
  else
    gap=$(( cols - total ))
    lgap=$(( gap / 2 ))
    rgap=$(( gap - lgap ))
    printf "%s%*s%s%*s%s" "$badge" "$lgap" "" "$msg" "$rgap" "" "$badge"
  fi
  printf "\033[0m"
}
bevel() {
  cols=${COLUMNS:-$(tmux display -p "#{pane_width}" 2>/dev/null)}
  [ -z "$cols" ] && cols=80
  printf "\033[48;2;139;0;0m\033[38;2;200;70;70m"
  i=0; while [ $i -lt $cols ]; do printf "%s" "$1"; i=$((i+1)); done
  printf "\033[0m"
}
draw() {
  printf "\033[H\033[2J"
  if [ "$PG_POS" = "top" ]; then
    printf "\033[1;1H"; render
    printf "\033[2;1H"; bevel "▄"
  else
    printf "\033[1;1H"; bevel "▀"
    printf "\033[2;1H"; render
  fi
}
trap draw WINCH
draw
while :; do sleep 86400; done
'

    local top_banner_pane_id bottom_banner_pane_id
    top_banner_pane_id=$(tmux split-window -vb -l 2 -t "$pane_id" -d \
      -e "PG_POS=top" -e "DZ_LABEL=$label" \
      -P -F '#{pane_id}' "sh -c '$banner_cmd'" 2>/dev/null)
    bottom_banner_pane_id=$(tmux split-window -v  -l 2 -t "$pane_id" -d \
      -e "PG_POS=bot" -e "DZ_LABEL=$label" \
      -P -F '#{pane_id}' "sh -c '$banner_cmd'" 2>/dev/null)

    if [[ -n "$top_banner_pane_id" ]]; then
      tmux set-option -p -t "$top_banner_pane_id" remain-on-exit off 2>/dev/null
      tmux set-option -p @danger_zone_banner_pane "$top_banner_pane_id"
    fi
    if [[ -n "$bottom_banner_pane_id" ]]; then
      tmux set-option -p -t "$bottom_banner_pane_id" remain-on-exit off 2>/dev/null
      tmux set-option -p @danger_zone_bottom_banner_pane "$bottom_banner_pane_id"
    fi
  fi

  # Deep oxblood tinted background on the triggering pane (24-bit hex)
  tmux select-pane -t "$pane_id" -P 'bg=#1a0505'
}

_danger_zone_clear_tmux_alert() {
  [[ -z "$TMUX" ]] && return
  [[ "$(tmux show-options -pv @danger_zone 2>/dev/null)" != "1" ]] && return

  local pane_id
  pane_id=$(tmux show-options -pv @danger_zone_pane 2>/dev/null)

  # Kill both banner panes so the resulting layout reflow piggybacks on the
  # border/style repaint below (avoids a flicker frame).
  local top_banner_pane_id bottom_banner_pane_id
  top_banner_pane_id=$(tmux show-options -pqv @danger_zone_banner_pane 2>/dev/null)
  bottom_banner_pane_id=$(tmux show-options -pqv @danger_zone_bottom_banner_pane 2>/dev/null)
  [[ -n "$top_banner_pane_id"    ]] && tmux kill-pane -t "$top_banner_pane_id"    2>/dev/null
  [[ -n "$bottom_banner_pane_id" ]] && tmux kill-pane -t "$bottom_banner_pane_id" 2>/dev/null

  # Revert the triggering pane's tinted background
  [[ -n "$pane_id" ]] && tmux select-pane -t "$pane_id" -P 'default' 2>/dev/null

  # Restore the original window name and re-enable default automatic-rename behavior
  local orig_window_name
  orig_window_name=$(tmux show-options -pqv @danger_zone_orig_window_name 2>/dev/null)
  if [[ -n "$orig_window_name" ]]; then
    tmux rename-window "$orig_window_name" 2>/dev/null
    tmux set-option -wu automatic-rename 2>/dev/null
  fi

  # Post-session summary + audit log (only if the confirmation prompt was accepted)
  local start_epoch confirmed trigger
  start_epoch=$(tmux show-options -pqv @danger_zone_start_epoch 2>/dev/null)
  confirmed=$(tmux show-options -pqv @danger_zone_confirmed 2>/dev/null)
  trigger=$(tmux show-options -pqv @danger_zone_matched_trigger 2>/dev/null)
  if [[ -n "$start_epoch" && "$confirmed" == "1" ]]; then
    local duration=$(( $(date +%s) - start_epoch ))
    local mins=$((duration / 60))
    local secs=$((duration % 60))
    print -P ""
    print -P "%F{160}%B▲ PRODUCTION SESSION ENDED ▲%b%f  duration: ${mins}m ${secs}s"

    if [[ -n "$DANGER_ZONE_LOG" ]]; then
      mkdir -p "${DANGER_ZONE_LOG:h}" 2>/dev/null
      printf '%s | %s | %s | %s | %ss\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${USER:-unknown}" \
        "${HOST:-$(hostname 2>/dev/null)}" \
        "${trigger:-unknown}" \
        "$duration" >> "$DANGER_ZONE_LOG"
    fi
  fi

  tmux set-option -pu @danger_zone
  tmux set-option -pu @danger_zone_pane
  tmux set-option -pu @danger_zone_banner_pane 2>/dev/null
  tmux set-option -pu @danger_zone_bottom_banner_pane 2>/dev/null
  tmux set-option -pu @danger_zone_orig_window_name 2>/dev/null
  tmux set-option -pu @danger_zone_start_epoch 2>/dev/null
  tmux set-option -pu @danger_zone_confirmed 2>/dev/null
  tmux set-option -pu @danger_zone_matched_trigger 2>/dev/null
}

# ── zsh hooks ─────────────────────────────────────────────────────────────────
_danger_zone_preexec() {
  local cmd="$1"
  local trigger
  trigger=$(_danger_zone_match_trigger "$cmd") || return
  if _danger_zone_is_production "$cmd"; then
    _danger_zone_set_tmux_alert "$(_danger_zone_label_for "$trigger")"
  fi
}

_danger_zone_precmd() {
  _danger_zone_clear_tmux_alert
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _danger_zone_preexec
add-zsh-hook precmd  _danger_zone_precmd
add-zsh-hook chpwd   _danger_zone_chpwd

# Fire once for the starting directory so a shell opened inside a project
# picks up its config without needing to `cd` first.
_danger_zone_chpwd

# ── accept-line widget override ───────────────────────────────────────────────
# Requires explicit confirmation before running any registered trigger in a
# production context. Runs BEFORE preexec so aborting avoids spawning visuals.
# Matches on $BUFFER, catching `bundle exec rails c`, `./bin/rails console`,
# inline-env variants — anything whose buffer matches.
_danger_zone_accept_line() {
  local trigger
  if trigger=$(_danger_zone_match_trigger "$BUFFER"); then
    if _danger_zone_is_production "$BUFFER"; then
      local label expected response=""
      label=$(_danger_zone_label_for "$trigger")
      expected="yes"
      [[ "$DANGER_ZONE_STRICT" == "1" ]] && expected="$label"

      zle -I
      print -P ""
      print -P "%F{196}%B▲ DANGER ▲%b%f  You are about to enter a %F{196}%B$label%b%f."
      print -P "%F{246}Any mistake here will affect real users and real data.%f"
      print ""
      printf "Type \033[1;33m%s\033[0m to continue, anything else to abort: " "$expected"
      read -r response < /dev/tty
      if [[ "$response" != "$expected" ]]; then
        print -P "%F{160}Aborted.%f"
        BUFFER=""
        zle reset-prompt
        return 0
      fi
      if [[ -n "$TMUX" ]]; then
        tmux set-option -p @danger_zone_confirmed "1" 2>/dev/null
        tmux set-option -p @danger_zone_matched_trigger "$trigger" 2>/dev/null
      fi
    fi
  fi
  zle .accept-line
}
zle -N accept-line _danger_zone_accept_line
