(() => {
  'use strict';
  const host = document.querySelector('.companion-demo');
  if (!host) return;
  const canvas = host.querySelector('canvas');
  const caption = document.getElementById('companion-caption');
  const buttons = [...host.querySelectorAll('[data-tool]')];
  const pause = host.querySelector('.motion-toggle');
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const descriptions = ['陪在身边，等一个新想法。', '变成画笔，把重点轻轻标出来。', '换种语言，思路不用换。', '圈出此刻想关注的内容。', '一个箭头，指向想说的地方。', '标上顺序，让重点更清楚。'];
  let player, loaded = false, started = false, visible = false, paused = false, tool = 0;
  const sync = () => {
    if (!loaded) return;
    const still = reduced.matches || paused;
    host.classList.toggle('is-ready', !reduced.matches);
    pause.hidden = reduced.matches;
    pause.setAttribute('aria-pressed', String(paused));
    pause.textContent = paused ? '继续动态效果' : '暂停动态效果';
    if (visible && !document.hidden && !still) player.play();
    else player.pause();
  };
  const fail = () => {
    loaded = false;
    host.classList.remove('is-ready');
    pause.hidden = true;
    caption.textContent = '动态预览暂不可用，先和 Marr 打个照面。';
    player?.cleanup();
  };
  function start() {
    if (started || reduced.matches) return;
    started = true;
    const script = document.createElement('script');
    script.src = 'vendor/rive/rive.js';
    script.onerror = fail;
    script.onload = () => {
      try {
        rive.RuntimeLoader.setWasmUrl('vendor/rive/rive.wasm');
        rive.RuntimeLoader.setWasmFallbackUrl('vendor/rive/rive_fallback.wasm');
        player = new rive.Rive({
          src: 'assets/companion.riv', canvas, artboard: 'Marr Tool',
          stateMachine: 'Companion', autoBind: true, autoplay: false,
          layout: new rive.Layout({fit: rive.Fit.Contain, alignment: rive.Alignment.Center}),
          onLoadError: fail,
          onLoad: () => {
            if (!player.viewModelInstance?.number('tool')) { fail(); return; }
            loaded = true;
            player.viewModelInstance.number('tool').value = tool;
            player.resizeDrawingSurfaceToCanvas(Math.min(devicePixelRatio || 1, 2));
            sync();
          }
        });
      } catch { fail(); }
    };
    document.head.append(script);
  }
  buttons.forEach(button => button.addEventListener('click', () => {
    tool = Number(button.dataset.tool);
    buttons.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    caption.textContent = descriptions[tool];
    if (loaded) player.viewModelInstance.number('tool').value = tool;
  }));
  pause.addEventListener('click', () => { paused = !paused; sync(); });
  reduced.addEventListener('change', () => { if (visible) start(); sync(); });
  document.addEventListener('visibilitychange', sync);
  new ResizeObserver(() => {
    if (loaded) player.resizeDrawingSurfaceToCanvas(Math.min(devicePixelRatio || 1, 2));
  }).observe(canvas);
  new IntersectionObserver(entries => {
    visible = entries[0].isIntersecting;
    if (visible) start();
    sync();
  }, {threshold: 0.05}).observe(host);
  window.addEventListener('pagehide', () => player?.pause());
  window.addEventListener('pageshow', sync);
})();
