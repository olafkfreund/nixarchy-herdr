// Run with: node tests/ui-menu.cjs
// Menu.qml: the reply excerpt, the input label, the waiting timer, the source.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const menu = fs.readFileSync(`${__dirname}/../Menu.qml`, 'utf8');
const m = { Qt: { callLater() {} }, JSON };
m.root = { inputMode: '', promptTarget: null, promptReply: '', promptConfirmOpen: false,
           newPending: false, awaitingExit: false, newHost: '', newKind: '', localHost: 'box',
           opened: true, waitSecs: 5 };
m.newField = { text: '', forceActiveFocus() {} };
m.card = { forceActiveFocus() {} };
m.promptConfirm = { dialog: { selectedIndex: 0 }, forceActiveFocus() {} };
m.waitTimer = { running: false };
m.promptProc = { running: false, gotOut: false, gotExit: false };
m.herd = { actionError: '', script: 'hs', agentBusy: () => false, sessions: [],
  sessionAt: () => ({ name: 's', host: '' }), agentAt: () => ({ pane: 'p', title: 't' }),
  cleanTitle: (x) => x, hostAtCursor: () => '', cursor: 0 };
vm.createContext(m);
for (const name of ['replyExcerpt', 'inputLabelText', 'submitPrompt', 'promptDone', 'cancelInput',
                    'close', 'promptStartFailed', 'targetStatus']) {
  const match = menu.match(new RegExp('  function ' + name + '\\([^]*?\\n  \\}'));
  assert.ok(match, `Missing Menu function: ${name}`);
  vm.runInContext(match[0], m);
  m.root[name] = m[name];
}

// excerpt
assert.equal(m.replyExcerpt('a\n    b\n\n\n'), 'a\n    b', 'indentation kept, trailing blanks dropped');
const many = Array.from({ length: 60 }, (_, i) => `l${i}`).join('\n');
const out = m.replyExcerpt(many).split('\n');
assert.equal(out.length, 40);
assert.equal(out[0], 'l20');
const wide = Array.from({ length: 40 }, () => 'x'.repeat(199)).join('\n');   // 8039 chars
const cut = m.replyExcerpt(wide);
assert.ok(cut.length <= 4000);
assert.ok(cut.split('\n').every((l) => l === 'x'.repeat(199)), 'cut at a line start');
const one = m.replyExcerpt('short\n' + 'y'.repeat(5000));
assert.equal(one, '…' + 'y'.repeat(4000));
assert.equal(m.replyExcerpt(null), '');
console.log('PASS: the reply excerpt');

// label
assert.equal(m.inputLabelText(), 'New session on box');
Object.assign(m.root, { newKind: 'app', newHost: 'razer' });
assert.equal(m.inputLabelText(), 'New space on razer');
Object.assign(m.root, { inputMode: 'prompt', promptTarget: { host: 'razer', title: 'lead' } });
assert.equal(m.inputLabelText(), 'razer · lead');
const labelBlock = menu.match(/id: inputLabel[^]*?\n              \}/)[0];
assert.match(labelBlock, /Text\.ElideLeft/, 'leading words drop, the host at the end stays');
assert.match(labelBlock, /Math\.round\(inputBox\.width \/ 2\)/);
assert.match(menu, /Accessible\.name: inputLabel\.text/);
assert.match(menu, /"name, then optionally a folder"/);
assert.match(menu, /"message to " \+ root\.promptTarget\.title/);
console.log('PASS: the input label');

// waiting timer stops on success, failure, cancel and close
const start = () => {
  Object.assign(m.root, { inputMode: 'prompt', awaitingExit: false,
    promptTarget: { kind: '', host: '', session: 's', pane: 'p', title: 't' } });
  m.newField.text = 'go'; m.waitTimer.running = false; m.promptProc.running = false;
  m.submitPrompt(false);
  assert.equal(m.waitTimer.running, true);
  assert.equal(m.root.waitSecs, 0);
};
start(); m.promptDone('{"ok":true,"output":"hi"}', 0);
assert.equal(m.waitTimer.running, false, 'success');
start(); m.promptDone('{"ok":false,"error":"no"}', 0);
assert.equal(m.waitTimer.running, false, 'failure');
start(); m.cancelInput();
assert.equal(m.waitTimer.running, false, 'cancel');
start(); m.close();
assert.equal(m.waitTimer.running, false, 'close');
start(); m.promptProc.running = false; m.promptStartFailed();
assert.equal(m.waitTimer.running, false, 'start failure');
assert.match(menu, /"waiting " \+ root\.waitSecs \+ " s \\u00b7 Esc cancels"/);
console.log('PASS: the waiting timer stops on every exit');

// source checks
assert.match(menu, /height: Math\.min\(replyText\.implicitHeight, root\.replyBudget\)/);
// The cap must not depend on the card or the input row, which are sized around it.
{
  const budget = menu.match(/readonly property real replyBudget: ([\s\S]*?)\n\n/)[1];
  assert.doesNotMatch(budget, /card\.|newRow|replyBox|bodyHeight/, 'reply budget is independent of the card');
}
assert.match(menu, /Flickable \{\n\s+id: replyBox/);
assert.doesNotMatch(menu, /replyFrom/);
assert.doesNotMatch(menu, /Qt\.darker\([^)]*foreground/);
assert.doesNotMatch(menu, /Qt\.darker/);
assert.match(menu, /ConfirmOverlay \{/);
assert.doesNotMatch(menu, /ConfirmDialog/);
assert.match(menu, /WlrLayershell\.layer: WlrLayer\.Overlay/);
assert.doesNotMatch(menu, /readonly property real textScale/);
assert.match(menu, /Style\.space\(760\) \* herd\.textScale/);
for (const seq of ['"Ctrl+="', '"Ctrl++"', '"Ctrl+Shift+="', '"Ctrl+-"', '"Ctrl+0"'])
  assert.ok(menu.includes(seq), seq);
assert.equal((menu.match(/context: Qt\.WindowShortcut/g) || []).length, 3);
assert.match(menu, /herd\.textBigger\(\)[^]*herd\.textSmaller\(\)[^]*herd\.textReset\(\)/);
console.log('PASS: the menu source');
