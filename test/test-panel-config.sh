#!/usr/bin/env bash
# test-panel-config.sh — the config file is the one place that says who reviews and with which
# model. These tests exist because the alternative failed in production: `cursor` was dropped from
# the panel on 2026-08-13 and kept reviewing for weeks, because callers that omit --reviewers got
# the default assigned in the script rather than the configured panel. The first test below is
# that incident, in a form that fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB="$HERE/../lib-panel.sh"
PASS=0; FAIL=0
ok()  { echo "  ok   [-] $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CFG="$WORK/config"

# Every case runs with the model/panel environment scrubbed. Without this the suite reads the
# developer's own exports and "the file wins" passes for the wrong reason — the exact trap the
# relay's own tests already guard against for CURSOR_REVIEW_MODEL.
resolve() { # $1 = config body (or ""), rest = panel_resolve args
  local body="$1"; shift
  printf '%s' "$body" > "$CFG"
  env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
    bash -c '. "$0"; panel_config_load 2>/dev/null; panel_resolve "$@"' "$LIB" "$@"
}

echo "panel config tests:"

# THE INCIDENT: a panel set in the file must reach a caller that passes no flag at all.
got=$(resolve 'REVIEWERS=claude,codex' NOT_SET_ANYWHERE REVIEWERS 'claude,codex,grok,opencode')
[ "$got" = "claude,codex" ] && ok "a panel in the config reaches a caller that omits --reviewers" \
  || bad "config panel ignored — got '$got'"

# No config at all → the script default. The machine with nothing configured must still work.
got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$WORK/absent" \
  bash -c '. "$0"; panel_config_load 2>/dev/null; panel_resolve NOPE REVIEWERS "$1"' "$LIB" 'claude,codex,grok,opencode')
[ "$got" = "claude,codex,grok,opencode" ] && ok "no config file → the script default still applies" \
  || bad "missing config broke the default — got '$got'"

# Precedence: env beats file.
got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" CLAUDE_REVIEW_MODEL=sonnet \
  bash -c 'printf "MODEL_claude=opus\n" > "$2"; . "$0"; panel_config_load 2>/dev/null; panel_resolve CLAUDE_REVIEW_MODEL MODEL_claude fallback' "$LIB" x "$CFG")
[ "$got" = "sonnet" ] && ok "the environment beats the config file" || bad "env lost to the file — got '$got'"

# An EMPTY value means "not configured", at every layer — NOT "disable". The relay's own tests
# run with CURSOR_REVIEW_MODEL= on purpose so a stray export cannot make an assertion pass; if
# empty meant "disabled" the model would silently unpin and argv would carry a bare --model.
got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" CURSOR_REVIEW_MODEL= \
  bash -c 'printf "" > "$2"; . "$0"; panel_config_load 2>/dev/null; panel_resolve CURSOR_REVIEW_MODEL MODEL_cursor composer-2.5' "$LIB" x "$CFG")
[ "$got" = "composer-2.5" ] && ok "an empty env value means 'not set', not 'disabled'" \
  || bad "empty env unpinned the model — got '$got'"
got=$(resolve 'MODEL_cursor=' CURSOR_REVIEW_MODEL MODEL_cursor composer-2.5)
[ "$got" = "composer-2.5" ] && ok "an empty file value means 'not set' too" || bad "empty file value — got '$got'"

# Every seat named in a panel must be configurable. This is the cursor bug in its second form:
# a seat you can name but cannot pin drifts back to a default nobody chose.
for seat in claude claude_fallback codex cursor grok opencode agy; do
  got=$(resolve "MODEL_$seat=pinned-$seat" NOT_SET "MODEL_$seat" 'script-default')
  [ "$got" = "pinned-$seat" ] && ok "MODEL_$seat is configurable" || bad "MODEL_$seat ignored — got '$got'"
done

# Parsing is fail-noisy, never fail-silent: a config that disappears without a word is the very
# defect this file exists to remove.
out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "TYPO_KEY=x\nno-equals-here\n" > "$2"; . "$0"; panel_config_load 2>&1 >/dev/null' "$LIB" x "$CFG")
printf '%s' "$out" | grep -q "unknown key" && ok "an unknown key is reported" || bad "unknown key swallowed"
printf '%s' "$out" | grep -q "malformed" && ok "a malformed line is reported" || bad "malformed line swallowed"

# The file is READ, never SOURCED. A config that executes is arbitrary code run by a tool that
# runs from cron.
canary="$WORK/pwned"
env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "REVIEWERS=\$(touch %s)\n" "$3" > "$2"; . "$0"; panel_config_load >/dev/null 2>&1' "$LIB" x "$CFG" "$canary"
[ -e "$canary" ] && bad "the config file was EXECUTED — command substitution ran" \
  || ok "the config is read, never sourced (no command substitution)"

# The KEY side of the same rule, which the test above does not cover. `printf -v name[i]` assigns
# to an array element and bash evaluates that subscript as arithmetic — so MODEL_x[$(cmd)] would
# run cmd while the file was merely being parsed. The key must be a bare identifier first.
for inj in 'MODEL_x[$(touch %s)]=y' 'MODEL_x[`touch %s`]=y' 'EFFORT_a[$(touch %s)]=z'; do
  canary="$WORK/pwned-key"; rm -f "$canary"
  printf "$inj\n" "$canary" > "$CFG"
  out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
    bash -c '. "$0"; panel_config_load; panel_resolve NOPE REVIEWERS d' "$LIB" 2>&1)
  if [ -e "$canary" ]; then bad "key injection EXECUTED a command: $inj"
  elif printf '%s' "$out" | grep -q "invalid key"; then ok "an injected key is rejected and reported: ${inj%%=*}"
  else bad "injected key neither ran nor was reported: $inj (out: $out)"; fi
