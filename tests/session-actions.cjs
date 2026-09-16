// Run with: node tests/session-actions.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync(`${__dirname}/../HerdrModel.qml`, 'utf8');
const context = { root: { script: 'herdr-sessions' }, actionProc: {}, dismiss() {} };
vm.createContext(context);
for (const name of ['validName', 'validPane', 'run', 'openSession', 'focusAgent',
                    'removeSession', 'killSession']) {
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
