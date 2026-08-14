#!/usr/bin/env bash
# lib-panel.sh — the one place that answers "who reviews, with which model".
#
# Before this file the answer lived in five: a default assigned in pr-review-relay, another in
# review-local, SHIP_FEATURE_REVIEWERS in ship-feature's own config, ten per-seat environment
# variables whose names follow no rule (PR_RELAY_OPENCODE_MODEL, AGY_REVIEW_MODEL,
# GROK_REVIEW_MODEL...), and a models.conf that NOTHING read. Two opposite failures came out of
# that on 2026-08-13: `cursor` kept reviewing for weeks after it was dropped, because callers that
# skip --reviewers get the script default rather than the configured panel; and a model pinned in
# models.conf had never taken effect at all.
#
# Precedence, strongest first — the whole contract, in one list:
#   1. the command-line flag        (--reviewers)
#   2. the environment variable     (CLAUDE_REVIEW_MODEL, PR_RELAY_AGENT_TIMEOUT, ...)
#   3. this config file
#   4. the default assigned in the script
#
# 4 stays on purpose: the tool must work on a machine with no config at all.

# The file is READ, never SOURCED. A config that is sourced is arbitrary code executed by a tool
# that runs from cron. Parsing uses shell built-ins only — no tr, no sed, no cut — because the
# relay does not validate PATH until later, and a config parser that shells out before that check
# would be exactly the hole the check exists to close.
# Every seat a MODEL_/EFFORT_ suffix may name. The relay's own panel, plus the plan-review seats
# that ship-feature drives from this same file (grok45high is grok at high effort, kimi3 is the
# opencode runner on another model). claude_fallback is not a seat: it is claude's second choice
# when the first model is unavailable.
PANEL_SEATS="claude claude_fallback codex cursor antigravity grok opencode qwen kimi3 grok45high"

# PANEL_CFG_* is this loader's OUTPUT, never an input. Without this reset an exported
# PANEL_CFG_REVIEWERS=cursor acts as a fifth, undocumented precedence layer that outranks the
# script default — the exact shape of the bug this file exists to close, arriving through the fix
# for it.
#
# The reset is bounded rather than a wildcard sweep, and that is what makes it PORTABLE. The set of
# keys panel_resolve can ever be asked for is known: three fixed keys, plus MODEL_/EFFORT_ for each
# seat. Enumerating variables by prefix has no portable form — `${!PANEL_CFG_@}` is bash-only, and
# under zsh it is a `bad substitution` that aborted this function mid-way and handed the caller a
# half-load. Listing the keys instead needs no expansion any shell lacks, and no external command
# (this file parses with built-ins only, because the relay has not validated PATH yet).
#
# The bash sweep still runs where it works, to also clear a key stored for a seat this repo does
# not know about. It is the extra, never the guarantee.
panel_reset_cfg() {
  local _k _s _rest
  for _k in REVIEWERS PLAN_REVIEWERS AGENT_TIMEOUT; do unset "PANEL_CFG_$_k"; done
  # The seat list is peeled a word at a time rather than iterated with `for _s in $PANEL_SEATS`:
  # zsh does not word-split an unquoted parameter, so that loop passed the WHOLE list as one name
  # and unset failed with "invalid parameter name" — the reset silently doing nothing, in the
  # function whose job is to make sure a stale value cannot survive.
  _rest="$PANEL_SEATS"
  while [ -n "$_rest" ]; do
    _s="${_rest%% *}"
    if [ -n "$_s" ]; then unset "PANEL_CFG_MODEL_$_s"; unset "PANEL_CFG_EFFORT_$_s"; fi
    if [ "$_rest" = "$_s" ]; then _rest=; else _rest="${_rest#* }"; fi
  done
  # Probe the expansion, never the shell's name: bash exports BASH_VERSION, so a bash parent hands
  # it to a zsh or dash child, and a `[ -n "$BASH_VERSION" ]` guard then runs `${!PANEL_CFG_@}`
  # there anyway — `bad substitution`, and under dash the whole load aborts. The eval'd string is
  # a fixed literal, never anything read from the config file.
  if ( eval 'set -- ${!PANEL_CFG_@}' ) 2>/dev/null; then
    eval 'for _k in ${!PANEL_CFG_@}; do unset "$_k"; done'
  fi
  PANEL_CFG_KEYS=
}

