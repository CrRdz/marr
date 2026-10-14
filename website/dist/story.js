const clamp = (value, min = 0, max = 1) => Math.min(max, Math.max(min, value));
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const cinemaViewport = matchMedia('(min-width: 541px) and (min-height: 700px)');
const scrollEnabled = () => cinemaViewport.matches && !reduced.matches;
const scenes = {
  flow: [
    {kind: 'translate', phase: 0, title: '只圈出，你想读的。', note: '拖动框选这段英文。', duration: 3800},
    {kind: 'translate', phase: 2, title: '译文，就在原处。', note: '思路不用切换。', duration: 3400},
    {kind: 'translate', phase: 3, title: '对照，一眼明白。', note: '拖动原文，拖角缩放。', duration: 4500},
    {kind: 'ask', phase: 2, title: '有疑问，顺手就问。', note: '截图就是上下文。', duration: 3800},
    {kind: 'ask', phase: 3, title: '接着聊。接着想。', note: '在 Conversation 里继续。', duration: 5200}
  ],
  work: [
    {kind: 'work', phase: 0, title: '从这里，开始。', note: '圈出想调整的界面。', duration: 2400},
    {kind: 'work', phase: 1, title: '重点，圈出来。', note: '方框标出范围。', duration: 3500},
    {kind: 'work', phase: 2, title: '一个箭头，就说清楚。', note: '指向你想改的地方。', duration: 3500},
    {kind: 'work', phase: 3, title: '想法，进入 Work。', note: '带着标注，继续项目中的工作。', duration: 5200}
  ]
};
const symbols = {
  play: '<path d="m9 5 11 7-11 7Z" fill="currentColor" stroke="none"/>',
  pause: '<path d="M9 6v12M15 6v12" stroke-width="3"/>',
  replay: '<path d="M4 10a8 8 0 1 1 1 7M4 4v6h6"/>'
};
const chapters = [...document.querySelectorAll('.chapter')].map(el => ({
  el, frame: el.querySelector('iframe'), kind: el.dataset.kind,
  phase: -1, ready: false, manual: false, playing: false,
  driver: scrollEnabled() ? 'scroll' : 'selected', followsScroll: true,
  inView: false, lastLocal: 0, lastSent: -1, lastFrame: 0, ended: false
}));
const send = (c, data) => c.frame.contentWindow?.postMessage(data, location.origin);
// Floating controls stay inside the presentation area, including when the
// mobile view zooms in on a single window. Page scrolling does not change it.
function syncBounds(c, force = false) {
  if (!c.ready) return;
  const stage = c.el.querySelector('.stage').getBoundingClientRect();
  const frame = c.frame.getBoundingClientRect();
  if (!frame.width || !stage.height) return;
  const scale = frame.width / 1000;
  const x = clamp((stage.left - frame.left) / scale, 0, 1000);
  const y = clamp((stage.top - frame.top) / scale, 0, 700);
  const right = clamp((stage.right - frame.left) / scale, x, 1000);
  const bottom = clamp((stage.bottom - frame.top) / scale, y, 700);
  const bounds = {x, y, w: right - x, h: bottom - y};
  const key = Object.values(bounds).map(Math.round).join(':');
  if (force || key !== c.boundsKey) {
    c.boundsKey = key;
    send(c, {type: 'marr-demo-bounds', bounds});
  }
}
function focusWindow(c, panel) {
  c.el.style.setProperty('--mobile-pan', panel ? '-52%' : '-6%');
  c.el.style.setProperty('--desktop-pan', panel ? '0%' : '16%');
  requestAnimationFrame(() => syncBounds(c));
}
function playbackUI(c) {
  const button = c.el.querySelector('.play-story');
  button.setAttribute('aria-label', c.playing ? '暂停演示' : c.ended ? '重新播放演示' : '播放演示');
  button.setAttribute('aria-pressed', String(c.playing));
  button.querySelector('svg').innerHTML = symbols[c.playing ? 'pause' : c.ended ? 'replay' : 'play'];
  c.el.classList.toggle('is-playing', c.playing);
  c.el.classList.toggle('is-scroll-driven', c.driver === 'scroll' && scrollEnabled());
  c.el.dataset.driver = c.manual ? 'manual' : c.driver;
  c.el.querySelector('.follow-scroll').hidden = !scrollEnabled() || c.driver === 'scroll' || c.manual;
  c.el.querySelector('.scroll-cue').innerHTML = c.manual ? '随时向下，继续探索 <span aria-hidden="true">↓</span>'
    : c.driver === 'scroll' && scrollEnabled() ? '向下推进，向上回看 <span aria-hidden="true">↕</span>'
    : '随时向下，继续探索 <span aria-hidden="true">↓</span>';
}
function render(c, index, local = 1) {
  const changed = index !== c.phase;
  const scene = scenes[c.kind][index];
  c.phase = index;c.lastLocal = local;
  if (changed) {
    c.lastSent = -1;
    c.el.querySelector('.step-title').textContent = scene.title;
    c.el.querySelector('.step-note').textContent = scene.note;
    c.el.querySelector('.chapter-counter').textContent = `${String(index + 1).padStart(2, '0')} / ${String(scenes[c.kind].length).padStart(2, '0')}`;
    c.el.querySelectorAll('[data-step]').forEach(b => {
      const active = +b.dataset.step === index;
      b.setAttribute('aria-pressed', String(active));
      b.style.setProperty('--progress', active ? local : 0);
    });
    const panelVisible = (scene.kind === 'ask' || scene.kind === 'work') && scene.phase === 3;
    focusWindow(c, panelVisible);
    if (!reduced.matches) {
      c.captionAnimation?.cancel();
      c.captionAnimation = c.el.querySelector('.scene-caption').animate(
        [{opacity: .3, transform: 'translateY(6px)'}, {opacity: 1, transform: 'translateY(0)'}],
        {duration: 240, easing: 'cubic-bezier(.2,.7,.3,1)'}
      );
    }
  }
  c.el.querySelector(`[data-step="${index}"]`).style.setProperty('--progress', local);
  if (!c.ready || c.manual || (!changed && Math.abs(local - c.lastSent) < .018)) return;
  // Each action completes early in its beat, leaving time to read the result.
  const action = clamp((local - .14) / .38);
  const selecting = c.kind === 'flow' && index === 0 && local > .14;
  send(c, {
    type: 'marr-story', kind: scene.kind, phase: selecting ? 1 : scene.phase,
    progress: c.kind === 'work' ? scene.phase / 4 + action * .2
      : selecting ? .25 + action * .18
      : scene.kind === 'ask' && scene.phase === 2 ? .5 + action * .18 : .9
  });
  c.lastSent = local;
}
function stop(c) {c.playing = false; c.lastFrame = 0; playbackUI(c);}
function manual(c, on, preserve = false) {
  stop(c);
  c.manual = on;c.followsScroll = !on;c.driver = !on && scrollEnabled() ? 'scroll' : 'selected';
  c.el.classList.toggle('manual', on);
  c.el.querySelector('.try').setAttribute('aria-pressed', String(on));
  c.el.querySelector('.try').innerHTML = on ? '返回演示 <span aria-hidden="true">↙</span>' : '亲手试试 <span aria-hidden="true">↗</span>';
  c.frame.tabIndex = on ? 0 : -1;
  if (!preserve) send(c, {type: 'marr-story-manual', enabled: on, kind: scenes[c.kind][Math.max(0, c.phase)].kind});
  if (!on) {const current = Math.max(0, c.phase);c.phase = -1;render(c, current);}
  playbackUI(c);
  if (!on) schedule();
}
function choose(c, index) {
  if (c.manual) manual(c, false);
  stop(c);c.followsScroll = false;c.driver = 'selected';c.ended = false;
  render(c, index, 1);
  playbackUI(c);
}
function start(c, restart = false) {
  if (c.manual) manual(c, false);
  if (restart || c.ended || (c.phase === scenes[c.kind].length - 1 && c.lastLocal === 1)) {
    c.phase = -1;c.ended = false;render(c, 0, 0);
  }
  c.followsScroll = false;c.driver = 'playback';c.playing = true;c.lastFrame = 0;playbackUI(c);queuePlayback();
}
chapters.forEach(c => {
  const observer = new ResizeObserver(() => syncBounds(c));
  observer.observe(c.el.querySelector('.stage'));observer.observe(c.frame);
  c.frame.addEventListener('transitionend', () => syncBounds(c));
  c.el.querySelector('.try').addEventListener('click', () => manual(c, !c.manual));
  c.el.querySelector('.follow-scroll').addEventListener('click', () => {
    stop(c);c.followsScroll = true;c.driver = 'scroll';c.ended = false;playbackUI(c);schedule();
  });
  c.el.querySelectorAll('[data-step]').forEach(b => b.addEventListener('click', () => choose(c, +b.dataset.step)));
  c.el.querySelector('.steps').addEventListener('keydown', e => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) return;
    e.preventDefault();
    const count = scenes[c.kind].length;
    const index = e.key === 'Home' ? 0 : e.key === 'End' ? count - 1 : clamp(c.phase + (e.key === 'ArrowRight' ? 1 : -1), 0, count - 1);
    choose(c, index);c.el.querySelector(`[data-step="${index}"]`).focus({preventScroll: true});
  });
  c.el.querySelector('.play-story').addEventListener('click', () => c.playing ? stop(c) : start(c));
  c.frame.addEventListener('load', () => {
    c.ready = true;syncBounds(c, true);
    if (!c.manual) {const current = Math.max(0, c.phase);c.phase = -1;render(c, current, c.lastLocal);}
    update();
  });
});
window.addEventListener('message', e => {
  if (e.origin !== location.origin) return;
  const c = chapters.find(c => c.frame.contentWindow === e.source);
  if (!c) return;
  if (e.data?.type === 'marr-window-focus') {
    focusWindow(c, e.data.target === 'panel');
  }
  if (e.data?.type === 'marr-story-interact') manual(c, true, true);
  if (e.data?.type === 'marr-story-ready') {
    c.ready = true;syncBounds(c, true);
    if (!c.manual) {const current = Math.max(0, c.phase);c.phase = -1;render(c, current, c.lastLocal);}
    update();
  }
});
// Native scroll controls the presentation. Explicit steps, playback and hands-on
// interaction take ownership until the user chooses to follow scrolling again.
let playbackFrame = 0;
function queuePlayback() {if (!playbackFrame) playbackFrame = requestAnimationFrame(playback);}
function playback(now) {
  playbackFrame = 0;
  let active = false;
  for (const c of chapters) {
    if (!c.playing || !c.inView || !c.ready || document.hidden) {c.lastFrame = 0;continue;}
    active = true;
    const delta = c.lastFrame ? Math.min(now - c.lastFrame, 80) : 0;c.lastFrame = now;
    const next = MarrScrollTimeline.advance(Math.max(0, c.phase), c.lastLocal, delta, scenes[c.kind].map(scene => scene.duration));
    render(c, next.index, next.local);
    if (next.ended) {c.ended = true;stop(c);}
  }
  if (active) queuePlayback();
}
let scrollFrame = 0;
function update() {
  scrollFrame = 0;
  const h = innerHeight;
  for (const c of chapters) {
    const r = c.el.getBoundingClientRect();
    const stage = c.el.querySelector(".stage").getBoundingClientRect();
    c.inView = MarrScrollTimeline.visibility(stage.top, stage.bottom, h) >= .55;
    if (scrollEnabled() && c.driver === 'scroll' && !c.manual && r.top < h && r.bottom > 0) {
      const progress = clamp(-r.top / Math.max(1, r.height - h));
      const next = MarrScrollTimeline.sample(progress, scenes[c.kind].length);
      render(c, next.index, next.local);
    }
    if (c.inView && c.playing) queuePlayback();
  }
  document.querySelector('.nav').classList.toggle('is-dark', [...document.querySelectorAll('.interlude,.work-intro,.chapter-dark')].some(el => {const r = el.getBoundingClientRect();return r.top <= 60 && r.bottom > 60;}));
  if (!reduced.matches) {
    const inter = document.querySelector('.interlude'), r = inter.getBoundingClientRect();
    const p = scrollEnabled() ? clamp(-r.top / Math.max(1, r.height - h)) : 0;
    const dissolve = clamp((p - .18) / .35);
    const reveal = clamp((p - .38) / .42);
    inter.style.setProperty('--intro-opacity', 1 - dissolve);
    inter.style.setProperty('--intro-shift', `${-30 * dissolve}px`);
    inter.style.setProperty('--work-opacity', reveal);
    inter.style.setProperty('--work-shift', `${28 * (1 - reveal)}px`);
    inter.style.setProperty('--work-scale', .94 + reveal * .06);
  }
}
function schedule() {if (!scrollFrame) scrollFrame = requestAnimationFrame(update);}
addEventListener('scroll', schedule, {passive: true});
addEventListener('resize', () => {schedule();galleryState();});
addEventListener('visibilitychange', () => {if (!document.hidden) queuePlayback();});
function motionModeChanged() {
  for (const c of chapters) {
    if (c.manual) continue;
    stop(c);
    if (c.followsScroll) c.driver = scrollEnabled() ? 'scroll' : 'selected';
    playbackUI(c);
  }
  update();
}
reduced.addEventListener('change', motionModeChanged);
cinemaViewport.addEventListener('change', motionModeChanged);
// The gallery follows native horizontal gestures. Vertical wheels stay vertical.
const gallery = document.querySelector('.highlight-track'), cards = [...gallery.children];
let activeCard = 0, galleryFrame = 0;
function cardTarget(index) {
  const centered = cards[index].offsetLeft - gallery.offsetLeft - (gallery.clientWidth - cards[index].offsetWidth) / 2;
  return clamp(centered, 0, gallery.scrollWidth - gallery.clientWidth);
}
function chooseCard(index) {gallery.scrollTo({left: cardTarget(clamp(index, 0, cards.length - 1)), behavior: reduced.matches ? 'instant' : 'smooth'});}
function galleryState() {
  galleryFrame = 0;
  activeCard = cards.reduce((best, _, i) => Math.abs(cardTarget(i) - gallery.scrollLeft) < Math.abs(cardTarget(best) - gallery.scrollLeft) ? i : best, 0);
  document.querySelectorAll('[data-card]').forEach(b => b.setAttribute('aria-pressed', String(+b.dataset.card === activeCard)));
  document.querySelector('.gallery-prev').disabled = activeCard === 0;
  document.querySelector('.gallery-next').disabled = activeCard === cards.length - 1;
}
gallery.addEventListener('scroll', () => {if (!galleryFrame) galleryFrame = requestAnimationFrame(galleryState);}, {passive: true});
document.querySelectorAll('[data-card]').forEach(b => b.addEventListener('click', () => chooseCard(+b.dataset.card)));
document.querySelector('.gallery-prev').addEventListener('click', () => chooseCard(activeCard - 1));
document.querySelector('.gallery-next').addEventListener('click', () => chooseCard(activeCard + 1));
gallery.addEventListener('keydown', e => {if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {e.preventDefault();chooseCard(activeCard + (e.key === 'ArrowRight' ? 1 : -1));}});
document.querySelectorAll('[data-jump-step]').forEach(a => a.addEventListener('click', e => {
  e.preventDefault();const c = chapters[0];choose(c, +a.dataset.jumpStep);
  c.el.scrollIntoView({behavior: reduced.matches ? 'instant' : 'smooth', block: 'start'});
}));
const observer = new IntersectionObserver(entries => entries.forEach(entry => {
  if (entry.isIntersecting) {entry.target.classList.add('in-view');observer.unobserve(entry.target);}
}), {threshold: .12});
document.querySelectorAll('.section-heading,.feature-intro,.work-intro,.closing>h2').forEach(el => {el.classList.add('reveal');observer.observe(el);});
chapters.forEach(c => {render(c, 0, 0);playbackUI(c);});
galleryState();update();
