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
export FAKE_PROC_DIR="$tmp/proc" FAKE_KILL_LOG="$tmp/kill-log"
# Anything herdr set in the calling shell is not the fake's business.
for var in ${!HERDR_@}; do unset "$var"; done

# The fake herdr. `session list` names one running session, s1; its snapshot
# has one agent, or FAKE_AGENTS and FAKE_TABS in its place, and is padded out
# to FAKE_SNAPSHOT_BYTES. Every call logs its
# argv to FAKE_LOG, one argument per line.
cat > "$tmp/bin/herdr" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" >> "$FAKE_LOG"
name=s1
if [[ ${1-} == --session ]]; then name=$2; shift 2; fi
case "$1 ${2-}" in
  "session list")
    sleep "${FAKE_LIST_SLEEP:-0}" >/dev/null 2>&1
    printf '{"sessions":%s}\n' "$FAKE_SESSIONS" ;;
  "api snapshot")
    sleep_var="FAKE_SNAPSHOT_SLEEP_$name"
    body_var="FAKE_SNAPSHOT_BODY_$name"
    printf 'snapshot-pid %s %s\n' "$name" "$$" >> "$FAKE_LOG"
    # stdout off the sleep, or a killed fake would leave it holding the pipe.
    sleep "${!sleep_var:-${FAKE_SNAPSHOT_SLEEP:-0}}" >/dev/null 2>&1
    if [[ -n ${!body_var-} ]]; then printf '%s\n' "${!body_var}"; exit; fi
    pad=$(head -c "${FAKE_SNAPSHOT_BYTES:-0}" /dev/zero | tr '\0' x)
    agents=${FAKE_AGENTS:-'[{"agent_status":"idle","pane_id":"w1:p1","workspace_id":"ws1","terminal_title":"fake agent"}]'}
    printf '{"result":{"snapshot":{"version":"fake","pad":"%s","workspaces":[{"workspace_id":"ws1","label":"proj"}],"tabs":%s,"agents":%s}}}\n' \
      "$pad" "${FAKE_TABS:-[]}" "$agents" ;;
  "agent prompt")
    printf 'prompt-pid %s\n' "$$" >> "$FAKE_LOG"
    # exec, so the pid logged is the one waiting and a TERM to it ends the wait.
    [[ -z ${FAKE_PROMPT_SLEEP-} ]] || exec sleep "$FAKE_PROMPT_SLEEP" >/dev/null 2>&1
    exit "${FAKE_PROMPT_RC:-0}" ;;
  "agent get")
    sleep "${FAKE_GET_SLEEP:-0}" >/dev/null 2>&1
    # The pad goes first, so an answer cut short at a cap has no status left.
    pad=$(head -c "${FAKE_AGENT_GET_BYTES:-0}" /dev/zero | tr '\0' x)
    printf '{"result":{"agent":{"pad":"%s","agent_status":"%s"}}}\n' "$pad" "${FAKE_AGENT_STATUS:-idle}" ;;
  "agent read")
    sleep "${FAKE_READ_SLEEP:-0}" >/dev/null 2>&1
    if [[ -n ${FAKE_SCREEN_BYTES-} ]]; then
      head -c "$FAKE_SCREEN_BYTES" /dev/zero | tr '\0' x
      printf '%s' "${FAKE_SCREEN_SUFFIX-}"
    else
      printf '%s' "${FAKE_SCREEN-screen}"
    fi ;;
  "agent focus")
    if [[ ${FAKE_IGNORE_TERM-} == 1 ]]; then trap '' TERM; fi
    exec sleep "${FAKE_FOCUS_SLEEP:-0}" ;;
  "session delete") exit 0 ;;
  *) exit 1 ;;
esac
FAKE

