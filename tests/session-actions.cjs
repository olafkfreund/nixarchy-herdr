// Run with: node tests/session-actions.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync(`${__dirname}/../HerdrModel.qml`, 'utf8');
const context = { root: { script: 'herdr-sessions' }, actionProc: {}, killProc: {}, dismiss() {},
                  activeCard: null, confirmTarget: null, confirmAction: '', confirmOpen: false,
                  sessions: [], hostState: { razer: 'ok', p620: 'ok' }, actionError: '',
                  settleTimer: { restart() {} }, actionFinished() {} };
vm.createContext(context);
for (const name of ['validName', 'validPane', 'run', 'openSession', 'focusAgent',
                    'removeSession', 'killSession', 'askKill', 'askDelete', 'ask',
                    'closeConfirm', 'confirmPending', 'sessionKey', 'agentKey', 'agentWants',
                    'blinking', 'updateAttention', 'refresh', 'applyHostPayload',
                    'launch', 'storeResult', 'complete', 'hostUnchecked', 'stateOfHost',
                    'sessionLabel', 'rowKey', 'navRowsFor', 'rowAt', 'sessionAt', 'rebuild',
                    'bestRow', 'attentionRank', 'agentAt', 'lastColumnFor', 'clampColumn',
                    'moveCursor', 'moveColumn', 'cycleColumn', 'cursorToAgent', 'cursorToSession',
                    'applyHosts', 'applyPayload', 'tooltipText', 'cleanTitle', 'pollInterval',
                    'newSession', 'hostSummary', 'countLabel', 'startFailed', 'finishRun']) {
  const match = source.match(new RegExp('  function ' + name + '\\([^]*?\\n  \\}'));
  assert.ok(match, `Missing function: ${name}`);
  vm.runInContext(match[0], context);
}

const real = { rebuild: context.rebuild, applyHostPayload: context.applyHostPayload, complete: context.complete };
for (const host of [undefined, '', 'razer', 'p620']) {
  for (const name of ['same-name', 'default']) {
    const session = { name, host, running: true, isDefault: name === 'default' };
    const prefix = ['herdr-sessions', ...(host ? ['--host', host] : [])];
    const cases = [
      ['open', () => context.openSession(session)],
      ['focus', () => context.focusAgent(session, { pane: 'w1:p2' }), 'w1:p2'],
      ['open', () => context.focusAgent(session, { pane: '' })],
      ['kill', () => context.killSession(session)],
    ];
    if (!session.isDefault) cases.push(['delete', () => context.removeSession({ ...session, running: false })]);
    for (const [action, invoke, pane] of cases) {
      context.actionProc = { running: false };
      context.killProc = { running: false };
      invoke();
      const proc = action === 'kill' ? context.killProc : context.actionProc;
      assert.deepEqual(Array.from(proc.command),
        [...prefix, action, name, ...(pane ? [pane] : [])]);
      assert.equal(proc.running, true);
      assert.equal((action === 'kill' ? context.actionProc : context.killProc).running, false);
    }
  }
}
console.log('PASS: local and remote open, focus, fallback, kill and delete routing');

// A session name is only unique on its own host. Keyed by name alone, acting
// on the local "3" dimmed razer's "3" too, and razer's agent asking blinked
// the local one.
{
  const local = { name: '3' };
  const remote = { name: '3', host: 'razer' };
  assert.notEqual(context.sessionKey(local), context.sessionKey(remote));

  context.actionProc = { running: false };
  context.run('open', local);
  assert.equal(context.pendingKey, context.sessionKey(local));
  assert.notEqual(context.pendingKey, context.sessionKey(remote));

  // updateAttention and blinking read their state through root.
  Object.assign(context.root, { agentKey: context.agentKey, agentWants: context.agentWants,
                                attentionKey: '', wantingBefore: {}, attentionPrimed: true });
  context.updateAttention([{ ...remote, agentList: [{ pane: 'w1:p1', status: 'blocked' }] },
                           { ...local, agentList: [{ pane: 'w1:p1', status: 'working' }] }]);
  assert.equal(context.blinking(remote, { pane: 'w1:p1' }), true);
  assert.equal(context.blinking(local, { pane: 'w1:p1' }), false);
}
console.log('PASS: dimming and blinking tell the same name on two hosts apart');

