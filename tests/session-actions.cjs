// Run with: node tests/session-actions.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync(`${__dirname}/../HerdrModel.qml`, 'utf8');
const context = { root: { script: 'herdr-sessions' }, actionProc: {}, dismiss() {},
                  activeCard: null, confirmTarget: null, confirmAction: '', confirmOpen: false };
vm.createContext(context);
for (const name of ['validName', 'validPane', 'run', 'openSession', 'focusAgent',
                    'removeSession', 'killSession', 'askKill', 'askDelete', 'ask',
                    'closeConfirm', 'confirmPending']) {
  const match = source.match(new RegExp('  function ' + name + '\\([^]*?\\n  \\}'));
  assert.ok(match, `Missing function: ${name}`);
  vm.runInContext(match[0], context);
}

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
      invoke();
      assert.deepEqual(Array.from(context.actionProc.command),
        [...prefix, action, name, ...(pane ? [pane] : [])]);
      assert.equal(context.actionProc.running, true);
    }
  }
}
console.log('PASS: local and remote open, focus, fallback, kill and delete routing');

// Deleting a stopped session asks first, and runs only once confirmed.
for (const host of [undefined, 'razer']) {
  const session = { name: 'gone', host, running: false, isDefault: false };
  context.actionProc = { running: false };
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