# The fake ssh records what it was asked and answers nothing, which is an
# unreachable host as far as the script can tell. With FAKE_SSH_RUN set it runs
# the remote command here instead, against the fake herdr. FAKE_SSH_PIPE as
# well hands its output to a reader that takes one byte and leaves, which is
# what sshd closing the command's stdout looks like from the other end.
cat > "$tmp/bin/ssh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" >> "$FAKE_LOG"
printf 'ssh-pid %s\n' "$$" >> "$FAKE_LOG"
[[ -n ${FAKE_SSH_RUN-} ]] || exit 0
sleep "${FAKE_SSH_SLEEP:-0}" >/dev/null 2>&1
while [[ $# -gt 0 && $1 != -- ]]; do shift; done
shift 2
[[ -z ${FAKE_SSH_PIPE-} ]] || { bash -c "$*" | head -c 1 >/dev/null; exit; }
exec bash -c "$*"
FAKE

# The fake hyprctl's windows are whatever FAKE_CLIENTS holds; every other
# call, dispatch included, does nothing.
cat > "$tmp/bin/hyprctl" <<'FAKE'
#!/bin/sh
if [ "$1" = clients ]; then
  sleep "${FAKE_CLIENTS_SLEEP:-0}"
  cat "$FAKE_CLIENTS"
elif [ "$1" = dispatch ]; then
  exit "${FAKE_DISPATCH_RC:-0}"
else echo "[]"; fi
FAKE
cat > "$tmp/bin/ss" <<'FAKE'
#!/bin/bash
printf '%s\n' "${FAKE_SS_LINES-}"
FAKE
cat > "$tmp/bin/kill" <<'FAKE'
#!/bin/bash
signal=$1 pid=$2
if [[ $signal == -0 ]]; then
  [[ ! -f $FAKE_PROC_DIR/$pid/dead ]]
  exit
fi
printf '%s %s\n' "$signal" "$pid" >> "$FAKE_KILL_LOG"
if [[ $signal == -KILL || ${FAKE_TERM_STICKS-} != 1 ]]; then
  : > "$FAKE_PROC_DIR/$pid/dead"
elif [[ -n ${FAKE_CHANGE_START_ON_TERM-} ]]; then
  printf '%s\n' "$FAKE_CHANGE_START_ON_TERM" > "$FAKE_PROC_DIR/$pid/stat"
fi
FAKE
cat > "$tmp/disable-kill" <<'FAKE'
enable -n kill
FAKE
cat > "$tmp/bin/setsid" <<'FAKE'
#!/bin/bash
exec "$@"
FAKE
cat > "$tmp/bin/uwsm-app" <<'FAKE'
#!/bin/bash
[[ ${1-} == -- ]] && shift
exec "$@"
FAKE
cat > "$tmp/bin/foot" <<'FAKE'
#!/bin/bash
printf 'foot-launched\n' >> "$FAKE_LOG"
exit "${FAKE_FOOT_RC:-0}"
FAKE
chmod +x "$tmp/bin/herdr" "$tmp/bin/ssh" "$tmp/bin/hyprctl" "$tmp/bin/ss" "$tmp/bin/kill" \
  "$tmp/bin/setsid" "$tmp/bin/uwsm-app" "$tmp/bin/foot"

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
  : > "$FAKE_KILL_LOG"
  echo "[]" > "$FAKE_CLIENTS"
  export FAKE_SESSIONS='[{"name":"s1","default":false,"running":true,"session_dir":"/nonexistent"}]'
  unset FAKE_SNAPSHOT_BYTES FAKE_SNAPSHOT_SLEEP FAKE_PROMPT_RC FAKE_AGENT_STATUS \
    FAKE_AGENT_GET_BYTES FAKE_SCREEN FAKE_SSH_RUN FAKE_SSH_PIPE FAKE_PROMPT_SLEEP \
    FAKE_AGENTS FAKE_TABS FAKE_FOCUS_SLEEP FAKE_GET_SLEEP FAKE_READ_SLEEP \
    FAKE_LIST_SLEEP FAKE_IGNORE_TERM FAKE_SSH_SLEEP FAKE_CLIENTS_SLEEP \
    FAKE_SCREEN_BYTES FAKE_SCREEN_SUFFIX HERDR_TEST_NEW_DEADLINE \
    FAKE_SS_LINES FAKE_TERM_STICKS FAKE_CHANGE_START_ON_TERM FAKE_FOOT_RC FAKE_DISPATCH_RC
  local var
  for var in ${!FAKE_SNAPSHOT_BODY_@} ${!FAKE_SNAPSHOT_SLEEP_@}; do unset "$var"; done
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

fake_stat() {
  local pid=$1 start=$2 comm=${3:-herdr} i
  printf '%s (%s) S' "$pid" "$comm"
  for ((i = 0; i < 18; i++)); do printf ' 0'; done
  printf ' %s\n' "$start"
}

fake_server() {
  local pid=$1 start=$2
  mkdir -p "$FAKE_PROC_DIR/$pid"
  rm -f -- "$FAKE_PROC_DIR/$pid/dead"
  printf 'herdr\n' > "$FAKE_PROC_DIR/$pid/comm"
  printf 'herdr\0server\0' > "$FAKE_PROC_DIR/$pid/cmdline"
  fake_stat "$pid" "$start" > "$FAKE_PROC_DIR/$pid/stat"
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
# shellcheck disable=SC2317,SC2329 # called through check; older shellcheck says SC2317
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
# shellcheck disable=SC2016 # $two and $one are jq variables
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
# shellcheck disable=SC2317,SC2329 # called through check; older shellcheck says SC2317
cache_left_alone() {
  [[ -d $cache/keep && $(stat -c %a "$cache/keep.txt") == 644 ]]
}
check "9 demo leaves the cache alone" cache_left_alone ||
  printf '  got: %.200s\n  left: %s\n' "$out" "$(ls -l "$cache")"
"$script" demo off >/dev/null

# Case 10: a remote prompt whose connection is gone stops on the remote host
# too, rather than waiting on the agent there for minutes.
reset
printf hi | FAKE_SSH_RUN=1 FAKE_SSH_PIPE=1 FAKE_PROMPT_SLEEP=60 \
  "$script" --host h1 prompt s1 w1:p1 >/dev/null 2>&1 &
bg+=($!)
pid=""
for ((i = 0; i < 50; i++)); do
  [[ -n $pid ]] || pid=$(awk '$1 == "prompt-pid" { print $2 }' "$FAKE_LOG")
  [[ -n $pid ]] && ! kill -0 "$pid" 2>/dev/null && break
  sleep 0.1
done
# shellcheck disable=SC2317,SC2329 # called through check; older shellcheck says SC2317
prompt_gone() {
  [[ -n $pid ]] && ! kill -0 "$pid" 2>/dev/null
}
check "10 cancelled remote prompt" prompt_gone ||
  printf '  prompt pid %s still running after 5s\n' "${pid:-(never started)}"
# A failing run's prompt is ended here, or it would outlive the suite.
[[ -z $pid ]] || kill "$pid" 2>/dev/null
stop_bg

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

# Case 12: each agent names the tab it sits in. A tab nobody named carries its
# number as its label, and an agent with no tab has none; both come out empty.
reset
out=$(FAKE_TABS='[{"tab_id":"w1:t1","label":"review","number":1},
                   {"tab_id":"w1:t2","label":"2","number":2}]' \
  FAKE_AGENTS='[{"agent_status":"idle","pane_id":"w1:p1","tab_id":"w1:t1","terminal_title":"a1"},
                {"agent_status":"idle","pane_id":"w1:p2","tab_id":"w1:t2","terminal_title":"a2"},
                {"agent_status":"idle","pane_id":"w1:p3","terminal_title":"a3"}]' \
  "$script" list)
check "12 tab names" jq -e '[.sessions[0].agentList[] | .tab] == ["review", "", ""]' <<<"$out" ||
  printf '  got: %s\n' "$(jq -c '[.sessions[0].agentList[]? | .tab]' <<<"$out")"

# Case 13: herdr titles a tab itself as "<number> · <what runs in it>", which
# nobody named either, so it comes out empty too. A real name still shows.
reset
out=$(FAKE_TABS='[{"tab_id":"w1:t1","label":"1 · claude › Code review","number":1},
                   {"tab_id":"w1:t2","label":"12 · x","number":12},
                   {"tab_id":"w1:t3","label":"release","number":3}]' \
  FAKE_AGENTS='[{"agent_status":"idle","pane_id":"w1:p1","tab_id":"w1:t1","terminal_title":"a1"},
                {"agent_status":"idle","pane_id":"w1:p2","tab_id":"w1:t2","terminal_title":"a2"},
                {"agent_status":"idle","pane_id":"w1:p3","tab_id":"w1:t3","terminal_title":"a3"}]' \
  "$script" list)
check "13 auto-titled tabs" jq -e '[.sessions[0].agentList[] | .tab] == ["", "", "release"]' <<<"$out" ||
  printf '  got: %s\n' "$(jq -c '[.sessions[0].agentList[]? | .tab]' <<<"$out")"

# Step 1: each action deadline has its own error, including timeout's 137
# path when a child ignores TERM.
reset
start=$SECONDS
out=$(FAKE_FOCUS_SLEEP=30 "$script" focus s1 w1:p1)
took=$((SECONDS - start))
# shellcheck disable=SC2016 # $took is a jq variable
check "14 focus deadline" jq -e --argjson took "$took" \
  '.error == "timed out: focus" and $took < 6' <<<"$out" ||
  printf '  took %ss, got: %.200s\n' "$took" "$out"

reset
start=$SECONDS
out=$(FAKE_FOCUS_SLEEP=30 FAKE_IGNORE_TERM=1 "$script" focus s1 w1:p1)
took=$((SECONDS - start))
# shellcheck disable=SC2016 # $took is a jq variable
check "15 focus KILL deadline" jq -e --argjson took "$took" \
  '.error == "timed out: focus" and $took < 7' <<<"$out" ||
  printf '  took %ss, got: %.200s\n' "$took" "$out"

reset
out=$(printf hi | FAKE_GET_SLEEP=30 "$script" prompt s1 w1:p1)
check "16 get deadline" jq -e '.error == "timed out: reading the reply"' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
out=$(printf hi | FAKE_READ_SLEEP=30 "$script" prompt s1 w1:p1)
check "17 read deadline" jq -e '.error == "timed out: reading the reply"' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
out=$(printf hi | FAKE_PROMPT_RC=124 "$script" prompt s1 w1:p1)
check "18 prompt wait timeout" jq -e '.ok == true and .status == "timeout"' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
out=$(FAKE_SSH_RUN=1 FAKE_SSH_SLEEP=30 "$script" --host razer delete s1)
check "19 remote action deadline" jq -e '.error == "timed out: delete on razer"' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
out=$("$script" open s1)
check "20 no window launches" jq -e '.ok == true' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
start=$SECONDS
out=$(FAKE_CLIENTS_SLEEP=30 "$script" open s1)
took=$((SECONDS - start))
# shellcheck disable=SC2016 # $took is a jq variable
check "21 slow window lookup launches" jq -e --argjson took "$took" \
  '.ok == true and $took < 5' <<<"$out" ||
  printf '  took %ss, got: %.200s\n' "$took" "$out"

reset
out=$(printf hi | FAKE_SCREEN_BYTES=200000 "$script" prompt s1 w1:p1)
check "22 long screen intact" jq -e '.ok == true and (.output | length) == 200000' <<<"$out" ||
  printf '  output length: %s\n' "$(jq -r '.output | length' <<<"$out")"

reset
out=$(printf hi | FAKE_SCREEN_BYTES=$((2 * 1024 * 1024 - 1)) FAKE_SCREEN_SUFFIX=é \
  "$script" prompt s1 w1:p1)
check "23 split UTF-8 screen" jq -e '.ok == true and (.output | endswith("\ufffd"))' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
start=$SECONDS
out=$(FAKE_SSH_RUN=1 HERDR_TEST_NEW_DEADLINE=3 "$script" --host razer new fresh /tmp)
took=$((SECONDS - start))
# shellcheck disable=SC2016 # $took is a jq variable
check "24 remote new deadline" jq -e --argjson took "$took" \
  '.error == "session started, but razer never reported it running" and $took < 12' <<<"$out" ||
  printf '  took %ss, got: %.200s\n' "$took" "$out"

reset
out=$(FAKE_LIST_SLEEP=30 "$script" new fresh)
check "25 name check deadline" jq -e '.error == "timed out: checking the name"' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
out=$(FAKE_LIST_SLEEP=30 "$script" kill s1)
check "26 socket lookup deadline" jq -e '.error == "timed out: finding the server"' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
out=$(FAKE_LIST_SLEEP=30 "$script" delete s1)
check "27 delete unaffected by list" jq -e '.ok == true' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

# Step 2: snapshot projection is isolated per session, and listing is bounded.
# shellcheck disable=SC2089 # literal JSON is passed through the environment
three='[{"name":"a","running":true},{"name":"b","running":true},{"name":"c","running":true}]'
for field in agents workspaces tabs; do
  reset
  export FAKE_SESSIONS=$three
  case $field in
    agents) export FAKE_SNAPSHOT_BODY_b='{"result":{"snapshot":{"agents":"bad","workspaces":[],"tabs":[]}}}' ;;
    workspaces) export FAKE_SNAPSHOT_BODY_b='{"result":{"snapshot":{"agents":[],"workspaces":"bad","tabs":[]}}}' ;;
    tabs) export FAKE_SNAPSHOT_BODY_b='{"result":{"snapshot":{"agents":[],"workspaces":[],"tabs":7}}}' ;;
  esac
  out=$("$script" list)
  check "28 malformed $field isolated" jq -e \
    '[.sessions[] | .readable] == [true,false,true]
     and [.sessions[] | .agents] == [1,0,1]' <<<"$out" ||
    printf '  got: %.200s\n' "$out"