// Deleting a stopped session asks first, and runs only once confirmed.
for (const host of [undefined, 'razer']) {
  const session = { name: 'gone', host, running: false, isDefault: false };
  context.actionProc = { running: false };
  context.sessions = [session];
  context.askDelete(session);
  assert.equal(context.actionProc.running, false, 'askDelete must not delete anything yet');
  assert.equal(context.confirmOpen, true, 'askDelete must open the dialog');
  assert.equal(context.confirmAction, 'delete');
  context.confirmPending();
  assert.deepEqual(Array.from(context.actionProc.command),
    ['herdr-sessions', ...(host ? ['--host', host] : []), 'delete', 'gone']);
  assert.equal(context.confirmOpen, false, 'confirming must close the dialog');
}
console.log('PASS: delete asks first, then deletes on confirm');

// Every route that destroys a stopped session goes through the confirm
// dialog. A source assertion, because a behaviour case could only fail with
// "missing function", which proves nothing about the keys and buttons a user
// actually presses.
{
  const card = fs.readFileSync(`${__dirname}/../Card.qml`, 'utf8');
  const routes = {
    'Card.qml onDeleteRequested': card.match(/onDeleteRequested: \{[^]*?\n  \}/),
    'Card.qml trash button': card.match(/iconText: panel\.iconTrash[^]*?onClicked: [^\n]*/),
    'HerdrModel.qml destroy column': source.match(/if \(column === root\.columnDestroy\) \{[^]*?\n    \}/),
  };
  for (const [what, match] of Object.entries(routes)) {
    assert.ok(match, `Missing route: ${what}`);
    assert.match(match[0], /askDelete/, `${what} must ask before deleting`);
    assert.doesNotMatch(match[0], /\bremoveSession\b/, `${what} deletes without asking`);
  }
}
console.log('PASS: every route that deletes a session asks first');

// A delete herdr refused is reported as refused. `|| true` on herdr's own
// command reported {"ok":true} for a session that was still there, and the
// panel's only symptom was a row that did not go away.
{
  const os = require('node:os');
  const cp = require('node:child_process');
  const stub = fs.mkdtempSync(`${os.tmpdir()}/herdr-stub-`);
  fs.writeFileSync(`${stub}/herdr`, '#!/bin/sh\necho "no such session: gone" >&2\nexit 1\n', { mode: 0o755 });
  const out = cp.execFileSync('bash', [`${__dirname}/../bin/herdr-sessions`, 'delete', 'gone'],
    { env: { ...process.env, PATH: `${stub}:${process.env.PATH}` }, encoding: 'utf8' });
  fs.rmSync(stub, { recursive: true, force: true });
  const data = JSON.parse(out);
  assert.equal(data.ok, false, `a refused delete must not report ok, got: ${out.trim()}`);
  assert.match(data.error, /no such session: gone/);
}
console.log("PASS: a delete herdr refused keeps herdr's reason");

// A closed menu reaches no other machine. The poll timer stopped, but the
// settle timer after an action still called refresh(), which started an ssh
// per host, and an answer that landed after closing was still applied.
{
  let started = 0;
  Object.assign(context, {
    remote: true, opened: false, listProc: { running: true },
    hostPolls: { count: 1, objectAt: () => ({ running: false, start() { started++; } }) },
    hostSessions: {}, hostState: { h1: 'ok' }, rebuild() {},
  });
  context.refresh();
  assert.equal(started, 0, 'refresh must not poll hosts while the menu is closed');
  context.applyHostPayload('h1', '');
  assert.equal(context.hostState.h1, 'ok', 'a late answer must not be applied while closed');
}
console.log('PASS: no host polling while the menu is closed');

