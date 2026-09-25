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

# THE TIMEOUT DEFAULT, pinned as a literal. `panel_resolve` takes its fallback as an ARGUMENT, so
# every test above proves the ladder and none of them proves which number the script actually hands
# it — a plan review that dies on the clock reports no findings, which reads exactly like a clean
# review, so the number is worth pinning. Reading the literal out of the script is the only way to
# assert it without a full relay run; change 500 here and this goes red, which is its whole job.
#
# ~/.config/pr-review-relay/config's AGENT_TIMEOUT is the one place to override it, for this tool
# AND for ship-feature's plan-review, which reads this same file.
RELAY="$HERE/../pr-review-relay"
got=$(grep -o 'panel_resolve PR_RELAY_AGENT_TIMEOUT AGENT_TIMEOUT [0-9]*' "$RELAY" | awk '{print $4}')
[ "$got" = "500" ] && ok "the built-in per-reviewer timeout is 500s" \
  || bad "the built-in timeout default is '$got', not 500"

# review-local runs the SAME panel with the SAME seats off the SAME config key, so its literal has to
# agree with the relay's. Two entrypoints in one repo quietly disagreeing on a no-config machine is
# the drift this default exists to remove, and nothing else in the suite compares them.
LOCAL="$HERE/../review-local"
got=$(grep -o 'panel_resolve PR_RELAY_AGENT_TIMEOUT AGENT_TIMEOUT [0-9]*' "$LOCAL" | awk '{print $4}')
[ "$got" = "500" ] && ok "review-local uses the same 500s default as the relay" \
  || bad "review-local's timeout default is '$got', not 500"

# The file still beats that literal — the override has to keep working, or the default becomes a cap.
got=$(resolve 'AGENT_TIMEOUT=470' PR_RELAY_AGENT_TIMEOUT AGENT_TIMEOUT 500)
[ "$got" = "470" ] && ok "AGENT_TIMEOUT in the config beats the built-in default" \
  || bad "config timeout ignored — got '$got'"

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
# glm and gemini are ship-feature's CURRENT plan seats. Before they were listed here, every relay run
# on a machine that pinned them printed "no reviewer seat named 'glm'" — always wrong, so ignored.
out=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" \
  bash -c 'printf "MODEL_glm=x\nMODEL_gemini=y\nEFFORT_glm=z\n" > "$2"; . "$0"; panel_config_load 2>&1 >/dev/null' "$LIB" x "$CFG")
[ -z "$out" ] && ok "glm and gemini keys are not reported as unknown" || bad "glm/gemini warned about — got: $out"

# --- panel_seat_pins: what each seat's dispatch line shows -----------------------
# Sourced in the order both entry points use (panel, opencode, grok), because the grok and
# opencode arms call those libs' resolvers. Globals the scripts set at load time are passed in.
GLIB="$HERE/../lib-grok.sh"; OLIB="$HERE/../lib-opencode.sh"
pins() { # $1 = config body, $2 = seat, rest = VAR=value assignments for the call
  local body="$1" seat="$2"; shift 2
  printf '%s' "$body" > "$CFG"
  env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG="$CFG" "$@" \
    bash -c 'set -u; . "$0"; . "$1"; . "$2"; panel_config_load 2>/dev/null; panel_seat_pins "$3"' "$LIB" "$OLIB" "$GLIB" "$seat"
}
got=$(pins '' grok)
[ "$got" = " (model=grok-4.6, effort=medium)" ] && ok "unpinned grok shows the grok-4.6 / medium defaults" || bad "unpinned grok pins: '$got'"
got=$(pins $'MODEL_grok=grok-4.7\nEFFORT_grok=low\n' grok)
[ "$got" = " (model=grok-4.7, effort=low)" ] && ok "MODEL_grok / EFFORT_grok reach the grok line" || bad "file grok pins: '$got'"
got=$(pins $'MODEL_grok=grok-4.7\n' grok GROK_REVIEW_MODEL=env-grok)
[ "$got" = " (model=env-grok, effort=medium)" ] && ok "GROK_REVIEW_MODEL beats MODEL_grok on the line too" || bad "env grok pin: '$got'"
got=$(pins $'MODEL_opencode=zai/glm-5.3\n' opencode)
[ "$got" = " (model=zai/glm-5.3)" ] && ok "MODEL_opencode reaches the opencode line" || bad "opencode pin: '$got'"
got=$(pins '' opencode)
[ "$got" = " (model=cli default)" ] && ok "unpinned opencode says cli default" || bad "unpinned opencode: '$got'"
got=$(pins '' codex CODEX_REVIEW_MODEL=gpt-x)
[ "$got" = " (model=gpt-x, effort=cli default)" ] && ok "codex shows its model and an unpinned effort" || bad "codex pins: '$got'"
got=$(pins '' claude CLAUDE_REVIEW_MODEL=opus CLAUDE_REVIEW_FALLBACK_MODEL=sonnet CLAUDE_REVIEW_EFFORT=high)
[ "$got" = " (model=opus, fallback=sonnet, effort=high)" ] && ok "claude shows model, fallback and effort" || bad "claude pins: '$got'"
# Every global unset, under set -u: must not abort (both callers run set -u).
got=$(pins '' claude); rc=$?
[ "$rc" = 0 ] && [ "$got" = " (model=cli default, fallback=none, effort=cli default)" ] \
  && ok "claude with no globals set does not abort under set -u" || bad "claude unset globals: rc=$rc '$got'"
# A seat with no pin, and a name nobody knows: empty, exit 0 — never an error.
got=$(pins '' qwen); rc=$?
[ "$rc" = 0 ] && [ -z "$got" ] && ok "qwen (no pin) prints nothing" || bad "qwen: rc=$rc '$got'"
got=$(pins '' no-such-seat); rc=$?
[ "$rc" = 0 ] && [ -z "$got" ] && ok "an unknown seat prints nothing and succeeds" || bad "unknown seat: rc=$rc '$got'"
# A caller that sources lib-panel.sh ALONE (pr-review-distill does) gets nothing for grok rather
# than "command not found".
got=$(env -i HOME="$WORK" PATH=/usr/bin:/bin PR_RELAY_CONFIG=/dev/null \
  bash -c 'set -u; . "$0"; panel_seat_pins grok' "$LIB" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$got" ] && ok "grok pins without lib-grok.sh print nothing, no error" || bad "grok without its lib: rc=$rc '$got'"

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