done

reset
export FAKE_SNAPSHOT_BODY_s1='{"result":{"snapshot":{"agents":[{"terminal_title":7,"state_change_seq":"12","pane_id":"w1:p1"}],"workspaces":[],"tabs":[]}}}'
out=$("$script" list)
check "29 coerced title and sequence" jq -e \
  '.sessions[0].agentList[0] | .title == "7" and .seq == 12' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
export FAKE_SESSIONS=$three FAKE_SNAPSHOT_SLEEP_a=1.5 \
  FAKE_SNAPSHOT_SLEEP_b=1.5 FAKE_SNAPSHOT_SLEEP_c=1.5
start=$(date +%s%N)
out=$("$script" list)
took=$(( ($(date +%s%N) - start) / 1000000 ))
# shellcheck disable=SC2016 # $took is a jq variable
check "30 snapshots run together" jq -e --argjson took "$took" \
  '.sessions | length == 3' <<<"$out" &&
  check "30 snapshots under 3 seconds" test "$took" -lt 3000 ||
  printf '  took %sms, got: %.200s\n' "$took" "$out"

reset
FAKE_SESSIONS=$(jq -nc '[range(12) | {name: ("s" + tostring), running: true}]')
export FAKE_SNAPSHOT_SLEEP=30
start=$(date +%s%N)
out=$("$script" list)
took=$(( ($(date +%s%N) - start) / 1000000 ))
check "31 twelve wedged bounded" jq -e \
  '(.sessions | length) == 12 and ([.sessions[] | select(.readable == false)] | length) >= 8' <<<"$out" &&
  check "31 twelve wedged under 8 seconds" test "$took" -lt 8000 ||
  printf '  took %sms, got: %.200s\n' "$took" "$out"