// Where an agent sits: the workspace, then the tab, whichever exist.
{
  for (const name of ['agentPlace', 'themeColor']) {
    const match = source.match(new RegExp('  function ' + name + '\\([^]*?\\n  \\}'));
    assert.ok(match, `Missing function: ${name}`);
    vm.runInContext(match[0], context);
  }
  assert.equal(context.agentPlace({ workspace: 'w', tab: 't' }), 'w  ·  t');
  assert.equal(context.agentPlace({ workspace: 'w' }), 'w');
  assert.equal(context.agentPlace({ tab: 't' }), 't');
  assert.equal(context.agentPlace({}), '');
  assert.equal(context.agentPlace(null), '');
}
console.log('PASS: agentPlace names the workspace and tab that exist');

// A theme colour only goes through flatColor when the theme sets one.
{
  const calls = [];
  context.Color = { pick: () => '', flatColor: (...args) => { calls.push(args); return 'flat'; } };
  assert.equal(context.themeColor('herdr.done', '#5FA46B'), '#5FA46B');
  assert.equal(calls.length, 0, 'flatColor must not be called when the theme sets nothing');
  context.Color.pick = () => 'accent';
  assert.equal(context.themeColor('herdr.done', '#5FA46B'), 'flat');
  assert.deepEqual(calls, [['accent', '#5FA46B']]);
}
console.log('PASS: themeColor falls back unless the theme names a colour');

// Everything below drives the model's logic with stub processes. `fresh` gives
// every case a clean slate.
const fresh = () => {
  Object.assign(context, real);
  Object.assign(context, {
    actionProc: { running: false, kind: 'action' }, killProc: { running: false, kind: 'kill' },
    actionError: '', actionName: '', actionDismiss: false, pendingKey: '', killPendingKey: '',
    hostState: { razer: 'ok' }, hostNames: [], hostSessions: {}, sessions: [], localSessions: [],
    remote: true, opened: true, pollGen: 0, cursor: -1, column: 0, cursorPlaced: false,
    reachable: true, errorText: '', hiddenSessions: 0, unreadableCount: 0,
    runningCount: 0, blockedCount: 0, workingCount: 0, doneCount: 0, agentCount: 0,
    confirmOpen: false, confirmTarget: null, confirmAction: '', columnRow: 0, columnOpen: 1,
    columnDestroy: 2,
  });
  context.dismissed = 0; context.finished = [];
  context.dismiss = () => { context.dismissed++; };
  context.actionFinished = (a, ok) => context.finished.push([a, ok]);
  context.showRow = () => {};
  context.root.agentKey = context.agentKey; context.root.agentWants = context.agentWants;
  Object.assign(context.root, { attentionKey: '', wantingBefore: {}, attentionPrimed: true });
  context.attentionKey = ''; context.wantingBefore = {}; context.attentionPrimed = true;
};
Object.defineProperty(context, 'navRows', { get: () => context.navRowsFor(context.sessions), configurable: true });
const sess = (name, ...panes) => ({ name, running: true,
  agentList: panes.map((p) => ({ pane: p, status: 'idle' })) });
const finish = (proc, out, code) => {
  proc.running = false;
  context.storeResult(proc, 'out', out); context.storeResult(proc, 'exit', code);
};

{
  fresh();
  assert.equal(context.run('open', sess('a')), true);
  assert.equal(context.run('focus', sess('a'), 'w1:p1'), false);
  assert.equal(context.actionError, 'busy: open is still running');
  assert.equal(context.newSession('', 'b'), false);
  assert.equal(context.newSession('', 'bad name'), false);
  assert.equal(context.actionError, 'not a valid session name');
}
console.log('PASS: a second action says busy, an invalid name says so');

{
  fresh();
  context.run('open', sess('a'));
  context.killSession(sess('a'));
  assert.equal(context.killProc.running, true, 'kill runs while another action is busy');
  assert.equal(context.actionError, '');
}
console.log('PASS: kill is not blocked by a running action');

