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
for seat in claude claude_fallback codex cursor grok opencode antigravity; do
  got=$(resolve "MODEL_$seat=pinned-$seat" NOT_SET "MODEL_$seat" 'script-default')
  [ "$got" = "pinned-$seat" ] && ok "MODEL_$seat is configurable" || bad "MODEL_$seat ignored — got '$got'"
done

# The seat is 'antigravity' — that is what --reviewers takes. Its variable happens to be called
# AGY_REVIEW_MODEL, and the call site used to read MODEL_agy, so MODEL_antigravity was accepted,
# stored, and read by nothing: a setting that vanished in silence, in the file written to stop
# settings vanishing in silence. MODEL_agy stays working as an alias for anyone who wrote it.
got=$(resolve 'MODEL_agy=via-alias' NOT_SET MODEL_antigravity 'script-default')
[ "$got" = "via-alias" ] && ok "MODEL_agy still resolves as an alias of MODEL_antigravity" \
  || bad "the MODEL_agy alias broke — got '$got'"

# A suffix that names no seat is stored (ship-feature reads this file too and may know seats this
# repo does not) but must be REPORTED, or a typo reads as a setting that simply had no effect.
out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "MODEL_opencde=oops\n" > "$2"; . "$0"; panel_config_load 2>&1 >/dev/null' "$LIB" x "$CFG")
printf '%s' "$out" | grep -q "no reviewer seat named 'opencde'" && ok "a MODEL_ key for a non-seat is reported" \
  || bad "typo'd seat name swallowed — got: $out"

# ...and a seat this repo does not drive itself must NOT be reported: ship-feature's plan panel
# uses these, and warning about them would train everyone to ignore the warning.
out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "MODEL_kimi3=x\nMODEL_grok45high=y\n" > "$2"; . "$0"; panel_config_load 2>&1 >/dev/null' "$LIB" x "$CFG")
[ -z "$out" ] && ok "plan-review seats are not reported as unknown" || bad "plan seat warned about — got: $out"

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

# Sourced from a shell that is not bash. The reset that stops an inherited PANEL_CFG_* from acting
# as a precedence layer used `${!PANEL_CFG_@}`, a bash-only expansion: under zsh it was a
# `bad substitution` that aborted panel_config_load mid-way. The first fix returned early on a
# non-bash shell — which SKIPPED the reset, so PANEL_CFG_REVIEWERS=cursor still won while the
# warning claimed nothing was loaded. Three reviewers caught that. The reset is now bounded and
# portable, and it runs before every return.
ZCFG="$WORK/other-shell.cfg"   # never the shared $CFG: later cases reuse that file
if command -v zsh >/dev/null 2>&1; then
  printf 'REVIEWERS=from-file\nMODEL_grok=g46\n' > "$ZCFG"

  # THE FINDING: an inherited PANEL_CFG_* must not survive, on the shell where the sweep cannot run.
  got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$WORK/absent" PANEL_CFG_REVIEWERS=cursor \
    zsh -c '. "$0"; panel_config_load 2>/dev/null; panel_resolve NOPE REVIEWERS "$1"' "$LIB" 'claude,codex,grok,opencode')
  [ "$got" = "claude,codex,grok,opencode" ] && ok "zsh: an inherited PANEL_CFG_* is cleared, not honoured" \
    || bad "zsh: PANEL_CFG_REVIEWERS survived — got '$got'"

  # ...and a real file still loads there, rather than aborting on a bash expansion.
  got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$ZCFG" PANEL_CFG_REVIEWERS=cursor \
    zsh -c '. "$0"; panel_config_load 2>/dev/null; printf "%s|%s" "$(panel_resolve NOPE REVIEWERS d)" "$(panel_resolve NOPE MODEL_grok grok-4.5)"' "$LIB")
  [ "$got" = "from-file|g46" ] && ok "zsh: the config file loads (no bash-only expansion on the path)" \
    || bad "zsh: file did not load — got '$got'"

  err=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$ZCFG" \
    zsh -c '. "$0"; panel_config_load' "$LIB" 2>&1 >/dev/null)
  case "$err" in
    *"bad substitution"*) bad "zsh: still aborts on a bash expansion — got: $err" ;;
    *) ok "zsh: loading is silent, with no bad substitution" ;;
  esac
else
  echo "  skip [-] zsh not installed"
fi