reset
export FAKE_SESSIONS=$three
export FAKE_SNAPSHOT_BODY_a='bad' FAKE_SNAPSHOT_BODY_b='bad' FAKE_SNAPSHOT_BODY_c='bad'
out=$("$script" list)
check "32 all snapshots fail" jq -e \
  '.ok == true and [.sessions[] | .readable] == [false,false,false]' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
export FAKE_SESSIONS='[]'
out=$("$script" list)
check "33 no running sessions" jq -e '.ok == true and .sessions == []' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
export FAKE_SNAPSHOT_BODY_s1='{"result":{"snapshot":{"agents":[{"agent_status":"idle","pane_id":"w1:p1"}],"workspaces":[],"tabs":[]}}}'
out=$("$script" list)
check "34 untitled agent" jq -e \
  '.sessions[0].agentList[0].title == "untitled agent"' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
export FAKE_AGENTS
FAKE_AGENTS=$(jq -nc '[range(501) | {agent_status:"blocked", pane_id:"w1:p1", terminal_title:"agent"}]')
out=$("$script" list)
check "35 counts follow shown agents" jq -e \
  '.sessions[0] | .agents == 500 and .blocked == 500
   and .hiddenAgents == 1 and (.agentList | length) == 500' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
FAKE_SESSIONS=$(jq -nc '[range(1;202) | {name: ("s" + (tostring | ("000" + .)[-3:])), running:true}]')
out=$("$script" list)
check "36 session display cap" jq -e \
  '.sessions | length == 200' <<<"$out" &&
  check "36 hidden session count" jq -e '.hidden == 1' <<<"$out" ||
  printf '  got: %.200s\n' "$out"
