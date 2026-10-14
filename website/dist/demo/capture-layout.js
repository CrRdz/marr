(function (root, factory) {
  const layout = factory();
  if (typeof module === 'object' && module.exports) module.exports = layout;
  else root.MarrCaptureLayout = layout;
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';

  // These dimensions match demo.css, including the toolbar's 4px outer padding.
  const METRICS = Object.freeze({ button: 42, buttonGap: 8, toolbarPadding: 4, composerHeight: 46, composerWidth: 480, minimumComposerWidth: 320, controlGap: 12 });
  const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
  const right = rect => rect.x + rect.w;
  const bottom = rect => rect.y + rect.h;
  const overlap = (a, b) => Math.max(0, Math.min(right(a), right(b)) - Math.max(a.x, b.x)) * Math.max(0, Math.min(bottom(a), bottom(b)) - Math.max(a.y, b.y));
  const distance = (a, b) => Math.max(0, a.x - right(b), b.x - right(a)) + Math.max(0, a.y - bottom(b), b.y - bottom(a));
  const unique = values => [...new Set(values)];

  function safeBounds(raw = { x: 0, y: 27, w: 1000, h: 673 }) {
    const x = clamp(raw.x, 0, 1000), y = clamp(raw.y, 0, 700);
    const width = Math.max(1, Math.min(1000, right(raw)) - x);
    const height = Math.max(1, Math.min(700, bottom(raw)) - y);
    const padX = Math.min(12, Math.max(0, (width - 300) / 2));
    const padY = Math.min(12, Math.max(0, (height - 350) / 2));
    return { x: x + padX, y: y + padY, w: width - padX * 2, h: height - padY * 2 };
  }

  function fitAspectRect(rect, bounds) {
    const scale = Math.min(1, bounds.w / rect.w, bounds.h / rect.h);
    const w = rect.w * scale, h = rect.h * scale;
    return { x: clamp(rect.x, bounds.x, right(bounds) - w), y: clamp(rect.y, bounds.y, bottom(bounds) - h), w, h };
  }

  function compareButton(selection, bounds) {
    const w = 104, h = 32;
    const below = bottom(selection) + 10, above = selection.y - h - 10;
    return {
      x: clamp(selection.x + selection.w / 2 - w / 2, bounds.x, right(bounds) - w),
      y: below + h <= bottom(bounds) ? Math.max(bounds.y, below) : clamp(above, bounds.y, bottom(bounds) - h), w, h
    };
  }

  function originalWindow(selection, bounds, avoid = compareButton(selection, bounds), requestedSize = selection) {
    const gap = 12, size = fitAspectRect(requestedSize, bounds), candidates = [];
    const add = (rect, region = bounds) => {
      if (region.w < 1 || region.h < 1) return;
      const candidate = fitAspectRect(rect, region);
      if (overlap(candidate, { x: avoid.x - gap, y: avoid.y - gap, w: avoid.w + gap * 2, h: avoid.h + gap * 2 }) > 0) return;
      candidates.push(candidate);
    };
    add({ x: selection.x - size.w - gap, y: selection.y, w: size.w, h: size.h });
    add({ x: right(selection) + gap, y: selection.y, w: size.w, h: size.h });
    add({ x: selection.x, y: selection.y - size.h - gap, w: size.w, h: size.h });
    add({ x: selection.x, y: Math.max(bottom(selection), bottom(avoid)) + gap, w: size.w, h: size.h });
    // A large screenshot can still fit beside the Compare control by scaling as a whole.
    for (const region of [
      { x: bounds.x, y: bounds.y, w: bounds.w, h: avoid.y - gap - bounds.y },
      { x: bounds.x, y: bottom(avoid) + gap, w: bounds.w, h: bottom(bounds) - bottom(avoid) - gap },
      { x: bounds.x, y: bounds.y, w: avoid.x - gap - bounds.x, h: bounds.h },
      { x: right(avoid) + gap, y: bounds.y, w: right(bounds) - right(avoid) - gap, h: bounds.h }
    ]) add(size, region);
    const score = rect => overlap(rect, selection) * .03 + (size.w - rect.w) * 2 + distance(rect, selection) * .1;
    candidates.sort((a, b) => score(a) - score(b));
    return candidates[0] || size;
  }

  function toolbarSize(kind, expanded) {
    const count = (kind === 'work' ? 1 : 2) + (expanded ? 5 : 0);
    return {
      w: METRICS.button + METRICS.toolbarPadding * 2,
      h: count * METRICS.button + (count - 1) * METRICS.buttonGap + METRICS.toolbarPadding * 2
    };
  }

  function resolve(selection, { kind = 'translate', expanded = false, bounds = safeBounds() } = {}) {
    const size = toolbarSize(kind, expanded);
    const gap = METRICS.controlGap;
    // A short, narrow viewport may have no room above or below an expanded stack.
    // Keep the native buttons intact and let the input share its row at a smaller width.
    const minimumComposerWidth = Math.min(METRICS.minimumComposerWidth, bounds.w - size.w - gap);
    const center = selection.x + selection.w / 2;
    const desiredToolY = clamp(expanded ? selection.y : selection.y + selection.h / 2 - size.h / 2, bounds.y, bottom(bounds) - size.h);
    const toolXs = unique([right(selection) + gap, selection.x - gap - size.w, right(bounds) - size.w, bounds.x].map(x => clamp(x, bounds.x, right(bounds) - size.w)));
    const toolYs = unique([desiredToolY, bottom(selection) - size.h, selection.y - gap - size.h, bottom(selection) + gap, bounds.y, bottom(bounds) - size.h].map(y => clamp(y, bounds.y, bottom(bounds) - size.h)));
    let best;

    for (const x of toolXs) for (const y of toolYs) {
      const toolbar = { x, y, ...size };
      const composerYs = unique([bottom(selection) + 14, selection.y - 14 - METRICS.composerHeight, bottom(toolbar) + gap, toolbar.y - gap - METRICS.composerHeight, bottom(bounds) - METRICS.composerHeight, bounds.y].map(value => clamp(value, bounds.y, bottom(bounds) - METRICS.composerHeight)));
      for (const composerY of composerYs) {
        // If the rows intersect, reserve the toolbar's entire width plus breathing room.
        // This makes a collision impossible, including after clamping near canvas edges.
        const sharesRow = composerY < bottom(toolbar) + gap && composerY + METRICS.composerHeight > toolbar.y - gap;
        const intervals = sharesRow
          ? [[bounds.x, toolbar.x - gap], [right(toolbar) + gap, right(bounds)]]
          : [[bounds.x, right(bounds)]];
        for (const [left, end] of intervals) {
          const width = Math.min(METRICS.composerWidth, end - left);
          if (width < minimumComposerWidth) continue;
          const composer = { x: clamp(center - width / 2, left, end - width), y: composerY, w: width, h: METRICS.composerHeight };
          const covered = overlap(toolbar, selection) + overlap(composer, selection);
          const score = distance(toolbar, selection) + distance(composer, selection)
            + Math.abs(toolbar.y - desiredToolY) * .18
            + Math.abs(composer.x + composer.w / 2 - center) * .35
            + (METRICS.composerWidth - width) * 1.5
            + (toolbar.x < selection.x ? 3 : 0)
            + (composer.y < selection.y ? 6 : 0);
          // Covering the selection is a last resort; among clear layouts, stay nearby.
          if (!best || covered < best.covered || (covered === best.covered && score < best.score)) best = { toolbar, composer, covered, score };
        }
      }
    }
    return { toolbar: best.toolbar, composer: best.composer };
  }

  return Object.freeze({ resolve, toolbarSize, safeBounds, fitAspectRect, compareButton, originalWindow, METRICS });
});
