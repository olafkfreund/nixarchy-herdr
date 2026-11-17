// Run with: node tests/session-actions.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync(`${__dirname}/../HerdrModel.qml`, 'utf8');
const context = { root: { script: 'herdr-sessions' }, actionProc: {}, killProc: {}, dismiss() {},
                  activeCard: null, confirmTarget: null, confirmAction: '', confirmOpen: false,
                  sessions: [], hostState: { razer: 'ok', p620: 'ok' }, actionError: '',
                  settleTimer: { restart() {} }, actionFinished() {},
                  confirmAgent: null, appSessions: [], appHostSessions: [], appMachines: [], appStale: false,
                  hcAvailable: true, blockedCount: 0, doneCount: 0 };
Object.defineProperty(context, 'appMark', { get() { return this.hcAvailable && this.appStale; } });
context.root.urgent = 'URGENT'; context.root.finished = 'GREEN'; context.root.working = 'AMBER';
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
                    'newSession', 'hostSummary', 'countLabel', 'startFailed', 'finishRun',
                    'validHcAddress', 'requestNew', 'requestPrompt', 'requestInterrupt',
                    'askKillAgent', 'appKill', 'newAppSpace', 'appStart', 'appLine',
                    'appRunList', 'appSubDown', 'appSubExited', 'appSubStartFailed',
                    'applyAppList', 'appMachineState', 'appRowStale', 'appRowNotLive',
                    'appLaunch', 'confirmMessage', 'subtitleFor', 'agentNote', 'agentColor',
                    'activateCursor', 'errorLine', 'badgeColor']) {
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
{
  const saved = [context.appStale, context.hcAvailable, context.doneCount];
  context.doneCount = 2; context.appStale = false;
  assert.equal(context.badgeColor(), 'GREEN');
  context.appStale = true;
  assert.equal(context.badgeColor(), 'URGENT', 'stale is never green');
  context.doneCount = 0;
  assert.equal(context.badgeColor(), 'URGENT', 'stale with no agents');
  context.hcAvailable = false;
  assert.equal(context.badgeColor(), 'AMBER', 'no hc, no mark');
  [context.appStale, context.hcAvailable, context.doneCount] = saved;
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
  context.Commons = { Color: context.Color }; // Commons.Color since Qt 6.12 (olafkfreund/nixarchy#1381)
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
  m.promptConfirm = { selectedIndex: 0 }; m.confirmKeys = { forceActiveFocus() {} };
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

// herdr-core and herdr-app: the subscription, the sources, the keys, the
// kind-aware actions and the "not live" refusals.
{
  const timer = () => ({ running: false, starts: 0, restarts: 0, interval: 0,
    start() { this.running = true; this.starts++; },
    restart() { this.running = true; this.restarts++; },
    stop() { this.running = false; } });
  const appFresh = () => {
    fresh();
    Object.assign(context, {
      hcAvailable: true, appStale: false, appDirty: false, appSubLive: false, appError: '',
      appSessions: [], appHostSessions: [], appMachines: [], appBackoffMs: 2000, appBackoffCur: 0,
      appCoalesce: timer(), appWatchdog: timer(), appBackoff: timer(),
      appSubProc: { running: false, launched: false, exited: false },
      appListProc: { running: false, open: false, kind: 'applist' },
      confirmAgent: null, killSessionRef: null, killAgentRef: null,
      beginConfirms: 0, emitted: 0, prompts: 0,
      activeCard: { beginConfirm() { context.beginConfirms++; }, endConfirm() {} },
      newSessionRequested() { context.emitted++; }, promptRequested() { context.prompts++; },
    });
    Object.assign(context.root, { columnRow: 0, columnOpen: 1, columnDestroy: 2, urgent: 'URGENT' });
    context.urgent = 'URGENT';
  };
  const listOut = (rows, machines = []) => JSON.stringify({ ok: true, error: '', sessions: rows, machines });
  const app = (spaceId, host, ...addrs) => ({ kind: 'app', name: 'space ' + spaceId, host, spaceId, running: true,
    readable: true, agents: addrs.length, projects: [],
    agentList: addrs.map((a) => ({ title: 't' + a, status: 'idle', kind: null, pane: a, tab: '',
      seq: 0, cascade: [], cascadeKey: '' })) });
  const runList = (rows, machines) => {
    context.appListProc.running = false;
    finish(context.appListProc, listOut(rows, machines), 0);
  };

  // Coalescing, heartbeats, the dirty rerun
  appFresh();
  context.appStart();
  assert.equal(context.appSubProc.running, true);
  context.appLine('{"seq":1,"terminals":[]}');
  for (let i = 0; i < 3; i++) context.appLine('{"event":"x"}');
  assert.equal(context.appCoalesce.starts, 1, 'a burst starts the timer once');
  context.appCoalesce.running = false;
  context.appRunList();
  assert.deepEqual(Array.from(context.appListProc.command), ['herdr-sessions', 'app-list', '--remote']);
  context.appLine('{"event":"y"}');
  assert.equal(context.appDirty, true);
  assert.equal(context.appCoalesce.starts, 1, 'a line during a run does not start the timer');
  context.appListProc.command = null;
  runList([]);
  assert.ok(context.appListProc.command, 'dirty gives exactly one more run');
  assert.equal(context.appDirty, false);
  context.appListProc.command = null;
  runList([]);
  assert.equal(context.appListProc.command, null, 'and no more than one');
  const before = context.appCoalesce.starts, wd = context.appWatchdog.restarts;
  context.appLine('{"type":"heartbeat"}');
  context.appLine('not json');
  assert.equal(context.appCoalesce.starts, before, 'heartbeats and junk trigger nothing');
  assert.equal(context.appWatchdog.restarts, wd + 2, 'but every line resets the watchdog');
  console.log('PASS: a burst coalesces to one app-list, dirty reruns once, heartbeats only reset the watchdog');

  // Staleness and backoff
  appFresh();
  context.appStart();
  context.appLine('{"seq":1,"terminals":[]}');
  context.appSubDown();
  assert.equal(context.appStale, true);
  assert.equal(context.appSubProc.running, false, 'a silent subscription is killed');
  assert.equal(context.appBackoff.interval, 2000);
  context.appSubDown();
  assert.equal(context.appBackoff.starts, 1, 'a second down while waiting does nothing');
  context.appSubExited();
  assert.equal(context.appBackoff.starts, 1, 'the exit of a process we killed is ignored');
  context.appBackoff.running = false;
  context.appStart();
  assert.equal(context.appSubProc.running, true);
  context.appSubExited();                          // it died by itself
  assert.equal(context.appBackoff.interval, 4000, 'backoff doubles');
  assert.equal(context.appStale, true);
  context.appBackoff.running = false;
  context.appStart();
  runList([]);                                     // answered before any line arrived
  assert.equal(context.appStale, true, 'a list that lands while the subscription is down does not clear stale');
  context.appLine('{"seq":2,"terminals":[]}');
  runList([]);
  assert.equal(context.appStale, false);
  assert.equal(context.appBackoffCur, 0, 'backoff resets after a good list');
  context.appListProc.running = false;
  finish(context.appListProc, '{"ok":false,"error":"boom"}', 1);
  assert.equal(context.appStale, true);
  assert.equal(context.appError, 'boom');
  assert.equal(context.actionError, '', 'a list failure never touches actionError');
  console.log('PASS: stale until a good app-list, backoff doubles and resets');

  // No hc at all
  appFresh();
  context.appSessions = [app('sp1', '', 't1')];
  context.appSubProc.launched = true;
  context.appSubStartFailed();
  assert.equal(context.hcAvailable, false);
  assert.equal(context.appSessions.length, 0);
  context.appStart();
  context.appSubDown();
  assert.equal(context.appSubProc.running, false, 'no retry');
  assert.equal(context.appBackoff.starts, 0);
  console.log('PASS: no hc means no rows and no retry');

  // Four sources, the menu split, keys, the cursor
  appFresh();
  context.hostNames = ['razer'];
  context.localSessions = [{ name: 'c1', running: true, agentList: [{ pane: 'w1:p1', status: 'idle' }] }];
  context.hostSessions = { razer: [{ name: 'c2', host: 'razer', running: true, agentList: [] }] };
  context.hostState = { razer: 'ok' };
  runList([app('sp1', '', 't1'), app('sp1', 'razer', 'razer/t1'), app('sp2', '', 't2')],
          [{ name: 'razer', state: 'connected' }]);
  assert.deepEqual(Array.from(context.sessions, (x) => x.name),
    ['c1', 'space sp1', 'space sp2', 'c2', 'space sp1']);
  assert.equal(context.sessions[1].host, '');
  assert.equal(context.sessions[4].host, 'razer');
  const keys = new Set(Array.from(context.sessions, (x) => context.sessionKey(x)));
  assert.equal(keys.size, 5, 'no key collides');
  assert.notEqual(context.sessionKey({ kind: 'app', host: '', spaceId: 'sp1' }),
                  context.sessionKey({ name: 'sp1' }));
  context.cursorPlaced = true; context.cursor = 1;   // sp1's agent; classic c1 is row 0
  assert.equal(context.agentAt(context.cursor).pane, 't1');
  const renamed = app('sp1', '', 't1'); renamed.name = 'renamed';
  runList([app('sp0', '', 't0'), renamed, app('sp2', '', 't2'), app('sp1', 'razer', 'razer/t1')],
          [{ name: 'razer', state: 'connected' }]);
  assert.equal(context.agentAt(context.cursor).pane, 't1', 'the cursor follows a renamed space');
  // the bar's instance never gets remote rows
  context.remote = false;
  runList([app('sp1', '', 't1'), app('sp1', 'razer', 'razer/t1')]);
  assert.equal(context.appHostSessions.length, 0);
  assert.equal(context.sessions.filter((x) => x.kind === 'app').length, 1);
  console.log('PASS: the four sources merge, the bar gets no remote rows, keys differ, the cursor follows');

  // Dispatch by kind
  appFresh();
  context.hostNames = [];
  runList([app('sp1', 'razer', 'razer/t3')], [{ name: 'razer', state: 'connected' }]);
  const row = context.sessions[0];
  const last = () => Array.from(context.actionProc.command);
  context.openSession(row);
  assert.deepEqual(last(), ['herdr-sessions', 'app-focus', 'razer/t3']);
  assert.equal(context.actionDismiss, true);
  assert.equal(context.run('kill', row), false, 'a classic action never targets an app row');
  context.killSession(row);
  assert.equal(context.killProc.running, false);
  context.actionProc = { running: false, kind: 'action' };
  context.cursor = 0;
  context.requestInterrupt();
  assert.deepEqual(last(), ['herdr-sessions', 'app-interrupt', 'razer/t3']);
  finish(context.actionProc, '{"ok":true,"note":"still working"}', 0);
  assert.equal(context.actionError, 'still working');
  assert.equal(context.newAppSpace('razer', 'proj', ''), true);
  assert.deepEqual(last(), ['herdr-sessions', 'app-new', 'proj', '', 'razer']);
  finish(context.actionProc, '{"ok":true}', 0);
  context.newAppSpace('', 'proj', '/home/x');
  assert.deepEqual(last(), ['herdr-sessions', 'app-new', 'proj', '/home/x', '']);
  finish(context.actionProc, '{"ok":true}', 0);
  assert.equal(context.newAppSpace('', 'bad name', ''), false);
  assert.equal(context.lastColumnFor(row), 1, 'no destroy column on an app row');
  context.column = 2; context.activateCursor();
  assert.equal(context.confirmOpen, false, 'the destroy column does nothing on an app row');
  context.askDelete(row);
  assert.equal(context.confirmOpen, false);
  console.log('PASS: app rows dispatch to the app subcommands with the right arguments');

  // Kill: confirm names the cascade; a changed reply reopens it
  appFresh();
  const withCascade = app('sp1', '', 't3');
  Object.assign(withCascade.agentList[0], { title: 'lead', cascadeKey: 't4',
    cascade: [{ address: 't4', title: 'sub-agent' }] });
  runList([withCascade]);
  context.cursor = 0; context.cursorPlaced = true;
  context.askKill(context.sessions[0]);
  assert.equal(context.confirmOpen, true);
  assert.equal(context.killProc.running, false, 'asks first');
  assert.match(context.confirmMessage(), /lead/);
  assert.match(context.confirmMessage(), /t4 sub-agent/);
  context.confirmPending();
  assert.deepEqual(Array.from(context.killProc.command), ['herdr-sessions', 'app-kill', 't3', 't4']);
  context.killProc.running = false;
  finish(context.killProc, JSON.stringify({ ok: false, changed: true,
    cascade: [{ address: 't4', title: 'sub-agent' }, { address: 't9', title: 'late child' }],
    cascadeKey: 't4,t9' }), 0);
  assert.equal(context.confirmOpen, true, 'a changed reply reopens the confirmation');
  assert.equal(context.beginConfirms, 2);
  assert.match(context.confirmMessage(), /t9 late child/);
  assert.equal(context.actionError, '');
  context.confirmPending();
  assert.deepEqual(Array.from(context.killProc.command), ['herdr-sessions', 'app-kill', 't3', 't4,t9']);
  console.log('PASS: kill confirms with the cascade and reopens when it changed');

  // Not live
  const refusals = [
    ['stale', () => { context.appStale = true; }, 'desktop app', 'sp1', ''],
    ['machine', () => { context.appMachines = [{ name: 'razer', state: 'disconnected' }]; }, 'razer', 'sp2', 'razer'],
  ];
  for (const [, make, who, space, host] of refusals) {
    appFresh();
    runList([app(space, host, host ? 'razer/t1' : 't1')], [{ name: 'razer', state: 'connected' }]);
    make();
    const target = context.sessions[0];
    context.cursor = 0; context.cursorPlaced = true;
    const attempts = [
      () => context.focusAgent(target, target.agentList[0]),
      () => context.openSession(target),
      () => context.requestInterrupt(),
      () => context.askKill(target),
      () => context.requestNew(),
      () => context.requestPrompt(),
      () => context.newAppSpace(host, 'p', ''),
    ];
    for (const attempt of attempts) {
      context.actionError = '';
      attempt();
      assert.equal(context.actionError, who + ' is not live');
    }
    assert.equal(context.actionProc.running, false);
    assert.equal(context.confirmOpen, false);
    assert.equal(context.emitted + context.prompts, 0);
    assert.equal(context.subtitleFor(target), 'not live');
  }
  console.log('PASS: a not-live row refuses focus, prompt, interrupt, kill and new');

  // Helpers
  appFresh();
  assert.equal(context.validHcAddress('t3'), true);
  assert.equal(context.validHcAddress('razer/t4'), true);
  for (const bad of ['', 'w1:p1', 't3; x', '/t3', 'a/b/t3']) assert.equal(context.validHcAddress(bad), false);
  assert.equal(context.agentNote('error'), 'error');
  assert.equal(context.agentNote('blocked', 'question'), 'needs you: question');
  assert.equal(context.agentNote('blocked'), 'needs you');
  assert.equal(context.agentColor('error'), 'URGENT');
  assert.equal(context.subtitleFor(app('s', '', 't1')), 'desktop app');
  context.appMachines = [{ name: 'razer', state: 'connected' }];
  assert.match(context.subtitleFor(app('s', 'razer', 'razer/t1')), /desktop app.*razer/);
  context.appStale = true;
  assert.match(context.tooltipText(), /herdr-core not reachable/);
  console.log('PASS: validators, agentNote, agentColor, subtitles and the stale tooltip');
}

// Card.qml: the error line order, no destroy button on app rows, the `i` key.
{
  fresh();
  Object.assign(context, { appError: '', hiddenSessions: 0 });
  const set = (o) => Object.assign(context, { actionError: '', errorText: '', appError: '', reachable: true,
    hiddenSessions: 0 }, o);
  assert.equal(context.errorLine(), (set({}), ''));
  set({ hiddenSessions: 2 }); assert.equal(context.errorLine(), '2 sessions not shown');
  set({ hiddenSessions: 2, appError: 'app' }); assert.equal(context.errorLine(), 'app');
  set({ hiddenSessions: 2, appError: 'app', errorText: 'list' }); assert.equal(context.errorLine(), 'list');
  set({ appError: 'app', errorText: 'list', actionError: 'act' }); assert.equal(context.errorLine(), 'act');
  const card = fs.readFileSync(`${__dirname}/../Card.qml`, 'utf8');
  assert.match(card, /visible: row\.modelData\.running && row\.modelData\.kind !== "app"\s+iconText: panel\.iconKill/);
  assert.match(card, /!row\.modelData\.isDefault\s+&& row\.modelData\.kind !== "app"\s+iconText: panel\.iconTrash/);
  assert.match(card, /t === "i"\) panel\.requestInterrupt\(\)/);
  assert.match(card, /text: panel\.errorLine\(\)/);
}
console.log('PASS: the error line order, no destroy button on app rows, the i key');
