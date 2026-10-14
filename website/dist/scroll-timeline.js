(function (root, factory) {
  const timeline = factory();
  if (typeof module === 'object' && module.exports) module.exports = timeline;
  else root.MarrScrollTimeline = timeline;
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';

  const EDGE_HOLD = .05;
  const ACTIVE_RANGE = 1 - EDGE_HOLD * 2;
  const BEAT_ACTION = .8;
  const clamp = value => Math.max(0, Math.min(1, Number.isNaN(value) ? 0 : value));

  function checkCount(count) {
    if (!Number.isInteger(count) || count < 1) throw new RangeError('A timeline needs at least one step.');
    return count;
  }

  function stepIndex(index, count) {
    return Math.max(0, Math.min(count - 1, Math.floor(Number.isFinite(index) ? index : 0)));
  }

  // The first and last 5% hold the composition. Each equal-sized beat reaches
  // its result before the boundary, allowing reading and stable step seeking.
  function sample(progress, count) {
    checkCount(count);
    const overall = clamp(progress);
    const position = clamp((overall - EDGE_HOLD) / ACTIVE_RANGE) * count;
    const index = Math.min(count - 1, Math.floor(position));
    return { index, local: clamp((position - index) / BEAT_ACTION), overall };
  }

  function position(index, local, count) {
    checkCount(count);
    const step = stepIndex(index, count);
    const progress = clamp(local);
    // Completed steps seek to the center of their hold, not the next step.
    const offset = progress === 1 ? (BEAT_ACTION + 1) / 2 : progress * BEAT_ACTION;
    const result = EDGE_HOLD + (step + offset) / count * ACTIVE_RANGE;
    // Compensate only for arithmetic rounding at the start of a beat. This
    // keeps reverse seeks on the intended step without a visible progress jump.
    return progress === 0 && step > 0 ? result + Number.EPSILON : result;
  }

  function advance(index, local, delta, durations) {
    if (!Array.isArray(durations) || !durations.length || durations.some(value => !Number.isFinite(value) || value <= 0)) {
      throw new RangeError('Every timeline step needs a positive duration.');
    }
    let step = stepIndex(index, durations.length);
    const elapsed = Number.isFinite(delta) ? Math.max(0, delta) : 0;
    let remaining = clamp(local) * durations[step] + elapsed;
    // A completed page starts the next beat even when its first frame has a
    // zero delta. It never redraws the selected page from the beginning.
    while (step < durations.length - 1 && remaining >= durations[step]) {
      remaining -= durations[step];
      step++;
    }
    const ended = step === durations.length - 1 && remaining >= durations[step];
    return { index: step, local: clamp(remaining / durations[step]), ended };
  }

  function visibility(top, bottom, viewportHeight, header = 60) {
    if (![top, bottom, viewportHeight, header].every(Number.isFinite)) return 0;
    const viewportTop = Math.max(0, Math.min(viewportHeight, header));
    const usableHeight = viewportHeight - viewportTop;
    const elementHeight = bottom - top;
    if (usableHeight <= 0 || elementHeight <= 0) return 0;
    const visibleHeight = Math.max(0, Math.min(bottom, viewportHeight) - Math.max(top, viewportTop));
    return clamp(visibleHeight / Math.min(elementHeight, usableHeight));
  }

  return Object.freeze({ sample, position, advance, visibility });
});