done
rm -f "$WORK/pwned-key"

# A key that is a plain identifier but unknown is still just an unknown key — the charset check
# must not swallow that distinction, or the warning stops telling you which mistake you made.
out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "NOT_A_KEY=1\n" > "$2"; . "$0"; panel_config_load; panel_resolve NOPE REVIEWERS d' "$LIB" x "$CFG" 2>&1)
printf '%s' "$out" | grep -q "unknown key" && ok "a valid-looking but unknown key still says 'unknown key'" \
  || bad "unknown identifier key misreported — got: $out"

# PANEL_CFG_* is the loader's output, not an input. An exported one would be a fifth precedence
# layer nobody documented, outranking the script default — cursor coming back through the very fix
# that removed it. This is asserted with NO config file, the case where the leak survives longest.
got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$WORK/absent" PANEL_CFG_REVIEWERS=cursor \
  bash -c '. "$0"; panel_config_load 2>/dev/null; panel_resolve NOPE REVIEWERS "$1"' "$LIB" 'claude,codex,grok,opencode')
[ "$got" = "claude,codex,grok,opencode" ] && ok "an inherited PANEL_CFG_* is not a precedence layer" \
  || bad "PANEL_CFG_REVIEWERS from the environment won — got '$got'"

# ...and it must not survive a load that DOES find a file either, for a key that file omits.
got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" PANEL_CFG_MODEL_claude=ghost \
  bash -c 'printf "REVIEWERS=claude\n" > "$2"; . "$0"; panel_config_load 2>/dev/null; panel_resolve NOPE MODEL_claude opus' "$LIB" x "$CFG")
[ "$got" = "opus" ] && ok "an inherited PANEL_CFG_* is dropped for a key the file omits" \
  || bad "stale PANEL_CFG_MODEL_claude survived the load — got '$got'"

# HOME unset — cron, systemd, containers. The relay supports it on purpose; a bare \$HOME under
# set -u would abort the whole run.
if env -u HOME -i PATH=/usr/bin:/bin bash -c 'set -u; . "$0"; panel_config_load; panel_resolve A B c' "$LIB" >/dev/null 2>&1; then
  ok "an unset HOME does not abort the loader"
else bad "unset HOME aborted panel_config_load"; fi

echo "-------------------------------------------"
echo "panel config tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
