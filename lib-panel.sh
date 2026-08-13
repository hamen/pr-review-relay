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
panel_config_load() {
  # HOME can be unset — cron, systemd units, minimal containers — and this runs under `set -u`,
  # where a bare $HOME aborts the whole relay. The script supports that environment on purpose
  # (there is a round-state fallback for exactly it), so no config simply means no config.
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
    case "$key" in
      REVIEWERS|PLAN_REVIEWERS|AGENT_TIMEOUT) ;;
      MODEL_*|EFFORT_*) ;;
      *) echo "warning: unknown key in $cfg: $key" >&2; continue ;;
    esac
    # An empty value is a deliberate "unset this", not "not configured".
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