out=$("$script" new s201)
check "36 hidden name still exists" jq -e \
  '.error == "a session called s201 already exists"' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
out=$(FAKE_SNAPSHOT_BYTES=$((2 * 1024 * 1024)) "$script" list)
check "37 oversized snapshot unreadable" jq -e \
  '.sessions[0].readable == false' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
"$script" demo on >/dev/null
out=$("$script" --host razer list)
"$script" demo off >/dev/null
check "38 demo remote list" jq -e \
  '.ok == true and .sessions == []' <<<"$out" ||
  printf '  got: %.200s\n' "$out"

reset
out=$("$script" list)
check "39 no run directory left" test -z "$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'nixarchy-herdr.*' -print)" ||
  printf '  got: %.200s\n' "$out"

reset
export FAKE_SESSIONS=$three FAKE_SNAPSHOT_SLEEP_a=30 \
  FAKE_SNAPSHOT_SLEEP_b=30 FAKE_SNAPSHOT_SLEEP_c=30
"$script" list >/dev/null 2>&1 &
pid=$!
for ((i = 0; i < 50; i++)); do
  [[ -n $(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'nixarchy-herdr.*' -print) ]] &&
    grep -q '^snapshot-pid ' "$FAKE_LOG" && break
  sleep 0.05
done
kill -TERM "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
check "40 TERM removes run directory" test -z \
  "$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'nixarchy-herdr.*' -print)"
