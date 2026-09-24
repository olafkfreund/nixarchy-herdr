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
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/run"
chmod 700 "$tmp/run"

export HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" XDG_CACHE_HOME="$tmp/home/.cache"
export PATH="$tmp/bin:$PATH"
export FAKE_LOG="$tmp/log"
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
    printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "${FAKE_AGENT_STATUS:-idle}" ;;
  "agent read") printf 'screen\n' ;;
  *) exit 1 ;;
esac
FAKE

# The fake ssh records what it was asked and answers nothing, which is an
# unreachable host as far as the script can tell.
cat > "$tmp/bin/ssh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" >> "$FAKE_LOG"
FAKE

printf '#!/bin/sh\necho "[]"\n' > "$tmp/bin/hyprctl"
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
  unset FAKE_SNAPSHOT_BYTES FAKE_SNAPSHOT_SLEEP FAKE_PROMPT_RC FAKE_AGENT_STATUS
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

exit "$failed"
