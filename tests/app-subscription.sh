#!/usr/bin/env bash
# Runs tests/app-subscription.qml headless with a fake hc. Never starts the real hc.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
# The fake's sleep carries this run's pid, so cleanup touches nothing else.
trap 'pkill -f "[s]leep 31\.$$" 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/shell/bin" "$tmp/bin"
cp "$here/qmldir" "$here/HerdrActions.qml" "$here/HerdrModel.qml" "$here/tests/app-subscription.qml" "$tmp/shell/"
# A qmldir hides unlisted types from a root file in its directory; the plugin never loads HerdrModel that way.
echo "HerdrModel 1.0 HerdrModel.qml" >> "$tmp/shell/qmldir"
cp -r "$here/tests/app-subscription-stubs/Commons" "$tmp/shell/Commons"

# The script the model calls: counts app-list runs, answers with valid JSON.
cat > "$tmp/shell/bin/herdr-sessions" <<'STUB'
#!/usr/bin/env bash
# The model also polls `list`; only app-list is counted.
[[ ${1-} != app-list ]] && { printf '{"ok":true,"error":"","sessions":[]}\n'; exit 0; }
echo run >> "$TEST_DIR/app-list-runs"
if [[ $(wc -l < "$TEST_DIR/hc-starts") -ge 2 && $(wc -l < "$TEST_DIR/app-list-runs") -le 4 ]]; then
  echo fail >> "$TEST_DIR/app-list-failed"
  printf '{"ok":false,"error":"one failed read"}\n'
  exit 1
fi
printf '{"ok":true,"error":"","sessions":[{"kind":"app","name":"s","host":"","spaceId":"sp","running":true,"readable":true,"agents":0,"agentList":[]}],"windowOpen":false,"machines":[]}\n'
STUB

# Start 1: snapshot, a burst of five events, then silence. Start 2: snapshot,
# then heartbeats only and a normal exit. Start 3: snapshot, then silence.
cat > "$tmp/bin/hc" <<'FAKE'
#!/usr/bin/env bash
echo start >> "$TEST_DIR/hc-starts"
n=$(wc -l < "$TEST_DIR/hc-starts")
echo '{"seq":1,"terminals":[]}'
case $n in
  1) for _ in 1 2 3 4 5; do echo '{"event":"changed"}'; done ;;
  2) for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 0.2; echo '{"event":"heartbeat"}'; done
     echo '{"event":"changed"}'; sleep 0.5; exit 0 ;;
esac
trap 'kill "$!"' TERM
sleep "31.$RUN_MARK" &
wait
FAKE
chmod +x "$tmp/shell/bin/herdr-sessions" "$tmp/bin/hc"

RUN_MARK=$$ TEST_DIR=$tmp QT_QPA_PLATFORM=offscreen PATH="$tmp/bin:$PATH" \
  timeout 20 qs -p "$tmp/shell/app-subscription.qml"
