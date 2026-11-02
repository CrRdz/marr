const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require('node:path').join(__dirname, '../dist/companion.js'), 'utf8');
function setup(reduce = false) {
  const listeners = {}, classes = new Set(), scripts = [], calls = [];
  const element = () => ({hidden:false, textContent:'', attrs:{}, events:{}, setAttribute(k,v){this.attrs[k]=v;},addEventListener(k,f){this.events[k]=f;}});
  const canvas = element(), caption = element(), pause = element();
  const buttons = Array.from({length:6}, (_,i) => Object.assign(element(),{dataset:{tool:String(i)}}));
  const host = {querySelector:s=>s==='canvas'?canvas:pause,querySelectorAll:()=>buttons,classList:{toggle(k,v){v?classes.add(k):classes.delete(k);},remove(k){classes.delete(k);}}};
  const media = {matches:reduce,addEventListener(k,f){listeners.motion=f;}};
  const property = {value:0};
  let observer, options;
  const document = {hidden:false,querySelector:()=>host,getElementById:()=>caption,createElement:()=>({}),head:{append:s=>scripts.push(s)},addEventListener:(k,f)=>listeners[k]=f};
  const context = {document,matchMedia:()=>media,devicePixelRatio:1,window:{addEventListener(){}},ResizeObserver:class{observe(){}},IntersectionObserver:class{constructor(f){observer=f;}observe(){}},rive:{RuntimeLoader:{setWasmUrl(){},setWasmFallbackUrl(){}},Layout:class{},Fit:{Contain:1},Alignment:{Center:1},Rive:class{constructor(o){options=o;this.viewModelInstance={number:()=>property};}play(){calls.push('play');}pause(){calls.push('pause');}cleanup(){calls.push('cleanup');}resizeDrawingSurfaceToCanvas(){}}}};
  vm.runInNewContext(source,context);
  return {scripts,calls,buttons,pause,classes,property,media,listeners,document,caption,view:v=>observer([{isIntersecting:v}]),load(){scripts[0].onload();options.onLoad();}};
}
test('companion loads lazily and pauses offscreen or in background',()=>{
 const s=setup(); assert.equal(s.scripts.length,0); s.view(true); assert.equal(s.scripts.length,1);s.load();assert.equal(s.calls.at(-1),'play');s.view(false);assert.equal(s.calls.at(-1),'pause');s.view(true);s.document.hidden=true;s.listeners.visibilitychange();assert.equal(s.calls.at(-1),'pause');assert.equal(s.scripts.length,1);
});
test('reduced motion does not download Rive; changing preference restores it',()=>{
 const s=setup(true);s.view(true);assert.equal(s.scripts.length,0);s.media.matches=false;s.listeners.motion();s.load();assert.ok(s.classes.has('is-ready'));s.media.matches=true;s.listeners.motion();assert.equal(s.calls.at(-1),'pause');assert.ok(!s.classes.has('is-ready'));
});
test('tool selection binds to Rive and explicit pause persists across visibility changes',()=>{
 const s=setup();s.view(true);s.load();s.buttons[2].events.click();assert.equal(s.property.value,2);assert.equal(s.buttons[2].attrs['aria-pressed'],'true');s.pause.events.click();assert.equal(s.calls.at(-1),'pause');assert.ok(s.classes.has('is-ready'));s.view(false);s.view(true);assert.equal(s.calls.at(-1),'pause');s.pause.events.click();assert.equal(s.calls.at(-1),'play');
});
test('runtime download failure keeps the static fallback',()=>{
 const s=setup();s.view(true);s.scripts[0].onerror();assert.ok(!s.classes.has('is-ready'));assert.ok(s.pause.hidden);assert.match(s.caption.textContent,/暂不可用/);
});
