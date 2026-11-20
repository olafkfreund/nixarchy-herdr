#!/usr/bin/env bash
# Runs tests/unload.qml headless, one case per qs run, with a stub herdr-sessions
# and a fake hc. Never starts the real hc.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'pkill -f "[s]leep 33\.$$" 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/shell/bin" "$tmp/bin"
cp "$here/qmldir" "$here/HerdrActions.qml" "$here/HerdrModel.qml" "$here/tests/unload.qml" "$tmp/shell/"
# A qmldir hides unlisted types from a root file in its directory; the plugin never loads HerdrModel that way.
echo "HerdrModel 1.0 HerdrModel.qml" >> "$tmp/shell/qmldir"
cp -r "$here/tests/app-subscription-stubs/Commons" "$tmp/shell/Commons"

# Lists answer at once. An action writes started-<action>-<name>, sleeps, writes
# marker-..., then prints reply-<action>-<name> (or an ok with no note).
cat > "$tmp/shell/bin/herdr-sessions" <<'STUB'
#!/usr/bin/env bash
case ${1-} in list|app-list) printf '{"ok":true,"error":"","sessions":[],"windowOpen":false,"machines":[]}\n'; exit 0 ;; esac
tag="$1-$2"
echo x > "$TEST_DIR/started-$tag"
sleep 1
echo x > "$TEST_DIR/marker-$tag"
if [[ -f $TEST_DIR/reply-$tag ]]; then cat "$TEST_DIR/reply-$tag"
else printf '{"ok":true,"error":""}\n'; fi
STUB
cat > "$tmp/bin/hc" <<'FAKE'
#!/usr/bin/env bash
echo '{"seq":1,"terminals":[]}'
trap 'kill "$!"' TERM
sleep "33.$RUN_MARK" &
wait
FAKE
chmod +x "$tmp/shell/bin/herdr-sessions" "$tmp/bin/hc"

for c in 1 2 3 4 5 6 7; do
  dir="$tmp/case$c"
  mkdir -p "$dir"
  case $c in
    1|2|3) echo '{"ok":false,"error":"focus boom"}' > "$dir/reply-focus-s1" ;;
    4) echo '{"ok":false,"error":"kill went wrong"}' > "$dir/reply-kill-s1" ;;
    5) echo '{"ok":false,"changed":true,"cascade":[],"cascadeKey":"k2"}' > "$dir/reply-app-kill-p1" ;;
    7) echo '{"ok":false,"error":"orphan err"}' > "$dir/reply-focus-o"
       for x in x1 x2 x3; do echo "{\"ok\":true,\"note\":\"note-$x\"}" > "$dir/reply-focus-$x"; done ;;
  esac
  log="$dir/qs.log"
  RUN_MARK=$$ CASE=$c TEST_DIR=$dir QT_QPA_PLATFORM=offscreen PATH="$tmp/bin:$PATH" \
    timeout 30 qs -p "$tmp/shell/unload.qml" >"$log" 2>&1 || { cat "$log"; echo "FAIL: case $c"; exit 1; }
  cat "$log"
  # A recursion or type error the engine swallows still fails the case.
  if grep -qE 'RangeError|TypeError|ReferenceError' "$log"; then echo "FAIL: case $c logged a JS error"; exit 1; fi
done
