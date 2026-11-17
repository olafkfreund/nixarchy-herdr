// Run with: node tests/ui-panel.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const src = fs.readFileSync(`${__dirname}/../Panel.qml`, 'utf8');

// Badge text expression, one case per U1 state.
{
  const expr = src.match(/text: (herd\.needCount[^\n]+)/)[1];
  const t = (needCount, appMark) => vm.runInNewContext(expr, { herd: { needCount, appMark } });
  assert.equal(t(1, false), '1', 'blocked or done');
  assert.equal(t(3, true), '3!');
  assert.equal(t(0, true), '!');
  assert.equal(t(0, false), '', 'working: dot');
}

// Width expression: chosen width wins, scale applies, screen room caps.
{
  const m = src.match(/readonly property real cardWidth: ([^\n]+)\n\s+(chosenWidth[^\n]+)/);
  assert.ok(m, 'Missing pin cardWidth expression');
  const expr = m[1] + ' ' + m[2];
  const w = (chosenWidth, root, roomWidth) =>
    vm.runInNewContext(expr, { Math, roomWidth, chosenWidth, root });
  const root = (scale) => ({ cardMinWidth: Math.round(210 * scale), cardWidth: Math.round(300 * scale) });
  assert.equal(w(500, root(1), 1000), 500, 'a chosen width wins');
  assert.equal(w(240, root(1.6), 1000), 240, 'a chosen width below the scaled minimum is kept');
  assert.equal(w(0, root(1.6), 1000), 480, 'text scale applies without one');
  assert.equal(w(0, root(1.6), 400), 400, 'room on screen caps at 1.6');
}
assert.match(src, /cardWidth: Math\.round\(Style\.space\(300\) \* herd\.textScale\)/);
assert.match(src, /cardMinWidth: Math\.round\(Style\.space\(210\) \* herd\.textScale\)/);

// Pin focus: togglePin(true) records the flag before pinning; onVisibleChanged consumes it.
{
  const fn = src.match(/function togglePin\(fromKey\) \{\n([\s\S]*?)\n  \}\n/)[1];
  const order = [];
  const ctx = { pinned: false, screenName: 's', pinFromKey: false,
    persistSettings() { order.push(['persist', ctx.pinFromKey]); } };
  vm.runInNewContext(`(function(fromKey){${fn}})`, ctx)(true);
  assert.deepEqual(order, [['persist', true]], 'flag set before pinning');
  ctx.pinFromKey = false; order.length = 0;
  vm.runInNewContext(`(function(fromKey){${fn}})`, ctx)(false);
  assert.equal(ctx.pinFromKey, false, 'mouse pin leaves it false');

  const body = src.match(/onVisibleChanged: \{\n([\s\S]*?)\n    \}\n\n    Timer \{\n      id: armTimer/)[1];
  const run = (fromKey) => {
    const log = [];
    const c = { focusArmed: false, placed: true, visible: true,
      root: { pinFromKey: fromKey }, pinWindow: { place() {} },
      pinCard: { forceActiveFocus() { log.push('focus'); } },
      armTimer: { restart() { log.push('arm'); } },
      Qt: { callLater(f) { f(); } } };
    vm.runInNewContext(`(function(){${body}})`, c)();
    return { log, c };
  };
  let r = run(true);
  assert.deepEqual(r.log, ['focus']); assert.equal(r.c.focusArmed, true); assert.equal(r.c.root.pinFromKey, false);
  r = run(false);
  assert.deepEqual(r.log, ['arm']); assert.equal(r.c.focusArmed, false);
}

assert.match(src, /WlrLayershell\.layer: WlrLayer\.Top/);
assert.doesNotMatch(src, /WlrLayer\.Overlay/);
assert.doesNotMatch(src, /Qt\.darker\([^)]*foreground/);
console.log('PASS: ui-panel');