for ((i = 0; i < 30; i++)); do
  surviving=$(awk '$1 == "snapshot-pid" { print $3 }' "$FAKE_LOG" |
    while read -r child; do kill -0 "$child" 2>/dev/null && printf '%s\n' "$child"; done)
  [[ -n $surviving ]] || break
  sleep 0.1
done
check "40 TERM leaves no snapshot child" test -z "$surviving"

# Step 3: socket ownership and process identity are checked before signalling.
reset
export FAKE_SESSIONS='[{"name":"s1","running":true,"socket_path":"/path"}]'
export FAKE_SS_LINES='u_str LISTEN 0 4096 /path 123 * 0 users:(("x",pid=100,fd=3),("herdr",pid=101,fd=4))'
mkdir -p "$FAKE_PROC_DIR/100"
printf 'x\n' > "$FAKE_PROC_DIR/100/comm"
fake_server 101 100
out=$(BASH_ENV="$tmp/disable-kill" HERDR_TEST_PROC="$FAKE_PROC_DIR" "$script" kill s1)
check "41 two owners signal herdr" jq -e '.ok == true' <<<"$out" &&
  check "41 only server signalled" test "$(cat "$FAKE_KILL_LOG")" = '-TERM 101' ||
  printf '  got: %.200s, signals: %s\n' "$out" "$(cat "$FAKE_KILL_LOG")"

