// Run with: node tests/legacy-panel.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const panel = fs.readFileSync(`${__dirname}/../Panel.qml`, 'utf8');
{
  const badgeText = panel.match(/text: (herd\.[^\n]+)/);
  assert.ok(badgeText, 'Missing badge text expression');
  const shown = (needCount, appMark) =>
    vm.runInNewContext(badgeText[1], { herd: { needCount, appMark } });
  assert.equal(shown(2, true), '2!', 'stale keeps the need count with a mark');
  assert.equal(shown(2, false), '2', 'need count alone');
  assert.equal(shown(0, true), '!', 'stale with nothing needed shows the failure mark');
  assert.equal(shown(0, false), '', 'working or idle is a dot, no text');
}
console.log('PASS: the bar badge text');
