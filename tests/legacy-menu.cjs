// Run with: node tests/legacy-menu.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

// Menu.qml: its input line, with stubs for the model, the field and the process.
{
  const menu = fs.readFileSync(`${__dirname}/../Menu.qml`, 'utf8');
  const m = { Qt: { callLater() {} }, JSON };
  m.root = { inputMode: '', promptTarget: null, promptReply: '', promptConfirmOpen: false,
             newPending: false, awaitingExit: false, newHost: '', opened: true };
  m.newField = { text: '', forceActiveFocus() {} };
  m.card = { forceActiveFocus() {} };
  m.promptConfirm = { dialog: { selectedIndex: 0 }, forceActiveFocus() {} };
  m.waitTimer = { running: false };
  m.promptProc = { running: false };
  m.herd = { actionError: '', script: 'herdr-sessions', started: [],
    newSession(host, name) { this.started.push(name); return this.ok; }, ok: true,
    agentBusy: () => false, targetStatus: () => 'idle', sessions: [],
    sessionAt: () => ({ name: 's', host: '' }), agentAt: () => ({ pane: 'w1:p1', title: 't' }),
    cleanTitle: (x) => x, hostAtCursor: () => '', cursor: 0 };
  vm.createContext(m);
  for (const name of ['beginInput', 'cancelInput', 'submitInput', 'submitNew', 'actionDone',
                      'targetStatus', 'submitPrompt', 'storePrompt', 'promptDone', 'replyExcerpt', 'close',
                      'promptStartFailed']) {
    const match = menu.match(new RegExp('  function ' + name + '\\([^]*?\\n  \\}'));
    assert.ok(match, `Missing Menu function: ${name}`);
    vm.runInContext(match[0], m);
    m.root[name] = m[name];
  }
  const reset = () => {
    Object.assign(m.root, { inputMode: '', promptTarget: null, promptReply: '', promptConfirmOpen: false,
      newPending: false, awaitingExit: false, opened: true });
    m.waitTimer.running = false;
    Object.assign(m.promptProc, { running: false, gotOut: false, gotExit: false });
    m.newField.text = ''; m.herd.actionError = ''; m.herd.ok = true; m.herd.started = [];
  };

  // new: stays open and keeps its text on failure, closes on success
  reset();
  m.beginInput('new'); m.newField.text = 'dup';
  m.submitNew();
  assert.equal(m.root.newPending, true);
  m.actionDone('kill', true);
  assert.equal(m.root.newPending, true, 'a kill completion changes nothing');
  assert.equal(m.root.opened, true);
  m.actionDone('new', false);
  assert.equal(m.root.newPending, false);
  assert.equal(m.newField.text, 'dup');
  assert.equal(m.root.inputMode, 'new');
  m.submitNew(); m.actionDone('new', true);
  assert.equal(m.root.opened, false);
  assert.equal(m.root.inputMode, '');
  reset(); m.beginInput('new'); m.newField.text = 'x'; m.herd.ok = false;
  m.submitNew();
  assert.equal(m.root.newPending, false, 'a refused start leaves the line editable');
  console.log('PASS: a failed new keeps its text, a successful one closes, a kill changes nothing');

  // prompt: failure keeps the text, success clears it, timeout says so
  reset();
  m.beginInput('prompt'); m.newField.text = 'hello';
  m.submitPrompt(false);
  assert.equal(m.promptProc.running, true);
  assert.equal(m.newField.text, 'hello', 'text is not cleared on submit');
  m.storePrompt('exit', 0); m.storePrompt('out', '{"ok":false,"error":"nope"}');
  assert.equal(m.newField.text, 'hello');
  assert.equal(m.root.promptReply, 'could not send: nope');
  assert.equal(m.root.awaitingExit, false);
  m.promptProc.running = false;
  m.submitPrompt(false);
  m.storePrompt('out', '{"ok":true,"status":"timeout","output":"\\u276f hello\\nworking"}'); m.storePrompt('exit', 0);
  assert.equal(m.newField.text, '');
  assert.match(m.root.promptReply, /^still working after 5 min\n\u276f hello\nworking$/);
  console.log('PASS: a failed prompt keeps its text; a timeout is said on its own line');

  // cancel, then resubmit before the old run has exited
  reset();
  m.beginInput('prompt'); m.newField.text = 'again';
  m.submitPrompt(false);
  m.cancelInput();
  m.beginInput('prompt');
  assert.equal(m.root.inputMode, '', 'beginInput refuses while a run is open');
  assert.match(m.herd.actionError, /still waiting/);
  m.root.inputMode = 'prompt'; m.root.promptTarget = { host: '', session: 's', pane: 'w1:p1', title: 't' };
  m.promptProc.running = false; m.promptProc.command = null;
  m.submitPrompt(true);
  assert.equal(m.promptProc.running, false, 'a resubmit before onExited is refused');
  m.root.inputMode = '';
  m.storePrompt('out', '{"ok":true}'); m.storePrompt('exit', 0);
  assert.equal(m.root.awaitingExit, false);
  assert.equal(m.root.promptReply, '', 'a result for a cancelled line shows nothing');
  console.log('PASS: cancel then resubmit before onExited is refused');

  reset();
  m.root.promptConfirmOpen = true;
  m.close();
  assert.equal(m.root.promptConfirmOpen, false);
  assert.equal(m.root.opened, false);
  console.log('PASS: close() clears promptConfirmOpen');

  // beginInput leaves a pending `new` alone, and a prompt that cannot start
  // unlocks the line with its text kept.
  reset();
  m.beginInput('new'); m.newField.text = 'keepme';
  m.submitNew();
  m.beginInput('prompt');
  assert.equal(m.root.inputMode, 'new');
  assert.equal(m.newField.text, 'keepme');
  assert.match(m.herd.actionError, /busy: new/);
  reset();
  m.root.inputMode = 'prompt'; m.root.promptTarget = { host: '', session: 's', pane: 'w1:p1', title: 't' };
  m.newField.text = 'hello';
  m.submitPrompt(true);
  assert.equal(m.root.awaitingExit, true);
  m.promptProc.running = false;                   // the start failed
  m.promptStartFailed();
  assert.equal(m.root.awaitingExit, false);
  assert.equal(m.newField.text, 'hello');
  assert.match(m.root.promptReply, /could not start/);
  console.log('PASS: a pending new is not overwritten; a prompt that cannot start unlocks');

  // An app agent: the target is captured with its kind, and survives the cursor moving.
  const appRow = { kind: 'app', name: 'space', spaceId: 'sp1', host: 'razer',
    agentList: [{ pane: 'razer/t3', title: 'lead', status: 'idle' }] };
  Object.assign(m.herd, { sessions: [appRow], sessionAt: () => appRow, agentAt: () => appRow.agentList[0],
    hostAtCursor: () => 'razer', notLive: false, asked: [],
    appRowNotLive(x) { this.asked.push(x); return this.notLive; },
    newAppSpace(host, name, dir) { this.started.push(['app', host, name, dir]); return true; } });
  reset();
  m.beginInput('prompt');
  Object.assign(m.herd, { sessionAt: () => ({ name: 'other', host: '' }), agentAt: () => ({ pane: 'w1:p1', title: 'x' }) });
  assert.deepEqual({ ...m.root.promptTarget },
    { kind: 'app', host: 'razer', session: 'sp1', pane: 'razer/t3', title: 'lead' });
  assert.equal(m.targetStatus(), 'idle', 'the captured app target is read, not the cursor');
  appRow.agentList[0].status = 'working';
  assert.equal(m.targetStatus(), 'working');

  // --force only after the busy confirmation; never through --host
  m.newField.text = 'go';
  m.herd.agentBusy = (st) => st === 'working';
  m.submitPrompt(false);
  assert.equal(m.root.promptConfirmOpen, true);
  assert.equal(m.promptProc.running, false, 'busy asks first');
  m.root.promptConfirmOpen = false;
  m.submitPrompt(true);
  assert.deepEqual(Array.from(m.promptProc.command), ['herdr-sessions', 'app-prompt', 'razer/t3', '--force']);
  m.promptProc.running = false; m.root.awaitingExit = false;
  appRow.agentList[0].status = 'idle';
  m.submitPrompt(false);
  assert.deepEqual(Array.from(m.promptProc.command), ['herdr-sessions', 'app-prompt', 'razer/t3']);

  // a row that went not-live while typing is refused by the model
  m.promptProc.running = false; m.promptProc.command = null; m.root.awaitingExit = false;
  m.herd.notLive = true;
  m.submitPrompt(false);
  assert.equal(m.promptProc.command, null);
  assert.deepEqual({ ...m.herd.asked.at(-1) }, { kind: 'app', host: 'razer' });
  m.herd.notLive = false; m.herd.agentBusy = () => false;

  // n on an app row goes to the app path with the captured host
  reset();
  Object.assign(m.herd, { sessionAt: () => appRow });
  m.beginInput('new'); m.newField.text = 'proj /home/x';
  m.submitNew();
  assert.deepEqual(m.herd.started.map((x) => Array.from(x)), [['app', 'razer', 'proj', '/home/x']]);
  assert.equal(m.root.newKind, 'app');
  Object.assign(m.herd, { sessionAt: () => ({ name: 's', host: '' }), hostAtCursor: () => '' });
  reset(); m.beginInput('new'); m.newField.text = 'plain'; m.submitNew();
  assert.deepEqual(Array.from(m.herd.started), ['plain'], 'a classic row still makes a session');
  console.log('PASS: an app prompt and new route to the app path with captured targets');
}
console.log('PASS: the menu input line');