reset
export FAKE_SESSIONS='[{"name":"s1","running":true,"socket_path":"/path"}]'
export FAKE_SS_LINES='u_str LISTEN 0 4096 /path-other 123 * 0 users:(("herdr",pid=101,fd=4))'
fake_server 101 100
out=$(BASH_ENV="$tmp/disable-kill" HERDR_TEST_PROC="$FAKE_PROC_DIR" "$script" kill s1)
check "42 socket prefix is not a match" jq -e \
  '.error == "no running server for that session"' <<<"$out" &&
  check "42 prefix never signalled" test ! -s "$FAKE_KILL_LOG" ||
  printf '  got: %.200s, signals: %s\n' "$out" "$(cat "$FAKE_KILL_LOG")"

reset
export FAKE_SESSIONS='[{"name":"s1","running":true,"socket_path":"/path"}]'
export FAKE_SS_LINES='u_str LISTEN 0 4096 /path 123 * 0 users:(("herdr",pid=101,fd=4))'
fake_server 101 100
mv "$FAKE_PROC_DIR/101/stat" "$FAKE_PROC_DIR/101/stat-old"
mkfifo "$FAKE_PROC_DIR/101/stat"
(fake_stat 101 100 > "$FAKE_PROC_DIR/101/stat";
 sleep 0.2;
 fake_stat 101 200 > "$FAKE_PROC_DIR/101/stat") &
writer=$!
out=$(timeout 5 env BASH_ENV="$tmp/disable-kill" HERDR_TEST_PROC="$FAKE_PROC_DIR" "$script" kill s1)
kill "$writer" 2>/dev/null || true
wait "$writer" 2>/dev/null || true
unlink "$FAKE_PROC_DIR/101/stat"
mv "$FAKE_PROC_DIR/101/stat-old" "$FAKE_PROC_DIR/101/stat"
check "43 PID changed before TERM" jq -e '.ok == true' <<<"$out" &&
  check "43 changed PID not signalled" test ! -s "$FAKE_KILL_LOG" ||
  printf '  got: %.200s, signals: %s\n' "$out" "$(cat "$FAKE_KILL_LOG")"

reset
export FAKE_SESSIONS='[{"name":"s1","running":true,"socket_path":"/path"}]'
export FAKE_SS_LINES='u_str LISTEN 0 4096 /path 123 * 0 users:(("herdr",pid=101,fd=4))'
fake_server 101 100
export FAKE_TERM_STICKS=1
FAKE_CHANGE_START_ON_TERM=$(fake_stat 101 200)
export FAKE_CHANGE_START_ON_TERM
out=$(BASH_ENV="$tmp/disable-kill" HERDR_TEST_PROC="$FAKE_PROC_DIR" "$script" kill s1)
check "44 PID changed before KILL" jq -e '.ok == true' <<<"$out" &&
  check "44 no KILL after PID change" test "$(cat "$FAKE_KILL_LOG")" = '-TERM 101' ||
  printf '  got: %.200s, signals: %s\n' "$out" "$(cat "$FAKE_KILL_LOG")"

