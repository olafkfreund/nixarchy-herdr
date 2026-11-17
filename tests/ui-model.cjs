// Run with: node tests/ui-model.cjs
// The model's side of the UI pass: badge, priority, text size, blink, showRow.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync(`${__dirname}/../HerdrModel.qml`, 'utf8');
const ctx = { root: { urgent: 'URGENT', finished: 'GREEN', working: 'AMBER', workingForeground: 'AMBERFG',
                      foreground: 'FG' },
              Qt: { alpha: (c, a) => `${c}@${a}` }, Number, isFinite, Math, String,
              blockedCount: 0, doneCount: 0, workingCount: 0, runningCount: 0, agentCount: 0,
              unreadableCount: 0, hcAvailable: true, appStale: false, reachable: true, errorText: '',
              textScale: 1.0, blinkTimer: { restarts: 0, stops: 0, restart() { this.restarts++; }, stop() { this.stops++; } } };
ctx.urgent = 'URGENT'; ctx.finished = 'GREEN'; ctx.working = 'AMBER'; ctx.workingForeground = 'AMBERFG';
ctx.foreground = 'FG';
vm.createContext(ctx);

const fn = (name) => {
  const match = source.match(new RegExp('  function ' + name + '\\([^]*?\\n  \\}'));
  assert.ok(match, `Missing function: ${name}`);
  vm.runInContext(match[0], ctx);
};
for (const name of ['priority', 'noteLabel', 'noteColor', 'statusColor', 'badgeColor', 'tooltipText',
                    'setTextScale', 'textBigger', 'textSmaller', 'textReset', 'applyTextScale',
                    'agentKey', 'sessionKey', 'agentWants', 'updateAttention', 'blinking', 'agentColor',
                    'togglePin', 'moveCursor', 'rowAt', 'navRowsFor', 'rowKey', 'rebuild', 'bestRow',
                    'attentionRank', 'agentAt']) fn(name);

// Properties are bindings in QML: evaluate the same expressions as getters.
const prop = (name, re) => {
  const m = source.match(re);
  assert.ok(m, `Missing property: ${name}`);
  Object.defineProperty(ctx, name, { get: () => vm.runInContext(m[1], ctx), configurable: true });
};
prop('badgeActive', /readonly property bool badgeActive:\n\s+(.+)/);
prop('needCount', /readonly property int needCount: (.+)/);
prop('appMark', /readonly property bool appMark: (.+)/);
prop('badgeShown', /readonly property bool badgeShown: (.+)/);
ctx.root.agentKey = ctx.agentKey; ctx.root.agentWants = ctx.agentWants;

const set = (o) => Object.assign(ctx, { blockedCount: 0, doneCount: 0, workingCount: 0, runningCount: 0,
  agentCount: 0, unreadableCount: 0, hcAvailable: true, appStale: false, reachable: true, errorText: '' }, o);
// The badge text exactly as Panel.qml states it (U1), for the cases below.
const badgeText = () => ctx.needCount > 0 ? String(ctx.needCount) + (ctx.appMark ? '!' : '')
  : ctx.appMark ? '!' : '';

// Badge visibility and text
set({}); assert.equal(ctx.badgeShown, false, 'idle herd: no badge');
set({ blockedCount: 2, runningCount: 1 }); assert.equal(ctx.badgeShown, true); assert.equal(ctx.needCount, 2);
assert.equal(ctx.badgeColor(), 'URGENT');
set({ doneCount: 1, runningCount: 1 }); assert.equal(ctx.badgeColor(), 'GREEN');
set({ workingCount: 3, runningCount: 1 }); assert.equal(ctx.badgeShown, true); assert.equal(ctx.needCount, 0);
assert.equal(ctx.badgeColor(), 'AMBER'); assert.equal(badgeText(), '', 'working is a dot');
set({ appStale: true }); assert.equal(ctx.badgeShown, true, 'stale shows with nothing needed');
assert.equal(badgeText(), '!'); assert.equal(ctx.badgeColor(), 'URGENT');
set({ appStale: true, blockedCount: 2 }); assert.equal(badgeText(), '2!');
set({ appStale: true, hcAvailable: false }); assert.equal(ctx.badgeShown, false, 'no hc, no mark');
set({ blockedCount: 1, runningCount: 0, reachable: false, errorText: 'boom' });
assert.equal(ctx.badgeShown, true, 'hc-only agents show with no classic server');
assert.equal(ctx.badgeShown, true, 'classic failing with a blocked app agent still shows');
console.log('PASS: badge visibility, count, text and colour');

