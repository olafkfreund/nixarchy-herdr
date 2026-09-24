#!/bin/bash
# Cases for bin/herdr-sessions, run against fakes: nothing here reaches a real
# herdr server, ssh or Hyprland. Each case runs the script in a temp HOME with
# fake herdr, ssh and hyprctl first on PATH, and the fake herdr is steered by
# FAKE_* variables. Prints `ok <case>` or `FAIL <case>`, exits 0 only if every
# case passed.
#
#   bash tests/herdr-sessions.sh

set -u

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$here/../bin/herdr-sessions"

tmp=$(mktemp -d)
# Background processes the cases start, so none outlives the run.
bg=()
stop_bg() {
  local p
  # The child first: killing its bash alone would leave the sleep behind.
  for p in "${bg[@]}"; do pkill -P "$p"; kill "$p"; wait "$p"; done 2>/dev/null
  bg=()
}
trap 'stop_bg; rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/run"
chmod 700 "$tmp/run"

export HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" XDG_CACHE_HOME="$tmp/home/.cache"
export PATH="$tmp/bin:$PATH"
export FAKE_LOG="$tmp/log" FAKE_CLIENTS="$tmp/clients"
# Anything herdr set in the calling shell is not the fake's business.
for var in ${!HERDR_@}; do unset "$var"; done

# The fake herdr. `session list` names one running session, s1; its snapshot
# has one agent and is padded out to FAKE_SNAPSHOT_BYTES. Every call logs its
# argv to FAKE_LOG, one argument per line.
cat > "$tmp/bin/herdr" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" >> "$FAKE_LOG"
[[ ${1-} == --session ]] && shift 2
case "$1 ${2-}" in
  "session list")
    printf '{"sessions":[{"name":"s1","default":false,"running":true,"session_dir":"/nonexistent"}]}\n' ;;
  "api snapshot")
    # stdout off the sleep, or a killed fake would leave it holding the pipe.
    sleep "${FAKE_SNAPSHOT_SLEEP:-0}" >/dev/null 2>&1
    pad=$(head -c "${FAKE_SNAPSHOT_BYTES:-0}" /dev/zero | tr '\0' x)
    printf '{"result":{"snapshot":{"version":"fake","pad":"%s","workspaces":[{"workspace_id":"ws1","label":"proj"}],"agents":[{"agent_status":"idle","pane_id":"w1:p1","workspace_id":"ws1","terminal_title":"fake agent"}]}}}\n' "$pad" ;;
  "agent prompt") exit "${FAKE_PROMPT_RC:-0}" ;;
  "agent get")
    # The pad goes first, so an answer cut short at a cap has no status left.
    pad=$(head -c "${FAKE_AGENT_GET_BYTES:-0}" /dev/zero | tr '\0' x)
    printf '{"result":{"agent":{"pad":"%s","agent_status":"%s"}}}\n' "$pad" "${FAKE_AGENT_STATUS:-idle}" ;;
  "agent read") printf '%s' "${FAKE_SCREEN-screen}" ;;
  *) exit 1 ;;
esac
FAKE

