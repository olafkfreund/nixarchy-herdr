#!/usr/bin/env bash
# Runs tests/text-scale.qml headless with a fake hc and a temp cache dir.
# Never starts the real hc, and never touches the real size file.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'pkill -f "[s]leep 32\.$$" 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/shell/bin" "$tmp/bin"
cp "$here/qmldir" "$here/HerdrActions.qml" "$here/HerdrModel.qml" "$here/tests/text-scale.qml" "$tmp/shell/"
# A qmldir hides unlisted types from a root file in its directory; the plugin never loads HerdrModel that way.
echo "HerdrModel 1.0 HerdrModel.qml" >> "$tmp/shell/qmldir"
cp -r "$here/tests/app-subscription-stubs/Commons" "$tmp/shell/Commons"

cat > "$tmp/shell/bin/herdr-sessions" <<'STUB'
#!/usr/bin/env bash
printf '{"ok":true,"error":"","sessions":[],"windowOpen":false,"machines":[]}\n'
STUB
cat > "$tmp/bin/hc" <<'FAKE'
#!/usr/bin/env bash
echo '{"seq":1,"terminals":[]}'
trap 'kill "$!"' TERM
sleep "32.$RUN_MARK" &
wait
FAKE
chmod +x "$tmp/shell/bin/herdr-sessions" "$tmp/bin/hc"

# Case 1: the cache path is a regular file, so the directory cannot be made
# and a write fails. Case 2: the directory exists at start (FileView makes the
# directory on a write, but only watches a file whose directory already exists).
touch "$tmp/blocked"
RUN_MARK=$$ CASE=nodir TEST_DIR=$tmp XDG_CACHE_HOME=$tmp/blocked QT_QPA_PLATFORM=offscreen PATH="$tmp/bin:$PATH" \
  timeout 20 qs -p "$tmp/shell/text-scale.qml"
[[ -f $tmp/blocked ]] || { echo "FAIL: the blocked path was replaced" >&2; exit 1; }
mkdir -p "$tmp/cache/omarchy-herdr"
RUN_MARK=$$ CASE=dir TEST_DIR=$tmp XDG_CACHE_HOME=$tmp/cache QT_QPA_PLATFORM=offscreen PATH="$tmp/bin:$PATH" \
  timeout 20 qs -p "$tmp/shell/text-scale.qml"
