const { test } = require('node:test');
const assert = require('node:assert/strict');
const { resolve, toolbarSize, safeBounds, fitAspectRect, compareButton, originalWindow } = require('../dist/demo/capture-layout.js');

const bounds = { x: 8, y: 35, w: 984, h: 657 };
const right = r => r.x + r.w;
const bottom = r => r.y + r.h;
const intersection = (a, b) => Math.max(0, Math.min(right(a), right(b)) - Math.max(a.x, b.x)) * Math.max(0, Math.min(bottom(a), bottom(b)) - Math.max(a.y, b.y));
function usable(result, region = bounds) {
  for (const rect of [result.toolbar, result.composer]) {
    assert.ok(rect.x >= region.x && rect.y >= region.y, JSON.stringify(result));
    assert.ok(right(rect) <= right(region) + 1e-7 && bottom(rect) <= bottom(region) + 1e-7, JSON.stringify(result));
  }
  assert.equal(intersection(result.toolbar, result.composer), 0, JSON.stringify(result));
  const separated = right(result.toolbar) + 12 <= result.composer.x || right(result.composer) + 12 <= result.toolbar.x || bottom(result.toolbar) + 12 <= result.composer.y || bottom(result.composer) + 12 <= result.toolbar.y;
  assert.ok(separated, `Controls need a 12px gap: ${JSON.stringify(result)}`);
  assert.equal(result.composer.h, 46);
  assert.ok(result.composer.w >= Math.min(320, region.w - result.toolbar.w - 12) && result.composer.w <= 480);
}

test('toolbar geometry matches actual native-sized button stacks', () => {
  assert.deepEqual(toolbarSize('work', true), { w: 50, h: 300 });
  assert.deepEqual(toolbarSize('translate', true), { w: 50, h: 350 });
  assert.deepEqual(toolbarSize('ask', false), { w: 50, h: 100 });
  assert.deepEqual(toolbarSize('work', false), { w: 50, h: 50 });
});

test('small Work selection keeps every annotation button and the input accessible', () => {
  const selection = { x: 340, y: 260, w: 64, h: 42 };
  const result = resolve(selection, { kind: 'work', expanded: true });
  usable(result);
  assert.equal(intersection(result.toolbar, selection), 0);
  assert.equal(intersection(result.composer, selection), 0);
  assert.equal(result.composer.w, 480, 'A small selection leaves enough room for the full input.');
});

test('normal reading selection retains adjacent tools and the input below it', () => {
  const selection = { x: 80, y: 278, w: 510, h: 130 };
  const result = resolve(selection, { kind: 'translate', expanded: false });
  usable(result);
  assert.equal(result.toolbar.x, right(selection) + 12);
  assert.equal(result.composer.y, bottom(selection) + 14);
  assert.equal(result.composer.w, 480);
});

test('edge, corner, bottom and almost-full-canvas selections remain usable', () => {
  const selections = [
    { x: 0, y: 27, w: 35, h: 35 },
    { x: 965, y: 27, w: 35, h: 35 },
    { x: 0, y: 658, w: 42, h: 42 },
    { x: 958, y: 658, w: 42, h: 42 },
    { x: 450, y: 645, w: 100, h: 55 },
    { x: 20, y: 300, w: 950, h: 330 },
    { x: 0, y: 27, w: 1000, h: 673 },
  ];
  for (const selection of selections) for (const kind of ['work', 'translate']) for (const expanded of [false, true]) usable(resolve(selection, { kind, expanded }));
});

test('small selections at either edge do not need to be obscured', () => {
  for (const selection of [{ x: 0, y: 280, w: 45, h: 55 }, { x: 955, y: 280, w: 45, h: 55 }, { x: 490, y: 655, w: 45, h: 45 }]) {
    const result = resolve(selection, { kind: 'work', expanded: true });
    usable(result);
    assert.equal(intersection(result.toolbar, selection), 0);
    assert.equal(intersection(result.composer, selection), 0);
  }
});

test('layout invariants survive a grid of selection positions and sizes', () => {
  for (const x of [0, 80, 340, 720, 960]) for (const y of [27, 120, 310, 560, 670]) {
    for (const desiredWidth of [24, 70, 420, 1000]) for (const desiredHeight of [24, 60, 300, 673]) {
      const selection = { x, y, w: Math.min(desiredWidth, 1000 - x), h: Math.min(desiredHeight, 700 - y) };
      for (const kind of ['work', 'ask']) for (const expanded of [false, true]) usable(resolve(selection, { kind, expanded }));
    }
  }
});


test('cropped desktop and mobile viewports constrain every control to the visible canvas', () => {
  const viewports = [
    { x: 0, y: 49, w: 840, h: 595 },
    { x: 60, y: 0, w: 602, h: 700 },
    { x: 398, y: 0, w: 602, h: 700 },
    { x: 400, y: 0, w: 300, h: 700 },
  ];
  for (const viewport of viewports) {
    const region = safeBounds(viewport);
    for (const selection of [
      { x: 280, y: 230, w: 55, h: 38 },
      { x: 80, y: 278, w: 510, h: 130 },
      { x: 20, y: 450, w: 960, h: 240 },
      { x: 0, y: 27, w: 1000, h: 673 },
    ]) for (const kind of ['work', 'translate']) for (const expanded of [false, true]) {
      usable(resolve(selection, { kind, expanded, bounds: region }), region);
    }
  }
});

test('the smallest accepted viewport keeps expanded controls accessible', () => {
  for (const viewport of [{ x: 400, y: 100, w: 300, h: 350 }, { x: 250, y: 60, w: 360, h: 380 }]) {
    const region = safeBounds(viewport);
    for (const kind of ['work', 'translate']) for (const selection of [
      { x: region.x, y: region.y, w: 24, h: 24 },
      { x: region.x + 120, y: region.y + 120, w: 90, h: 70 },
      { ...region },
    ]) usable(resolve(selection, { kind, expanded: true, bounds: region }), region);
  }
});

test('Original popup fits the visible canvas and never covers Compare', () => {
  for (const viewport of [{ x: 0, y: 49, w: 840, h: 595 }, { x: 60, y: 0, w: 602, h: 700 }]) {
    const region = safeBounds(viewport);
    for (const selection of [
      { x: 80, y: 278, w: 510, h: 130 },
      { x: 180, y: 40, w: 480, h: 190 },
      { x: 320, y: 570, w: 240, h: 105 },
      { x: 0, y: 27, w: 1000, h: 673 },
    ]) {
      const compare = compareButton(selection, region);
      const popup = originalWindow(selection, region, compare);
      assert.equal(intersection(compare, popup), 0, JSON.stringify({ compare, popup }));
      assert.ok(popup.x >= region.x && popup.y >= region.y);
      assert.ok(right(popup) <= right(region) + 1e-7 && bottom(popup) <= bottom(region) + 1e-7);
      assert.ok(Math.abs(popup.w / popup.h - selection.w / selection.h) < 1e-7);
    }
  }
});

test('viewport resize preserves the Original aspect ratio and fits it without enlarging', () => {
  const before = { x: 780, y: 540, w: 420, h: 220 };
  const region = safeBounds({ x: 60, y: 0, w: 602, h: 700 });
  const after = fitAspectRect(before, region);
  assert.equal(after.w, before.w);
  assert.equal(after.h, before.h);
  assert.ok(right(after) <= right(region) && bottom(after) <= bottom(region));
  const reduced = fitAspectRect({ x: 0, y: 0, w: 900, h: 600 }, region);
  assert.ok(reduced.w < 900);
  assert.ok(Math.abs(reduced.w / reduced.h - 1.5) < 1e-7);
});