for (const order of [['out', 'exit'], ['exit', 'out']]) {
  fresh();
  let calls = 0;
  const realComplete = context.complete;
  context.complete = () => { calls++; };
  const proc = { kind: 'action' };
  for (const which of order) context.storeResult(proc, which, which === 'out' ? '{}' : 0);
  context.complete = realComplete;
  assert.equal(calls, 1, `complete must run once, order ${order}`);
}
console.log('PASS: complete runs once in either signal order');

// Quickshell 0.3.2 reports a command that cannot start only by `running`
// going false: no stdout, no exit. That run must still complete, once.
{
  fresh();
  context.newSession('', 'b');
  assert.equal(context.actionProc.open, true);
  context.actionProc.running = false;            // the start failed
  assert.equal(context.run('open', sess('a')), false, 'an open run is still busy');
  context.startFailed(context.actionProc);
  context.startFailed(context.actionProc);       // a second runningChanged is ignored
  assert.deepEqual(context.finished, [['new', false]]);
  assert.equal(context.actionError, 'could not start herdr-sessions');
  assert.equal(context.actionProc.open, false);
  assert.equal(context.run('open', sess('a')), true, 'the next action can start');
  // A normal finish completes first, so the runningChanged after it does nothing.
  context.storeResult(context.actionProc, 'out', '{"ok":true}');
  context.storeResult(context.actionProc, 'exit', 0);
  context.startFailed(context.actionProc);
  assert.deepEqual(context.finished, [['new', false], ['open', true]]);
}
console.log('PASS: a run that fails to start completes once, as a failure');

{
  fresh();
  context.run('open', sess('a'), undefined, true);
  finish(context.actionProc, '{"ok":true}', 1);
  assert.equal(context.dismissed, 0, 'ok:true with exit 1 is a failure');
  assert.match(context.actionError, /exited with code 1/);
  assert.equal(JSON.stringify(context.finished), '[["open",false]]');

  context.run('open', sess('a'), undefined, true);
  finish(context.actionProc, '{"ok":true}', 0);
  assert.equal(context.dismissed, 1);
  assert.equal(context.actionError, '');

  context.pinned = true;
  // dismiss() itself is a no-op when pinned; the model only calls it on success.
  context.run('open', sess('a'));
  finish(context.actionProc, '{"ok":true}', 0);
  assert.equal(context.dismissed, 1, 'an action that does not ask to dismiss does not');
}
console.log('PASS: a failed run does not dismiss; a successful one does once');

{
  const dismiss = source.match(/  function dismiss\([^]*?\n  \}/)[0];
  const ctx = { pinned: true, closed: 0 };
  ctx.close = () => { ctx.closed++; };
  vm.createContext(ctx); vm.runInContext(dismiss, ctx);
  ctx.dismiss(); assert.equal(ctx.closed, 0, 'pinned panel stays');
  ctx.pinned = false; ctx.dismiss(); assert.equal(ctx.closed, 1);
}
console.log('PASS: a pinned panel is not dismissed');

{
  fresh();
  context.run('open', sess('a'));
  finish(context.actionProc, '{"ok":true}', 0);
  assert.equal(JSON.stringify(context.finished), '[["open",true]]', 'the action emits');
  fresh();
  context.killSession(sess('a'));
  finish(Object.assign(context.killProc, { kind: 'kill' }), '{"ok":false,"error":"nope"}', 0);
  assert.equal(context.actionError, 'nope');
  finish({ kind: 'list' }, '{"ok":true,"sessions":[]}', 0);
  finish({ kind: 'host', gen: 0, modelData: 'razer' }, '{"ok":true,"sessions":[]}', 0);
  assert.equal(context.finished.length, 0, 'kill and polls never emit actionFinished');
  assert.equal(context.actionError, 'nope', 'a list or poll completion leaves the action error');
}
console.log('PASS: actionFinished is only for actionProc');