# The fake ssh records what it was asked and answers nothing, which is an
# unreachable host as far as the script can tell. With FAKE_SSH_RUN set it runs
# the remote command here instead, against the fake herdr.
cat > "$tmp/bin/ssh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" >> "$FAKE_LOG"
[[ -n ${FAKE_SSH_RUN-} ]] || exit 0
while [[ $# -gt 0 && $1 != -- ]]; do shift; done
shift 2
exec bash -c "$*"
FAKE

# The fake hyprctl's windows are whatever FAKE_CLIENTS holds; every other
# call, dispatch included, does nothing.
cat > "$tmp/bin/hyprctl" <<'FAKE'
#!/bin/sh
if [ "$1" = clients ]; then cat "$FAKE_CLIENTS"; else echo "[]"; fi
FAKE
chmod +x "$tmp/bin/herdr" "$tmp/bin/ssh" "$tmp/bin/hyprctl"

failed=0
# check <case> <command...>: the command's status is the verdict, its output
# is dropped.
check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok $name"; else echo "FAIL $name"; failed=1; return 1; fi
}

# Each case starts with a clean log and the fake's defaults.
reset() {
  : > "$FAKE_LOG"
  echo "[]" > "$FAKE_CLIENTS"
  unset FAKE_SNAPSHOT_BYTES FAKE_SNAPSHOT_SLEEP FAKE_PROMPT_RC FAKE_AGENT_STATUS \
    FAKE_AGENT_GET_BYTES FAKE_SCREEN FAKE_SSH_RUN
}

# fake_client <args...>: a live process with that command line, for the window
# matching to find; its pid is the last one in bg. The `; :` keeps bash from
# exec-ing sleep in its place, which would lose the args. Waits until the
# command line is readable, or the script could look before it exists.
fake_client() {
  bash -c 'sleep 30; :' "$@" 2>/dev/null &
  bg+=($!)
  local i
  for ((i = 0; i < 100; i++)); do
    grep -qaF 'sleep 30; :' "/proc/$!/cmdline" 2>/dev/null && return 0
    sleep 0.05
  done
}

# fake_windows <pid> <n>: that process owns n windows, 0x10 upwards, and
# nothing else owns any.
fake_windows() {
  jq -n --argjson pid "$1" --argjson n "$2" \
    '[range($n) | {pid: $pid, address: "0x\(. + 10)", workspace: {name: "1"}}]' > "$FAKE_CLIENTS"
}

# Case 1: a snapshot bigger than one exec argument may be (128 KB on Linux)
# still lists, with its agents.
reset
out=$(FAKE_SNAPSHOT_BYTES=200000 "$script" list)
check "1 big snapshot" jq -e '.sessions[0].name == "s1"
  and .sessions[0].agentList[0].title == "fake agent"' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

# Case 2: a server that never answers its snapshot does not hold the list up.
# The outer timeout only stops a failing run from hanging the suite.
reset
start=$SECONDS
out=$(FAKE_SNAPSHOT_SLEEP=30 timeout 20 "$script" list)
took=$((SECONDS - start))
# shellcheck disable=SC2016 # $took is a jq variable
check "2 stuck server" jq -e --argjson took "$took" \
  '$took <= 8 and .sessions[0].name == "s1"' <<<"$out" ||
  printf '  took %ss, got: %.200s\n' "$took" "$out"

# Case 3: herdr refusing the prompt is a failure, not a success with whatever
# the screen happens to show.
reset
out=$(printf hi | FAKE_PROMPT_RC=1 FAKE_AGENT_STATUS=blocked "$script" prompt s1 w1:p1)
check "3 prompt refused" jq -e '.ok == false
  and (.error | contains("waiting on a question"))' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

# Case 4: control characters never reach the agent's terminal; the fake logs
# each argument on its own line, so the prompt text is one whole line.
reset
out=$(printf 'a\033[201~b\rc\177d' | "$script" prompt s1 w1:p1)
check "4 control characters" grep -qFx 'a[201~bcd' "$FAKE_LOG" ||
  printf '  logged: %q\n' "$(cat "$FAKE_LOG")"

# Case 5: ssh is told not to forward anything. The fake answers nothing, so
# the list itself fails as unreachable; only what ssh was handed is checked.
reset
out=$("$script" --host h1 list)
# shellcheck disable=SC2329 # called through check
ssh_told_no_forwarding() {
  grep -qFx ForwardAgent=no "$FAKE_LOG" && grep -qFx PermitLocalCommand=no "$FAKE_LOG" &&
    [[ $out == *unreachable* ]]
}
check "5 ssh options" ssh_told_no_forwarding ||
  printf '  got: %.200s\n  logged: %q\n' "$out" "$(cat "$FAKE_LOG")"

# Case 6: a process owning two windows (ghostty, footclient) is matched to
# neither, so open starts a window rather than focusing the wrong one. With
# one window it still matches.
reset
fake_client herdr --session s1
fake_windows "${bg[-1]}" 2
two=$("$script" list)
fake_windows "${bg[-1]}" 1
one=$("$script" list)
stop_bg
check "6 one process, two windows" jq -en --argjson two "$two" --argjson one "$one" \
  '$two.sessions[0].windowAddress == "" and $one.sessions[0].windowAddress == "0x10"' ||
  printf '  two: %s, one: %s\n' "$(jq -c '[.sessions[] | .windowAddress]' <<<"$two")" \
    "$(jq -c '[.sessions[] | .windowAddress]' <<<"$one")"

# Case 7: a narrow COLUMNS does not cut the command line short of its
# --session.
reset
fake_client herdr --session s1 "--x$(printf 'x%.0s' {1..200})"
fake_windows "${bg[-1]}" 1
out=$(COLUMNS=40 "$script" list)
stop_bg
check "7 long command line" jq -e '.sessions[0].windowAddress == "0x10"' <<<"$out" ||
  printf '  got: %s\n' "$(jq -c '[.sessions[] | .windowAddress]' <<<"$out")"

# Case 8: a path that merely ends in herdr, like an editor on its source, is
# not herdr.
reset
fake_client vim /tmp/src/herdr --session s1
fake_windows "${bg[-1]}" 1
out=$("$script" list)
stop_bg
check "8 not herdr" jq -e '.sessions[0].windowAddress == ""' <<<"$out" ||
  printf '  got: %s\n' "$(jq -c '[.sessions[] | .windowAddress]' <<<"$out")"

# Case 9: demo mode touches its own file and nothing else in the cache
# directory, however that directory came to hold it.
reset
cache="$XDG_CACHE_HOME/omarchy-herdr"
mkdir -p "$cache/keep"
: > "$cache/keep.txt"
chmod 644 "$cache/keep.txt"
out=$("$script" demo on)
# shellcheck disable=SC2329 # called through check
cache_left_alone() {
  [[ -d $cache/keep && $(stat -c %a "$cache/keep.txt") == 644 ]]
}
check "9 demo leaves the cache alone" cache_left_alone ||
  printf '  got: %.200s\n  left: %s\n' "$out" "$(ls -l "$cache")"
"$script" demo off >/dev/null

# Case 11: a remote agent answering with megabytes is read only up to its cap.
# Cut short, the answer has no status, and with nothing on screen either the
# agent is unreachable rather than an answer. The outer timeout only stops a
# failing run from hanging the suite.
reset
start=$SECONDS
out=$(printf hi | FAKE_SSH_RUN=1 FAKE_AGENT_GET_BYTES=3000000 FAKE_SCREEN='' \
  timeout 20 "$script" --host h1 prompt s1 w1:p1)
took=$((SECONDS - start))
# shellcheck disable=SC2016 # $took and $len are jq variables
check "11 big remote agent" jq -e --argjson took "$took" --argjson len "${#out}" \
  '$took <= 10 and $len < 65536 and .ok == false' <<<"$out" ||
  printf '  took %ss, %s bytes, got: %.200s\n' "$took" "${#out}" "$out"

exit "$failed"