# A SECOND load must not leave the first one's values behind — including a key for a seat this
# repo does not know, which is stored on purpose (ship-feature may know it) and therefore has to be
# cleared on purpose. The bounded reset cannot see such a key by construction, and the bash sweep
# is not available on every shell, so PANEL_CFG_KEYS from the previous load is what closes it.
for _sh in bash zsh; do
  command -v "$_sh" >/dev/null 2>&1 || { echo "  skip [-] $_sh not installed"; continue; }
  printf 'MODEL_future=old\nREVIEWERS=first\n' > "$WORK/load-a.cfg"
  printf 'REVIEWERS=second\n'                   > "$WORK/load-b.cfg"
  got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin "$_sh" -c '. "$0"
    PR_RELAY_CONFIG="$1" panel_config_load 2>/dev/null
    PR_RELAY_CONFIG="$2" panel_config_load 2>/dev/null
    printf "%s|%s" "$(panel_resolve NOPE MODEL_future none)" "$(panel_resolve NOPE REVIEWERS d)"' \
    "$LIB" "$WORK/load-a.cfg" "$WORK/load-b.cfg")
  [ "$got" = "none|second" ] && ok "$_sh: a second load clears the first one's unknown-seat key" \
    || bad "$_sh: stale key survived a reload — got '$got'"
done
unset _sh

# A bash parent EXPORTS BASH_VERSION, so a zsh or dash child inherits it. Any guard that reads
# that name to mean "this is bash" then runs the bash-only expansion in the wrong shell: under zsh
# a `bad substitution`, under dash an abort that takes the whole load with it. Every case above
# uses `env -i`, which scrubs the variable and hides this entirely — so it gets its own cases.
for _sh in zsh dash; do
  command -v "$_sh" >/dev/null 2>&1 || { echo "  skip [-] $_sh not installed"; continue; }
  got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$WORK/absent" \
    BASH_VERSION=5.2.0 PANEL_CFG_REVIEWERS=cursor \
    "$_sh" -c '. "$0"; panel_config_load 2>/dev/null; panel_resolve NOPE REVIEWERS "$1"' "$LIB" 'script-default')
  [ "$got" = "script-default" ] && ok "$_sh: an inherited BASH_VERSION does not trigger the bash-only sweep" \
    || bad "$_sh: inherited BASH_VERSION broke the load — got '$got'"

  err=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$WORK/absent" BASH_VERSION=5.2.0 \
    "$_sh" -c '. "$0"; panel_config_load' "$LIB" 2>&1 >/dev/null)
  case "$err" in
    *"ad substitution"*) bad "$_sh: inherited BASH_VERSION still causes a bad substitution — got: $err" ;;
    *) ok "$_sh: no bad substitution with BASH_VERSION inherited" ;;
  esac
done
unset _sh

# A shell with no `printf -v` at all — dash is the one that ships everywhere, so this case needs no
# extra dependency. Storing is impossible there, so the honest answer is to say so and load
# nothing; the reset has already run, so nothing inherited is left standing either.
if command -v dash >/dev/null 2>&1; then
  printf 'REVIEWERS=from-file\n' > "$ZCFG"
  err=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$ZCFG" PANEL_CFG_REVIEWERS=cursor \
    dash -c '. "$0"; panel_config_load' "$LIB" 2>&1 >/dev/null)
  printf '%s' "$err" | grep -q "printf -v" && ok "a shell without printf -v says so" \
    || bad "no printf -v, but no warning either — got: $err"

  got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$ZCFG" PANEL_CFG_REVIEWERS=cursor \
    dash -c '. "$0"; panel_config_load 2>/dev/null; panel_resolve NOPE REVIEWERS "$1"' "$LIB" 'script-default')
  [ "$got" = "script-default" ] && ok "a shell without printf -v still clears an inherited PANEL_CFG_*" \
    || bad "dash: inherited value survived the refusal — got '$got'"
else
  echo "  skip [-] dash not installed"
fi

# HOME unset — cron, systemd, containers. The relay supports it on purpose; a bare \$HOME under
# set -u would abort the whole run.
if env -u HOME -i PATH=/usr/bin:/bin bash -c 'set -u; . "$0"; panel_config_load; panel_resolve A B c' "$LIB" >/dev/null 2>&1; then
  ok "an unset HOME does not abort the loader"
else bad "unset HOME aborted panel_config_load"; fi

echo "-------------------------------------------"
echo "panel config tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