{
  fresh();
  context.sessions = [{ name: 'a', running: true, agentList: [] }];
  context.localSessions = [{ name: 'a', running: true, agentList: [] }];
  context.actionError = 'kept';
  context.rebuild();
  context.applyPayload('{"ok":true,"sessions":[]}', 0);
  assert.equal(context.actionError, 'kept', 'a refresh leaves the action error alone');
}
console.log('PASS: actionError survives a refresh');

{
  fresh();
  const a = sess('a', 'w1:p1', 'w1:p2'), b = sess('b', 'w2:p1');
  context.localSessions = [a, b]; context.rebuild();
  context.cursor = 2; // b's agent
  context.cursorPlaced = true;
  context.localSessions = [b, a]; context.rebuild();
  assert.equal(context.cursor, 0, 'the cursor follows b to the top');
  // an unknown key falls back to the clamped old index
  context.cursor = 2; context.localSessions = [b]; context.rebuild();
  assert.equal(context.cursor, 0);
}
console.log('PASS: a re-sort keeps the cursor on the same row');

{
  fresh();
  const a = sess('a', 'w1:p1'), b = sess('b', 'w2:p1');
  b.agentList[0].status = 'blocked';
  context.localSessions = [a, b];
  context.sessions = [a, b]; // the list from before the first poll answers
  context.moveCursor(1);
  assert.equal(context.cursorPlaced, true);
  context.moveCursor(1);
  const moved = context.cursor;
  context.rebuild();
  assert.equal(context.cursor, moved, 'rebuild must not drag the cursor to the best row');
}
console.log('PASS: moving before the first poll survives rebuild');

{
  fresh();
  const target = { name: 'gone', running: false };
  context.sessions = [{ name: 'gone', running: true }];
  context.confirmTarget = target; context.confirmAction = 'delete';
  context.confirmPending();
  assert.equal(context.actionProc.running, false);
  assert.equal(context.actionError, 'gone changed; nothing done');
  context.sessions = [];
  context.confirmTarget = { name: 'x', running: true }; context.confirmAction = 'kill';
  context.confirmPending();
  assert.equal(context.killProc.running, false);
}
console.log('PASS: confirm on a changed session does nothing');

{
  fresh();
  context.hostState = {};
  const s = { name: 'x', host: 'razer', running: true };
  context.killSession(s); context.askKill(s);
  assert.equal(context.killProc.running, false);
  assert.equal(context.confirmOpen, false);
  assert.equal(context.actionError, 'razer not checked yet');
  context.hostState = { razer: 'down' };
  context.askKill(s);
  assert.equal(context.confirmOpen, false);
  context.hostState = { razer: 'ok' };
  context.killSession(s);
  assert.equal(context.killProc.running, true);
  assert.equal(context.stateOfHost('other'), 'checking');
  context.hostNames = ['razer', 'b']; context.hostState = { razer: 'ok' };
  assert.match(context.hostSummary(), /b …/);
}
console.log('PASS: kill is refused on a checking or down host');

{
  fresh();
  let applied = 0;
  context.applyHostPayload = () => { applied++; };
  context.pollGen = 2;
  finish({ kind: 'host', gen: 1, modelData: 'razer' }, '{"ok":true}', 0);
  assert.equal(applied, 0, 'an older generation is ignored');
  finish({ kind: 'host', gen: 2, modelData: 'razer' }, '{"ok":true}', 0);
  assert.equal(applied, 1);
  let restarted = 0;
  const poll = { kind: 'host', gen: 2, modelData: 'razer', restartPending: true, start() { restarted++; } };
  finish(poll, '{"ok":true}', 0);
  assert.equal(restarted, 1);
  assert.equal(poll.restartPending, false);
  context.opened = false;
  poll.restartPending = true;
  finish(poll, '{"ok":true}', 0);
  assert.equal(restarted, 1, 'a closed menu does not restart');
}
console.log('PASS: old poll generations are ignored and restartPending restarts');

{
  fresh();
  context.hostNames = ['a', 'b']; context.hostSessions = { a: [], b: [] }; context.hostState = { a: 'ok', b: 'ok' };
  context.applyHosts(['a']);
  assert.equal(JSON.stringify(Object.keys(context.hostSessions)), '["a"]');
  assert.equal(JSON.stringify(Object.keys(context.hostState)), '["a"]');
}
console.log('PASS: applyHosts prunes what left');