// priority and the colours
assert.equal(ctx.priority(null), 'idle');
assert.equal(ctx.priority({ blocked: 1, done: 2, working: 3 }), 'blocked');
assert.equal(ctx.priority({ done: 2, working: 3 }), 'done');
assert.equal(ctx.priority({ working: 3 }), 'working');
assert.equal(ctx.priority({}), 'idle');
assert.equal(ctx.noteColor(null), 'FG');
assert.equal(ctx.noteColor({ blocked: 1 }), 'URGENT');
assert.equal(ctx.noteColor({ done: 1 }), 'GREEN');
assert.equal(ctx.noteColor({ working: 1 }), 'AMBERFG');
assert.equal(ctx.statusColor(null), 'FG@0.62');
assert.equal(ctx.statusColor({ running: false, blocked: 1 }), 'FG@0.62', 'stopped is dim');
assert.equal(ctx.statusColor({ running: true }), 'FG@0.82', 'idle');
assert.equal(ctx.statusColor({ running: true, working: 1 }), 'AMBERFG');
assert.equal(ctx.statusColor({ running: true, done: 1, working: 1 }), 'GREEN');
assert.equal(ctx.noteLabel({ running: true, blocked: 1, done: 1 }), '1 needs you');
assert.equal(ctx.noteLabel({ running: true, done: 2 }), '2 done');
assert.equal(ctx.noteLabel({ running: true, working: 3 }), '3 working');
assert.equal(ctx.noteLabel({ running: true }), '');
assert.equal(ctx.noteLabel({ running: false, blocked: 1 }), '');
assert.equal(ctx.agentColor('idle'), 'FG@0.78');
set({ appStale: true }); assert.equal(ctx.badgeColor(), 'URGENT', 'stale is never green');
set({ appStale: true, doneCount: 2 }); assert.equal(ctx.badgeColor(), 'URGENT');
console.log('PASS: priority and the colours it drives');

// Text size
const writes = [];
ctx.textFile = { setText: (t) => writes.push(t) };
ctx.textScale = 1.0;
for (let i = 0; i < 20; i++) ctx.textBigger();
assert.equal(ctx.textScale, 1.6, 'clamped at the top');
for (let i = 0; i < 20; i++) ctx.textSmaller();
assert.equal(ctx.textScale, 0.8, 'clamped at the bottom');
ctx.textReset(); assert.equal(ctx.textScale, 1);
for (let i = 0; i < 20; i++) { ctx.textBigger(); ctx.textSmaller(); }
assert.equal(ctx.textScale, 1, 'no drift after 20 steps');
ctx.textBigger(); assert.equal(ctx.textScale, 1.1);
assert.equal(writes.at(-1), '1.1', 'a press writes the size');
for (const bad of ['', 'abc', '1.5abc', '2', '0.5', 'NaN', '-1']) {
  ctx.textScale = 1.2; ctx.applyTextScale(bad);
  assert.equal(ctx.textScale, 1.2, `ignored: ${JSON.stringify(bad)}`);
}
const before = writes.length;
ctx.applyTextScale('1.4\n'); assert.equal(ctx.textScale, 1.4);
assert.equal(writes.length, before, 'a load never writes');
assert.match(source, /onLoaded: root\.textFileLoaded\(text\(\)\)/);
assert.match(source, /watchChanges: true[^]*?onFileChanged: reload\(\)/);
console.log('PASS: text steps clamp, never drift, ignore garbage and do not write on load');

// Blink episodes
const sessions = (...rows) => rows.map(([name, pane, status, seq]) =>
  ({ name, agentList: [{ pane, status, seq }] }));
const reset = () => { Object.assign(ctx.root, { attentionKey: '', wantingBefore: {}, attentionPrimed: true,
  blinkExpired: false }); Object.assign(ctx.blinkTimer, { restarts: 0, stops: 0 }); };
