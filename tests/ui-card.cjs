// Run with: node tests/ui-card.cjs
// Card.qml: key routing, destroy key, scroll arithmetic, and source checks.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync(`${__dirname}/../Card.qml`, 'utf8');
const calls = [];
const rec = (name) => (...a) => calls.push([name, ...a]);
const panel = {
  cursor: 0, pinnable: true, session: { kind: 'classic', running: true },
  sessionAt() { return this.session; },
  openSession: rec('open'), askKill: rec('kill'), askDelete: rec('delete'), close: rec('close'),
  togglePin: rec('pin'), refresh: rec('refresh'), requestNew: rec('new'), requestPrompt: rec('prompt'),
  requestInterrupt: rec('interrupt'), textBigger: rec('bigger'), textSmaller: rec('smaller'),
  textReset: rec('reset'),
};
const ctx = {
  card: null, deleteRequested() { ctx.destroyCursor(); }, panel, Qt: { AltModifier: 0x08000000, MetaModifier: 0x10000000, ShiftModifier: 0x02000000,
    resolvedUrl: (p) => ({ toString: () => `file:///x/${p}` }) },
  Quickshell: { execDetached: rec('exec') },
};
ctx.card = ctx;
vm.createContext(ctx);
vm.runInContext('function destroyCursor() ' + source.match(/onDeleteRequested: (\{[^]*?\n  \})/)[1], ctx);
for (const name of ['scrollTarget', 'openKeys', 'handleTextKey']) {
  const m = source.match(new RegExp('  function ' + name + '\\([^]*?\\n  \\}'));
  assert.ok(m, `Missing function: ${name}`);
  vm.runInContext(m[0], ctx);
}
const key = (t, mods = 0) => { calls.length = 0; ctx.handleTextKey(t, mods); return calls.map((c) => c[0]).join(','); };

// key routing
for (const [t, want] of [['+', 'bigger'], ['=', 'bigger'], ['-', 'smaller'], ['0', 'reset'],
                         ['o', 'open'], ['p', 'pin'], ['r', 'refresh'], ['n', 'new'], ['a', 'prompt'],
                         ['i', 'interrupt'], ['K', 'kill']]) {
  assert.equal(key(t), want, t);
  assert.equal(key(t, ctx.Qt.ShiftModifier), want, `shift ${t}`);
  assert.equal(key(t, ctx.Qt.AltModifier), '', `alt ${t}`);
  assert.equal(key(t, ctx.Qt.MetaModifier), '', `meta ${t}`);
}
assert.equal(key('?'), 'close,exec');
assert.equal(calls[1][1][0], '/x/bin/herdr-menu-keys');
assert.deepEqual(calls.find((c) => c[0] === 'pin') || [], []);
key('p'); assert.deepEqual(calls[0], ['pin', true]);
panel.pinnable = false; assert.equal(key('p'), ''); panel.pinnable = true;

// x / K: running, stopped, app
for (const [session, want] of [[{ kind: 'classic', running: true }, 'kill'],
                               [{ kind: 'classic', running: false }, 'delete'],
                               [{ kind: 'app', running: true }, 'kill'],
                               [{ kind: 'app', running: false }, 'kill']]) {
  panel.session = session;
  calls.length = 0; ctx.destroyCursor();
  assert.equal(calls.map((c) => c[0]).join(','), want, JSON.stringify(session));
  assert.equal(key('K'), want);
}
panel.session = null; calls.length = 0; ctx.destroyCursor(); assert.equal(calls.length, 0);

// scroll arithmetic: contentY, height, top, bottom, originY, contentHeight
const st = (...a) => ctx.scrollTarget(...a);
assert.equal(st(100, 100, 20, 40, 0, 1000), 20, 'above');
assert.equal(st(0, 100, 150, 180, 0, 1000), 80, 'below');
assert.equal(st(50, 100, 60, 90, 0, 1000), 50, 'inside');
assert.equal(st(0, 100, 200, 400, 0, 1000), 200, 'taller than the view aligns its top');
assert.equal(st(0, 100, 990, 1000, 0, 1000), 900, 'clamped at the end');
assert.equal(st(50, 100, -20, -5, 0, 1000), 0, 'clamped at the origin');
assert.equal(st(0, 100, 10, 20, 0, 50), 0, 'content shorter than the view');

// source checks
assert.ok(!/Qt\.darker\(/.test(source), 'no Qt.darker');
assert.ok(!/\b(column|columnOpen|columnRow|columnDestroy|lastColumnFor|moveColumn|cycleColumn|clampColumn|cursorInBody)\b/.test(
  source.replace(/\/\/.*$/gm, '').replace(/agentColumn/g, '')), 'no U5 symbols');
assert.ok(!/onTabRequested/.test(source));
assert.ok(!/^\s*Keys\.onPressed/m.test(source), 'no Keys.onPressed on the catcher');
assert.ok(/Accessible\.focused: panel\.cursorOnAgent\(/.test(source));
assert.ok(/Accessible\.focused: panel\.cursorOnSession\(row\.index\) && !panel\.agentAt/.test(source));
for (const n of ['Open session', 'Kill server', 'Delete session', 'Unpin']) assert.ok(source.includes(`"${n}"`), n);
assert.equal((source.match(/enabled: panel\.pinnable !== false/g) || []).length, 3);
assert.ok(/context: Qt\.WindowShortcut/.test(source));
assert.ok(/ConfirmOverlay \{/.test(source) && !/ConfirmDialog \{/.test(source));
assert.ok(/footer\.height/.test(source) && /var count = 3/.test(source));
assert.ok(/panel\.togglePin\(false\)/.test(source));
assert.ok(/n new · a ask · i stop · x end · ± size · \? keys/.test(source));
assert.ok(/o open · i stop · x end · ± size · \? keys/.test(source));
assert.ok(/No herdr sessions\. Press n to start one\./.test(source));
console.log('ui-card ok');