{
  fresh();
  context.localSessions = [{ name: 'a', running: true, readable: false, agentList: [] }];
  context.rebuild();
  assert.equal(context.unreadableCount, 1);
  assert.equal(context.countLabel(context.sessions[0]), 'unreadable');
  assert.match(context.tooltipText(), /1 unreadable/);
  assert.equal(context.countLabel({ running: true, agents: 3, hiddenAgents: 2 }), '3 agents (2 not shown)');
  context.reachable = false; context.errorText = 'boom';
  assert.equal(context.tooltipText(), 'Herdr: boom');
}
console.log('PASS: the tooltip shows unreachable and unreadable');

assert.equal(context.cleanTitle('⠋ build'), 'build');
assert.equal(context.cleanTitle('✳ ● working'), 'working');
assert.equal(context.cleanTitle('日本語 task'), '日本語 task');
assert.equal(context.cleanTitle('✳'), '✳');
console.log('PASS: cleanTitle strips spinners, keeps CJK');

{
  fresh();
  const mk = (seq1, seq2) => [
    { name: 'a', agentList: [{ pane: 'w1:p1', status: 'blocked', seq: seq1 }] },
    { name: 'b', agentList: [{ pane: 'w1:p1', status: 'blocked', seq: seq2 }] }];
  context.updateAttention(mk(5, 5));
  assert.equal(context.root.attentionKey, '', 'equal seq: nobody blinks');
  context.root.wantingBefore = {};
  context.updateAttention(mk(5, 7));
  assert.match(context.root.attentionKey, /b/);
}
console.log('PASS: an equal-seq tie blinks nobody');

{
  fresh();
  context.opened = false;
  context.doneCount = 3;
  assert.equal(context.pollInterval(), 20000);
  context.workingCount = 1;
  assert.equal(context.pollInterval(), 5000);
  context.opened = true;
  assert.equal(context.pollInterval(), 3000);
}
console.log('PASS: a done-only list polls every 20 s');

// Menu.qml: its input line, with stubs for the model, the field and the process.
{
  const menu = fs.readFileSync(`${__dirname}/../Menu.qml`, 'utf8');
  const m = { Qt: { callLater() {} }, JSON };
  m.root = { inputMode: '', promptTarget: null, promptReply: '', promptConfirmOpen: false,
             newPending: false, awaitingExit: false, newHost: '', opened: true };
  m.newField = { text: '', forceActiveFocus() {} };
  m.card = { forceActiveFocus() {} };
  m.promptProc = { running: false };
  m.herd = { actionError: '', script: 'herdr-sessions', started: [],
    newSession(host, name) { this.started.push(name); return this.ok; }, ok: true,
    agentBusy: () => false, targetStatus: () => 'idle', sessions: [],
    sessionAt: () => ({ name: 's', host: '' }), agentAt: () => ({ pane: 'w1:p1', title: 't' }),
    cleanTitle: (x) => x, hostAtCursor: () => '', cursor: 0 };
  vm.createContext(m);
  for (const name of ['beginInput', 'cancelInput', 'submitInput', 'submitNew', 'actionDone',
                      'targetStatus', 'submitPrompt', 'storePrompt', 'promptDone', 'replyFrom', 'close',
                      'promptStartFailed']) {
    const match = menu.match(new RegExp('  function ' + name + '\\([^]*?\\n  \\}'));
    assert.ok(match, `Missing Menu function: ${name}`);
    vm.runInContext(match[0], m);
    m.root[name] = m[name];
  }
  const reset = () => {
    Object.assign(m.root, { inputMode: '', promptTarget: null, promptReply: '', promptConfirmOpen: false,
      newPending: false, awaitingExit: false, opened: true });
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
  assert.match(m.root.promptReply, /^still working after 5 min\nworking$/);
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
}