assert.match(source, /id: blinkTimer\s+interval: 60000\s+onTriggered: root\.blinkExpired = true/);
reset();
ctx.updateAttention(sessions(['a', 'w1:p1', 'blocked', 1]));
assert.equal(ctx.blinkTimer.restarts, 1, 'a new key starts an episode');
assert.equal(ctx.blinking({ name: 'a' }, { pane: 'w1:p1' }), true);
ctx.root.blinkExpired = true;                       // what the timer does at 60 s
assert.equal(ctx.blinking({ name: 'a' }, { pane: 'w1:p1' }), false, 'expired: no blink');
ctx.updateAttention(sessions(['a', 'w1:p1', 'blocked', 1]));
assert.equal(ctx.blinkTimer.restarts, 1, 'an unchanged poll does not restart it');
assert.equal(ctx.root.blinkExpired, true);
ctx.updateAttention(sessions(['a', 'w1:p1', 'blocked', 1], ['b', 'w2:p1', 'done', 2]));
assert.equal(ctx.blinkTimer.restarts, 2, 'a new episode restarts it');
assert.equal(ctx.root.blinkExpired, false);
assert.equal(ctx.blinking({ name: 'b' }, { pane: 'w2:p1' }), true);
const stops = ctx.blinkTimer.stops;
ctx.updateAttention(sessions(['a', 'w1:p1', 'idle', 1], ['b', 'w2:p1', 'idle', 2]));
assert.equal(ctx.root.attentionKey, '');
assert.ok(ctx.blinkTimer.stops > stops, 'clearing stops the timer');
console.log('PASS: blink episodes expire, restart on a new key, stop on clear');

// showRow gets the agent index
ctx.showCalls = [];
ctx.showRow = (si, ai) => ctx.showCalls.push([si, ai]);
Object.assign(ctx, { sessions: [{ name: 'a', agentList: [{ pane: 'p1' }, { pane: 'p2' }] }],
  cursor: 0, cursorPlaced: true });
Object.defineProperty(ctx, 'navRows', { get: () => ctx.navRowsFor(ctx.sessions), configurable: true });
ctx.moveCursor(1);
assert.deepEqual(ctx.showCalls.at(-1), [0, 1], 'moveCursor passes the agent index');
assert.equal((source.match(/showRow\([a-z.]*\.sessionIndex, [a-z.]*\.agentIndex\)/g) || []).length, 3,
  'rebuild (twice) and moveCursor pass the agent index');
assert.match(source, /function showRow\(sessionIndex, agentIndex\)/);
console.log('PASS: showRow callers pass the agent index');

// Tooltip
set({ runningCount: 2, agentCount: 3, blockedCount: 1, doneCount: 1, workingCount: 1 });
assert.equal(ctx.tooltipText(), '2 herdr servers, 3 agents, 1 waiting on you, 1 finished, 1 working');
set({ appStale: true, agentCount: 1 });
assert.equal(ctx.tooltipText(), '1 agent, herdr-core not reachable');
set({ reachable: false, errorText: 'boom', agentCount: 2, blockedCount: 1 });
assert.equal(ctx.tooltipText(), 'Herdr: boom, 2 agents, 1 waiting on you');
set({}); assert.equal(ctx.tooltipText(), 'Herdr: no sessions');
console.log('PASS: the tooltip lists every non-zero part and the failures');

// togglePin forwards the keyboard flag
{
  const got = [];
  ctx.host = { togglePin: (v) => got.push(v) };
  ctx.togglePin(true); ctx.togglePin(false); ctx.togglePin();
  assert.deepEqual(got, [true, false, false]);
}
console.log('PASS: togglePin(true) reaches the host as true');

// The columns are gone
assert.doesNotMatch(source, /columnRow|columnOpen|columnDestroy|lastColumnFor|moveColumn|cycleColumn|clampColumn|cursorInBody|\bcolumn\b\s*[=!]/);
assert.doesNotMatch(source, /Qt\.darker/);
assert.ok(fs.existsSync(`${__dirname}/../ConfirmOverlay.qml`));
console.log('PASS: no column cursor, no Qt.darker, ConfirmOverlay exists');

// A change during an in-flight read is queued and read once it finishes.
{
  const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
  const src = fs.readFileSync(`${__dirname}/../HerdrModel.qml`, 'utf8');
  const ctx = { textReading: true, textReadAgain: false, applied: [], reloads: 0,
    textFile: { reload() { ctx.reloads++ } }, applyTextScale(t) { ctx.applied.push(t) } };
  vm.createContext(ctx);
  for (const n of ['textFileChanged', 'textFileLoaded'])
    vm.runInContext(src.match(new RegExp('  function ' + n + '\\([^]*?\\n  \\}'))[0], ctx);
  ctx.textFileChanged();                 // change while the first read is out
  assert.equal(ctx.reloads, 0, 'no reload while reading');
  ctx.textFileLoaded('1.1');             // stale read lands
  assert.equal(ctx.reloads, 1, 'the queued change is read');
  ctx.textFileLoaded('1.2');
  assert.deepEqual(ctx.applied, ['1.1', '1.2'], 'the final value is applied last');
  ctx.textFileChanged(); assert.equal(ctx.reloads, 2, 'an idle change reloads at once');
  ctx.textFileLoaded(null); assert.equal(ctx.textReading, false, 'a failed load clears the flag');
  console.log('PASS: a change during a read is queued');
}