reset
export FAKE_SESSIONS='[{"name":"s1","running":true,"socket_path":"/path"}]'
export FAKE_SS_LINES='u_str LISTEN 0 4096 /path 123 * 0 users:(("herdr",pid=101,fd=4))'
fake_server 101 100
fake_stat 101 100 'x) y' > "$FAKE_PROC_DIR/101/stat"
out=$(BASH_ENV="$tmp/disable-kill" HERDR_TEST_PROC="$FAKE_PROC_DIR" "$script" kill s1)
check "45 stat comm has close parenthesis" jq -e '.ok == true' <<<"$out" &&
  check "45 odd comm server signalled" test "$(cat "$FAKE_KILL_LOG")" = '-TERM 101' ||
  printf '  got: %.200s, signals: %s\n' "$out" "$(cat "$FAKE_KILL_LOG")"

reset
export FAKE_SESSIONS='[{"name":"s1","running":true,"socket_path":"/path"}]'
export FAKE_SS_LINES='u_str LISTEN 0 4096 /path 123 * 0 users:(("herdr",pid=101,fd=4))'
fake_server 101 100
export FAKE_TERM_STICKS=1
out=$(BASH_ENV="$tmp/disable-kill" HERDR_TEST_PROC="$FAKE_PROC_DIR" "$script" kill s1)
check "45b wedged server needs KILL" jq -e '.ok == true' <<<"$out" &&
  check "45b signals original server twice" test \
    "$(cat "$FAKE_KILL_LOG")" = $'-TERM 101\n-KILL 101' ||
  printf '  got: %.200s, signals: %s\n' "$out" "$(cat "$FAKE_KILL_LOG")"

# Command-line verbs are not window clients; attach and named flags are.
reset
fake_client herdr agent prompt w1:p1 x
fake_windows "${bg[-1]}" 1
out=$("$script" list)
stop_bg
check "46 prompt is not a window" jq -e '.sessions[0].windowAddress == ""' <<<"$out"

reset
fake_client herdr session list
fake_windows "${bg[-1]}" 1
out=$("$script" list)
stop_bg
check "47 list is not a window" jq -e '.sessions[0].windowAddress == ""' <<<"$out"

reset
export FAKE_SESSIONS='[{"name":"foo","running":true}]'
fake_client herdr --session=foo
fake_windows "${bg[-1]}" 1
out=$("$script" list)
stop_bg
check "48 named flag is a window" jq -e '.sessions[0].windowAddress == "0x10"' <<<"$out"

reset
export FAKE_SESSIONS='[{"name":"foo","running":true}]'
fake_client herdr session attach foo
fake_windows "${bg[-1]}" 1
out=$("$script" list)
stop_bg
check "49 attach is a window" jq -e '.sessions[0].windowAddress == "0x10"' <<<"$out"

reset
out=$(FAKE_FOOT_RC=1 "$script" open s1)
check "50 launcher failure" jq -e '.error == "the terminal exited at once"' <<<"$out"

reset
out=$(FAKE_DISPATCH_RC=1 "$script" open 4)
check "51 dispatch failure" jq -e '.error == "could not focus the window"' <<<"$out"

reset
FAKE_SSH_RUN=1 FAKE_SSH_SLEEP=30 "$script" --host razer list >/dev/null 2>&1 &
pid=$!
ssh_pid=""
for ((i = 0; i < 50; i++)); do
  ssh_pid=$(awk '$1 == "ssh-pid" { print $2; exit }' "$FAKE_LOG")
  [[ -n $ssh_pid ]] && break
  sleep 0.05
done
kill -TERM "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
check "52 remote list run directory removed" test -z \
  "$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'nixarchy-herdr.*' -print)"
check "52 remote ssh child stopped" test -n "$ssh_pid" &&
  check "52 remote ssh child gone" test ! -e "/proc/$ssh_pid" ||
  printf '  ssh pid %s still exists\n' "${ssh_pid:-none}"

exit "$failed"