panel_config_load() {
  # HOME can be unset — cron, systemd units, minimal containers — and this runs under `set -u`,
  # where a bare $HOME aborts the whole relay. The script supports that environment on purpose
  # (there is a round-state fallback for exactly it), so no config simply means no config.
  #
  # The reset runs FIRST, before every early return, so a stale value cannot survive on a machine
  # with no config at all — including the "wrong shell" path, where returning early without it
  # would leave the inherited value in place while claiming nothing was loaded.
  panel_reset_cfg

  # Storing a value needs `printf -v`. bash and zsh both have it; dash and other POSIX shells do
  # not, and there the assignment below would fail once per line and store nothing, leaving a
  # caller with a config file it believes was read. Probed rather than inferred from a shell name,
  # because BASH_VERSION can be exported into another shell by a parent. The probe runs AFTER the
  # reset, so the "cannot load" path still cannot leave an inherited value standing.
  if ! ( printf -v _panel_probe '%s' x ) 2>/dev/null; then
    echo "warning: this shell has no 'printf -v'; lib-panel.sh loaded no config" >&2
    return 0
  fi

  local cfg="${PR_RELAY_CONFIG:-}"
  if [ -z "$cfg" ]; then
    [ -n "${HOME:-}" ] || return 0
    cfg="$HOME/.config/pr-review-relay/config"
  fi
  PANEL_CONFIG_PATH="$cfg"
  [ -e "$cfg" ] || return 0
  if [ ! -r "$cfg" ]; then
    echo "warning: panel config not readable: $cfg (using defaults)" >&2
    return 0
  fi

  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    # strip a leading BOM and surrounding whitespace with built-ins only
    line="${line#$'\xef\xbb\xbf'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|'#'*) continue;; esac
    case "$line" in
      *=*) key="${line%%=*}"; val="${line#*=}" ;;
      *) echo "warning: ignoring malformed line in $cfg: $line" >&2; continue ;;
    esac
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    # A key must be a bare identifier BEFORE it reaches printf -v. `printf -v name[i]` assigns to
    # an array element, and bash evaluates that subscript as an arithmetic expression — so a key
    # like MODEL_x[$(id)] would execute the command substitution while merely "parsing" the file.
    # The whole point of not sourcing this file is that reading it must not run anything.
    case "$key" in
      ''|*[!A-Za-z0-9_]*)
        echo "warning: ignoring invalid key in $cfg: $key" >&2; continue ;;
    esac
    case "$key" in
      REVIEWERS|PLAN_REVIEWERS|AGENT_TIMEOUT) ;;
      MODEL_*|EFFORT_*)
        # The documented rule is that the suffix is the SEAT name you pass to --reviewers. One
        # seat broke it: antigravity's variable is AGY_REVIEW_MODEL, so the call site read
        # MODEL_agy and MODEL_antigravity was accepted, stored, and never read by anything —
        # a setting that vanishes in silence, which is the failure this whole file exists to
        # prevent. The seat name is now the real key and `agy` is folded into it.
        case "$key" in
          MODEL_agy)  key=MODEL_antigravity ;;
          EFFORT_agy) key=EFFORT_antigravity ;;
        esac
        # A suffix that is not a seat is still stored — ship-feature reads this same file and may
        # know seats this repo does not — but it is reported, so a typo does not pass for a
        # setting that simply had no effect.
        case " $PANEL_SEATS " in
          *" ${key#*_} "*) ;;
          *) echo "warning: no reviewer seat named '${key#*_}' in $cfg: $key (stored, but nothing here reads it)" >&2 ;;
        esac
        ;;
      *) echo "warning: unknown key in $cfg: $key" >&2; continue ;;
    esac
    # An empty value means "not configured" — the resolver falls through to the script default.
    printf -v "PANEL_CFG_$key" '%s' "$val"
    PANEL_CFG_KEYS="${PANEL_CFG_KEYS:+$PANEL_CFG_KEYS }$key"
  done < "$cfg"
}

# Resolve one setting through the precedence list. $1 = env var name, $2 = config key,
# $3 = the script default.
#
# EMPTY MEANS "not configured", at every layer — the same rule the call sites already used with
# ${VAR:-default}. It is tempting to make an empty value mean "deliberately disable this", which
# is what ship-feature's load_config does, but the two conventions must not be mixed: the relay's
# own tests run with e.g. CURSOR_REVIEW_MODEL= on purpose, so that an override exported in a dev
# shell cannot make an assertion pass by accident. Treating that empty as "disabled" silently
# unpins the model and the argv assertion fails with a bare `--model`.
panel_resolve() {
  local env_name="$1" cfg_key="$2" fallback="${3-}" cfg_name="PANEL_CFG_$2" v
  eval "v=\${$env_name:-}"
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  eval "v=\${$cfg_name:-}"
  if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  printf '%s' "$fallback"
}
