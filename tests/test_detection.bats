#!/usr/bin/env bats
#
# Pure-logic tests for danger-zone.zsh. The zle widget, preexec/precmd hooks,
# and tmux visuals are tested by hand — only the detection + parser functions
# are exercised here. Requires `zsh` and `bats-core`.

SCRIPT="${BATS_TEST_DIRNAME}/../danger-zone.zsh"

# Build a fresh zsh -c invocation that sources the script in an isolated env:
#   - empty temp HOME
#   - empty temp cwd so the chpwd hook can't find a .danger-zone.conf
#   - kubectl stubbed out so detection doesn't hit a real cluster
_dz() {
  local body="$1"
  HOME=$(mktemp -d) zsh -f -c "
    cd \"\$(mktemp -d)\"
    kubectl() { return 1; }
    source \"$SCRIPT\"
    $body
  "
}

# ── _danger_zone_is_production ────────────────────────────────────────────────

@test "detects RAILS_ENV=production via default prod env vars" {
  run _dz 'RAILS_ENV=production _danger_zone_is_production "rails c" && echo HIT'
  [[ "$output" == *HIT* ]]
}

@test "detects RACK_ENV=production via default prod env vars" {
  run _dz 'RACK_ENV=production _danger_zone_is_production "rails c" && echo HIT'
  [[ "$output" == *HIT* ]]
}

@test "does not flag non-production env" {
  run _dz 'RAILS_ENV=development _danger_zone_is_production "rails c" || echo MISS'
  [[ "$output" == *MISS* ]]
}

@test "detects inline RAILS_ENV=production in command string" {
  run _dz '_danger_zone_is_production "RAILS_ENV=production rails c" && echo HIT'
  [[ "$output" == *HIT* ]]
}

@test "detects custom prod env var once appended" {
  run _dz '
    DANGER_ZONE_PROD_ENV_VARS+=( DJANGO_ENV )
    DJANGO_ENV=production _danger_zone_is_production "python manage.py shell" && echo HIT
  '
  [[ "$output" == *HIT* ]]
}

@test "DANGER_ZONE_DISABLED=1 short-circuits detection" {
  run _dz 'DANGER_ZONE_DISABLED=1 RAILS_ENV=production _danger_zone_is_production "rails c" || echo OFF'
  [[ "$output" == *OFF* ]]
}

# ── _danger_zone_match_trigger ────────────────────────────────────────────────

@test "matches default rails console trigger" {
  run _dz '_danger_zone_match_trigger "bundle exec rails console"'
  [[ "$output" == "rails console" ]]
}

@test "matches default rails c trigger" {
  run _dz '_danger_zone_match_trigger "./bin/rails c"'
  [[ "$output" == "rails c" ]]
}

@test "matches custom trigger once appended" {
  run _dz '
    DANGER_ZONE_TRIGGERS+=( "python manage.py shell" )
    _danger_zone_match_trigger "python manage.py shell --ipython"
  '
  [[ "$output" == "python manage.py shell" ]]
}

@test "does not match unrelated command" {
  run _dz '_danger_zone_match_trigger "ls -la" && echo HIT || echo MISS'
  [[ "$output" == *MISS* ]]
}

# ── _danger_zone_label_for ────────────────────────────────────────────────────

@test "returns default label for known trigger" {
  run _dz '_danger_zone_label_for "rails console"'
  [[ "$output" == "PRODUCTION RAILS CONSOLE" ]]
}

@test "falls back to generic label for unknown trigger" {
  run _dz '_danger_zone_label_for "no such trigger"'
  [[ "$output" == "PRODUCTION COMMAND" ]]
}

@test "custom label via DANGER_ZONE_LABELS" {
  run _dz '
    DANGER_ZONE_LABELS+=( "psql" "PRODUCTION DATABASE" )
    _danger_zone_label_for "psql"
  '
  [[ "$output" == "PRODUCTION DATABASE" ]]
}

# ── _danger_zone_load_conf ────────────────────────────────────────────────────

@test "parses trigger/prod_env/marker/label directives" {
  run _dz '
    CONF=$(mktemp)
    cat > "$CONF" <<EOF
trigger  python manage.py shell
prod_env DJANGO_ENV
marker   DJANGO_SETTINGS_MODULE=config.settings.production
label    python manage.py shell = PRODUCTION DJANGO SHELL
EOF
    _danger_zone_load_conf "$CONF"
    echo "trig=[$(_danger_zone_match_trigger "python manage.py shell --ipython")]"
    DJANGO_ENV=production _danger_zone_is_production "python manage.py shell" && echo "prod=OK"
    echo "label=[$(_danger_zone_label_for "python manage.py shell")]"
  '
  [[ "$output" == *"trig=[python manage.py shell]"* ]]
  [[ "$output" == *"prod=OK"* ]]
  [[ "$output" == *"label=[PRODUCTION DJANGO SHELL]"* ]]
}

@test "parser ignores blank lines and comments" {
  run _dz '
    CONF=$(mktemp)
    cat > "$CONF" <<EOF
# this is a comment

trigger  custom cmd

# another comment
EOF
    _danger_zone_load_conf "$CONF"
    _danger_zone_match_trigger "custom cmd --now"
  '
  [[ "$output" == "custom cmd" ]]
}

@test "parser warns on unknown directive but continues" {
  run _dz '
    CONF=$(mktemp)
    cat > "$CONF" <<EOF
frobnicate foo
trigger  good trigger
EOF
    _danger_zone_load_conf "$CONF" 2>&1
    _danger_zone_match_trigger "good trigger here"
  '
  [[ "$output" == *"unknown directive: frobnicate"* ]]
  [[ "$output" == *"good trigger"* ]]
}

@test "parser warns on malformed label" {
  run _dz '
    CONF=$(mktemp)
    printf "label no_equals_sign\n" > "$CONF"
    _danger_zone_load_conf "$CONF" 2>&1
  '
  [[ "$output" == *"label needs"* ]]
}

@test "reset directive clears built-in defaults" {
  run _dz '
    CONF=$(mktemp)
    cat > "$CONF" <<EOF
reset
trigger only thing
EOF
    _danger_zone_load_conf "$CONF"
    echo "triggers=[${DANGER_ZONE_TRIGGERS[*]}]"
  '
  [[ "$output" == "triggers=[only thing]" ]]
}

# ── find_project_config ───────────────────────────────────────────────────────

@test "find_project_config returns the nearest .danger-zone.conf walking up" {
  run _dz '
    root=$(mktemp -d)
    mkdir -p "$root/a/b/c"
    touch "$root/a/.danger-zone.conf"
    cd "$root/a/b/c"
    _danger_zone_find_project_config
  '
  [[ "$output" == */a/.danger-zone.conf ]]
}

@test "find_project_config returns nothing when none exists" {
  run _dz '
    cd "$(mktemp -d)"
    _danger_zone_find_project_config && echo HIT || echo MISS
  '
  [[ "$output" == *MISS* ]]
}
