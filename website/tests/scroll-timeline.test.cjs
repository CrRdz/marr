const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { sample, position, advance, visibility } = require('../dist/scroll-timeline.js');

function close(actual, expected, tolerance = 1e-10) {
  assert.ok(Math.abs(actual - expected) <= tolerance, `Expected ${actual} to be near ${expected}`);
}

test('scroll starts and finishes with a composition hold', () => {
  for (const progress of [-1, 0, .025, .05]) {
    const frame = sample(progress, 5);
    assert.equal(frame.index, 0);
    assert.equal(frame.local, 0);
  }
  for (const progress of [.95, .975, 1, 2]) {
    const frame = sample(progress, 5);
    assert.equal(frame.index, 4);
    assert.equal(frame.local, 1);
  }
  assert.equal(sample(-1, 5).overall, 0);
  assert.equal(sample(2, 5).overall, 1);
});

test('each beat finishes its action with room to read before the next step', () => {
  const count = 5, beat = .9 / count;
  for (let index = 0; index < count; index++) {
    for (const offset of [.81, .9, .99]) {
      const frame = sample(.05 + (index + offset) * beat, count);
      assert.equal(frame.index, index);
      assert.equal(frame.local, 1);
    }
  }
});

test('scrolling forward and backward is deterministic, including across step boundaries', () => {
  const progress = Array.from({ length: 1001 }, (_, i) => i / 1000);
  const forward = progress.map(value => sample(value, 5));
  const backward = [...progress].reverse().map(value => sample(value, 5)).reverse();
  assert.deepEqual(backward, forward);
  for (let i = 1; i < forward.length; i++) {
    const previous = forward[i - 1], current = forward[i];
    assert.ok(current.index + current.local >= previous.index + previous.local - 1e-10);
  }
});

test('seeking round-trips to the selected page and local progress', () => {
  for (const count of [1, 2, 4, 5, 11]) {
    for (let index = 0; index < count; index++) {
      for (const local of [0, .001, .14, .52, .8, .999, 1]) {
        const sought = position(index, local, count);
        const frame = sample(sought, count);
        assert.equal(frame.index, index, JSON.stringify({ count, index, local, sought, frame }));
        close(frame.local, local);
      }
    }
  }
});

test('a completed page resumes into the next page without replaying its action', () => {
  assert.deepEqual(advance(2, 1, 0, [2400, 3500, 3500, 5200]), { index: 3, local: 0, ended: false });
  const frame = advance(2, 1, 80, [2400, 3500, 3500, 5200]);
  assert.equal(frame.index, 3);
  close(frame.local, 80 / 5200);
  assert.equal(frame.ended, false);
});

test('pause and resume retain the current action progress', () => {
  const durations = [1000, 2000, 3000];
  assert.deepEqual(advance(1, .4, 0, durations), { index: 1, local: .4, ended: false });
  assert.deepEqual(advance(1, .4, 200, durations), { index: 1, local: .5, ended: false });
  assert.deepEqual(advance(1, .4, -200, durations), { index: 1, local: .4, ended: false });
});

test('long frames can cross several steps and stop at the last result', () => {
  const durations = [1000, 2000, 3000];
  assert.deepEqual(advance(0, .5, 3000, durations), { index: 2, local: 1 / 6, ended: false });
  assert.deepEqual(advance(0, 0, 6000, durations), { index: 2, local: 1, ended: true });
  assert.deepEqual(advance(0, 0, 60000, durations), { index: 2, local: 1, ended: true });
  assert.deepEqual(advance(2, 1, 80, durations), { index: 2, local: 1, ended: true });
  assert.deepEqual(advance(0, 1, 0, [1000]), { index: 0, local: 1, ended: true });
  assert.deepEqual(durations, [1000, 2000, 3000]);
});

test('visibility excludes the fixed header and offscreen content', () => {
  assert.equal(visibility(60, 560, 800), 1);
  assert.equal(visibility(-440, 60, 800), 0);
  assert.equal(visibility(800, 1300, 800), 0);
  assert.equal(visibility(-190, 310, 800), .5);
  assert.equal(visibility(550, 1050, 800), .5);
  assert.equal(visibility(0, 60, 800), 0);
});

test('oversized content uses the usable viewport as the visibility denominator', () => {
  assert.equal(visibility(-100, 1000, 800), 1);
  close(visibility(430, 1430, 800), .5);
  assert.equal(visibility(0, 800, 800, 0), 1);
  close(visibility(393, 1133, 800), .55);
  assert.ok(visibility(394, 1134, 800) < .55);
});

test('invalid geometry is invisible and invalid timelines fail without looping', () => {
  for (const args of [[10, 10, 800], [20, 10, 800], [0, 100, 60], [NaN, 100, 800], [0, Infinity, 800]]) {
    assert.equal(visibility(...args), 0);
  }
  for (const count of [0, -1, 1.5, NaN]) assert.throws(() => sample(.5, count), RangeError);
  for (const durations of [[], [0], [-1], [Infinity], [NaN]]) assert.throws(() => advance(0, 0, 100, durations), RangeError);
});

test('the same pure API is available in a browser without CommonJS or DOM globals', () => {
  const context = vm.createContext({});
  vm.runInContext(fs.readFileSync(require.resolve('../dist/scroll-timeline.js'), 'utf8'), context);
  assert.equal(typeof context.MarrScrollTimeline.sample, 'function');
  assert.equal(typeof context.MarrScrollTimeline.position, 'function');
  assert.equal(typeof context.MarrScrollTimeline.advance, 'function');
  assert.equal(typeof context.MarrScrollTimeline.visibility, 'function');
  assert.equal(context.MarrScrollTimeline.sample(.5, 1).index, 0);
});
