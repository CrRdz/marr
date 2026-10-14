const $=s=>document.querySelector(s), desktop=$('#desktop'), viewport=$('#viewport');
let selection=null,start=null,drawing=null,tool=null,mode='translate',translated=false,comparing=false,expanded=false,marks=[],zoom=1,dragOriginal=null;
const clamp=(v,a,b)=>Math.min(b,Math.max(a,v));
let visibleBounds={x:0,y:27,w:1000,h:673};
const controlBounds=()=>MarrCaptureLayout.safeBounds(visibleBounds);
const icons={"compare":"<svg class=\"ui-icon\" viewBox=\"0 0 24 24\" aria-hidden=\"true\"><rect x=\"3\" y=\"5\" width=\"18\" height=\"14\" rx=\"2\"/><path d=\"M12 5v14M8 9l-2 3 2 3M16 9l2 3-2 3\"/></svg>","check":"<svg class=\"ui-icon\" viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"m5 12 4 4L19 6\"/></svg>","chevron":"<svg class=\"ui-icon\" viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"m6 9 6 6 6-6\"/></svg>"};
function setMode(next){
  mode=['ask','work'].includes(next)?next:'translate';
  document.body.classList.toggle('work-scene',mode==='work');
  $('.work-document').hidden=mode!=='work';
  $('#panel').classList.toggle('work-panel',mode==='work');
  $('#panel').setAttribute('aria-label',mode==='work'?'Work 任务窗口':'Conversation 回答窗口');
  document.querySelectorAll('.panel-tabs span').forEach(s=>s.classList.toggle('chosen',s.textContent===(mode==='work'?'Work':'Conversation')));
  $('.panel-title').textContent=mode==='work'?'调整卡片布局':'理解这段文字';
  $('.controls').dataset.title=mode==='work'?'Work':mode==='ask'?'Capture & Ask':'截图翻译';
}
const visible=(s,on)=>{$(s).hidden=!on;if(s==='#panel'&&parent!==window)parent.postMessage({type:'marr-window-focus',target:on?'panel':'source'},location.origin);};
function rect(el){const a=el.getBoundingClientRect(),b=desktop.getBoundingClientRect(),scale=b.width/1000;return{x:(a.left-b.left)/scale,y:(a.top-b.top)/scale,w:a.width/scale,h:a.height/scale};}
function place(el,r){Object.assign(el.style,{left:r.x+'px',top:r.y+'px',width:r.w+'px',height:r.h+'px'});}
function point(e){const r=desktop.getBoundingClientRect();return{x:clamp((e.clientX-r.left)*1000/r.width,0,1000),y:clamp((e.clientY-r.top)*700/r.height,27,700)};}
function guide(s){$('#guide').textContent=s;}
function reset(){if(dragOriginal){const id=dragOriginal.pointerId;if(id!==undefined&&$('#original').hasPointerCapture(id))$('#original').releasePointerCapture(id);endOriginal();}document.body.classList.remove('work-done');setMode(mode);$('#compare').innerHTML=icons.compare+' Compare';$('[data-tool="expand"]').setAttribute('aria-label','Expand tools 展开工具');selection=null;start=null;drawing=null;tool=null;translated=false;comparing=false;marks=[];zoom=1;expanded=false;$('#marks').replaceChildren();$('#messages').replaceChildren();$('#question').value='';$('#followup input').value='';['#selection','#tools','#more-tools','#capture-composer','#translated','#compare','#original','#panel','#crop-preview'].forEach(s=>visible(s,false));document.querySelectorAll('[data-tool]').forEach(b=>b.classList.remove('selected'));$('[data-tool="expand"]').setAttribute('aria-expanded','false');guide(mode==='translate'?'在英文段落上拖动框选，再点击选区右侧的翻译按钮。也可以点击“选中示例段落”。':'框选英文段落，在下方输入问题并发送。展开工具栏还可以画框、箭头和编号。');}
function positionUI(){
  if(!selection)return;
  place($('#selection'),selection);
  const bounds=controlBounds(),layout=MarrCaptureLayout.resolve(selection,{kind:mode,expanded,bounds});
  place($('#tools'),layout.toolbar);
  place($('#capture-composer'),layout.composer);
  place($('#compare'),MarrCaptureLayout.compareButton(selection,bounds));
}
function commit(){if(!selection||selection.w<24||selection.h<24){reset();return;}if(mode==='work'){expanded=true;visible('#more-tools',true);$('[data-tool="expand"]').setAttribute('aria-expanded','true');}positionUI();visible('#tools',true);visible('#capture-composer',true);guide(mode==='translate'?'选区已就绪。点击右侧“文 A”翻译按钮，译文会覆盖在同一位置。':'选区已就绪。输入问题后按 Return；或展开圆形工具栏标出重点。');}
function example(){reset();const r=rect(mode==='work'?$('#work-target'):$('.paragraph'));selection={x:r.x-9,y:r.y-9,w:r.w+18,h:r.h+18};visible('#selection',true);positionUI();commit();}
function fragment(container,useTranslation){container.replaceChildren();const source=mode==='work'?$('.work-document'):$('#article'),a=rect(source),copy=source.cloneNode(true);copy.removeAttribute('id');Array.from(copy.children).forEach((child,i)=>{const r=rect(source.children[i]);Object.assign(child.style,{position:'absolute',left:(r.x-a.x)+'px',top:(r.y-a.y)+'px',width:r.w+'px',height:r.h+'px',margin:'0',overflow:'hidden'});if(useTranslation&&child.dataset.zh)child.textContent=child.dataset.zh;});Object.assign(copy.style,{left:(a.x-selection.x)+'px',top:(a.y-selection.y)+'px',width:a.w+'px',height:a.h+'px'});container.append(copy);}
function translate(){if(!selection)return;const a=rect($('#article'));if(selection.x>a.x+a.w||selection.x+selection.w<a.x||selection.y>a.y+440||selection.y+selection.h<a.y){guide('请框选左侧英文内容；此演示只提供这段英文的预设译文。');return;}translated=true;tool=null;visible('#tools',false);visible('#capture-composer',false);visible('#crop-preview',false);visible('#selection',false);fragment($('#translated'),true);place($('#translated'),selection);visible('#translated',true);positionUI();visible('#compare',true);guide('译文留在选区原位。点击 Compare，在旁边查看原文；按 Escape 重新开始。');}
function compare(){
  if(!selection)return;
  comparing=!comparing;visible('#original',comparing);
  $('#compare').innerHTML=comparing?icons.check+' Done':icons.compare+' Compare';
  if(comparing){
    place($('#original'),MarrCaptureLayout.originalWindow(selection,controlBounds(),rect($('#compare'))));
    fragment($('.original-crop'),false);fitOriginal();
    guide('原文小窗可以拖动或缩放；译文仍在原位。点 Done 收起原文。');
  }else guide('已收起原文。译文仍覆盖在原来的选区。');
}
function svg(name,attrs){const el=document.createElementNS('http://www.w3.org/2000/svg',name);Object.entries(attrs).forEach(([k,v])=>el.setAttribute(k,v));return el;}
function renderMarks(extra){const root=$('#marks');root.replaceChildren();[...marks,...(extra?[extra]:[])].forEach(m=>{const a=m.a,b=m.b;let shape;const attrs={fill:'none',stroke:'#ff383b','stroke-width':3,'stroke-linecap':'round','stroke-linejoin':'round'};if(m.type==='rectangle')shape=svg('rect',{...attrs,x:Math.min(a.x,b.x),y:Math.min(a.y,b.y),width:Math.abs(a.x-b.x),height:Math.abs(a.y-b.y)});else if(m.type==='arrow'){const ang=Math.atan2(b.y-a.y,b.x-a.x),l=Math.min(14,Math.hypot(b.x-a.x,b.y-a.y)*.4);shape=svg('path',{...attrs,d:`M${a.x} ${a.y}L${b.x} ${b.y}M${b.x-l*Math.cos(ang-.52)} ${b.y-l*Math.sin(ang-.52)}L${b.x} ${b.y}L${b.x-l*Math.cos(ang+.52)} ${b.y-l*Math.sin(ang+.52)}`});}else if(m.type==='pen')shape=svg('polyline',{...attrs,points:m.points.map(p=>`${p.x},${p.y}`).join(' ')});else{shape=svg('g',{});shape.append(svg('circle',{cx:a.x,cy:a.y,r:13,fill:'#ff383b',stroke:'white','stroke-width':1.5}));const t=svg('text',{x:a.x,y:a.y+5,'text-anchor':'middle',fill:'white','font-size':14,'font-family':'-apple-system, sans-serif','font-weight':700});t.textContent=m.number;shape.append(t);}root.append(shape);});}
function inside(p,r){return p.x>=r.x&&p.y>=r.y&&p.x<=r.x+r.w&&p.y<=r.y+r.h;}
desktop.addEventListener('pointerdown',e=>{if(e.target.closest('button,input,form,#panel,#original,#crop-preview')||translated)return;if(e.button!==0)return;if(document.body.classList.contains('embedded')&&!storyManual){if(e.pointerType==='touch')return;beginInteraction();}e.preventDefault();const p=point(e);desktop.setPointerCapture(e.pointerId);if(tool&&selection&&inside(p,selection)){const a={x:p.x-selection.x,y:p.y-selection.y};drawing={type:tool,a,b:a,points:[a],number:marks.filter(m=>m.type==='number').length+1};renderMarks(drawing);}else{reset();start=p;selection={x:p.x,y:p.y,w:0,h:0};visible('#selection',true);positionUI();}});
desktop.addEventListener('pointermove',e=>{const p=point(e);if(drawing){drawing.b={x:clamp(p.x-selection.x,0,selection.w),y:clamp(p.y-selection.y,0,selection.h)};drawing.points.push(drawing.b);renderMarks(drawing);}else if(start){selection={x:Math.min(start.x,p.x),y:Math.min(start.y,p.y),w:Math.abs(start.x-p.x),h:Math.abs(start.y-p.y)};place($('#selection'),selection);}});
function finish(){if(drawing){marks.push(drawing);drawing=null;renderMarks();}else if(start){start=null;commit();}}
desktop.addEventListener('pointerup',finish);desktop.addEventListener('pointercancel',finish);
$('#tools').addEventListener('click',e=>{const b=e.target.closest('button');if(!b)return;const key=b.dataset.tool;if(key==='translate')return translate();if(key==='expand'){expanded=!expanded;visible('#more-tools',expanded);b.setAttribute('aria-expanded',String(expanded));b.setAttribute('aria-label',expanded?'Collapse tools 收起工具':'Expand tools 展开工具');positionUI();return;}if(key==='undo'){marks.pop();renderMarks();return;}visible('#crop-preview',false);tool=tool===key?null:key;document.querySelectorAll('#more-tools button').forEach(b=>b.classList.toggle('selected',b.dataset.tool===tool));guide('在选区内拖动进行标注；编号工具单击即可。完成后在输入条中提问。');});
const answer='这段文字的核心是：好的工具应该融入工作流程，减少切换带来的打断。\n\n“keep your train of thought” 意思是“保持思路连贯”，这里不是字面上的“火车”。\n\n作者建议：遇到好奇的内容，截下来、提问、理解，再接着思考。';
function addMessage(question,followup=false){const q=document.createElement('div');q.className='user-message';q.textContent=question;const a=document.createElement('div');a.className='answer-message';a.textContent=followup?'可以理解为：“别让操作工具，打断你正在思考的事情。”\n\n例如，读到陌生的英文表达时，就地框选翻译，然后继续阅读。\n\n你可以继续围绕这段内容提问。':answer;$('#messages').append(q,a);$('#messages').scrollTop=$('#messages').scrollHeight;}
$('#capture-composer').addEventListener('submit',e=>{e.preventDefault();const q=$('#question').value.trim();if(!q){guide('输入一个问题，例如：“这段文字是什么意思？”');$('#question').focus();return;}visible('#selection',false);visible('#tools',false);visible('#capture-composer',false);visible('#crop-preview',false);visible('#panel',true);if(mode==='work')showWork(q);else addMessage(q);guide('继续输入，接着聊。');});
$('#followup').addEventListener('submit',e=>{e.preventDefault();const input=$('#followup input');if(!input.value.trim())return;if(mode==='work')showWork(input.value.trim());else addMessage(input.value.trim(),true);input.value='';});
$('#close-panel').addEventListener('click',reset);$('#compare').addEventListener('click',compare);$('#reset').addEventListener('click',reset);$('#select-example').addEventListener('click',example);
$('#thumbnail').addEventListener('click',()=>{const on=$('#crop-preview').hidden;visible('#crop-preview',on);if(on){fragment($('#crop-preview'),false);place($('#crop-preview'),{x:clamp(selection.x,8,988-selection.w),y:Math.max(35,selection.y-20),w:selection.w,h:selection.h});guide('截图预览。再次点击缩略图收起，或直接输入问题。');}});
document.querySelectorAll('[data-mode]').forEach(b=>b.addEventListener('click',()=>{mode=b.dataset.mode;document.querySelectorAll('[data-mode]').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));reset();if(mode==='ask'){$('#question').value='这段文字是什么意思？';} }));
function fitOriginal(){const r=rect($('#original'));zoom=r.w/selection.w;Object.assign($('.original-crop').style,{width:selection.w+'px',height:selection.h+'px',transform:'scale('+zoom+')'});}
function resizeOriginal(r,p,edge){
  const bounds=controlBounds(),ratio=selection.w/selection.h;
  const east=edge.includes('e'),south=edge.includes('s');
  const dx=(p.x-dragOriginal.p.x)*(east?1:-1),dy=(p.y-dragOriginal.p.y)*(south?1:-1);
  const delta=Math.abs(dx)>Math.abs(dy*ratio)?dx:dy*ratio;
  const maxW=Math.max(1,Math.min(east?bounds.x+bounds.w-r.x:r.x+r.w-bounds.x,(south?bounds.y+bounds.h-r.y:r.y+r.h-bounds.y)*ratio));
  const w=clamp(r.w+delta,Math.min(140,maxW),maxW),h=w/ratio;
  place($('#original'),{x:east?r.x:r.x+r.w-w,y:south?r.y:r.y+r.h-h,w,h});fitOriginal();
}
function keepOriginalVisible(){
  if(!selection||$('#original').hidden)return;
  const bounds=controlBounds();
  let next=MarrCaptureLayout.fitAspectRect(rect($('#original')),bounds);
  const button=rect($('#compare'));
  if(!dragOriginal&&next.x<button.x+button.w+12&&next.x+next.w>button.x-12&&next.y<button.y+button.h+12&&next.y+next.h>button.y-12){
    next=MarrCaptureLayout.originalWindow(selection,bounds,button,next);
  }
  place($('#original'),next);fitOriginal();
  if(dragOriginal){dragOriginal.r=rect($('#original'));dragOriginal.p=dragOriginal.lastPoint||dragOriginal.p;}
}
$('#original').addEventListener('pointerdown',e=>{if(e.button!==0)return;const p=point(e);parent.postMessage({type:'marr-window-drag',active:true},location.origin);dragOriginal={p,r:rect($('#original')),edge:e.target.dataset.resize,pointerId:e.pointerId};$('#original').setPointerCapture(e.pointerId);$('#original').focus({preventScroll:true});e.preventDefault();});
$('#original').addEventListener('pointermove',e=>{if(!dragOriginal)return;const p=point(e),r=dragOriginal.r,bounds=controlBounds();dragOriginal.lastPoint=p;if(dragOriginal.edge){resizeOriginal(r,p,dragOriginal.edge);return;}$('#original').style.left=clamp(r.x+p.x-dragOriginal.p.x,bounds.x,bounds.x+bounds.w-r.w)+'px';$('#original').style.top=clamp(r.y+p.y-dragOriginal.p.y,bounds.y,bounds.y+bounds.h-r.h)+'px';});
function endOriginal(){dragOriginal=null;parent.postMessage({type:'marr-window-drag',active:false},location.origin);}
$('#original').addEventListener('pointerup',endOriginal);$('#original').addEventListener('pointercancel',endOriginal);
$('#original').addEventListener('keydown',e=>{const r=rect($('#original')),bounds=controlBounds();if(['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key)){e.preventDefault();place($('#original'),{...r,x:clamp(r.x+(e.key==='ArrowRight'?10:e.key==='ArrowLeft'?-10:0),bounds.x,bounds.x+bounds.w-r.w),y:clamp(r.y+(e.key==='ArrowDown'?10:e.key==='ArrowUp'?-10:0),bounds.y,bounds.y+bounds.h-r.h)});}if(['+','=','-'].includes(e.key)){e.preventDefault();dragOriginal={p:{x:0,y:0},r};resizeOriginal(r,{x:e.key==='-'?-30:30,y:0},'se');endOriginal();}});
document.addEventListener('keydown',e=>{if(e.key==='Escape'){reset();if(document.body.classList.contains('embedded'))desktop.focus({preventScroll:true});else $('#select-example').focus();}});
function resize(){desktop.style.transform=`scale(${viewport.clientWidth/1000})`;positionUI();keepOriginalVisible();if(parent!==window)parent.postMessage({type:'marr-demo-height',height:Math.ceil(document.body.getBoundingClientRect().height)},location.origin);}
window.addEventListener('message',e=>{
  if(e.origin!==location.origin||e.source!==parent||e.data?.type!=='marr-demo-bounds')return;
  const b=e.data.bounds;if(!b||!['x','y','w','h'].every(key=>Number.isFinite(b[key]))||b.w<300||b.h<350)return;
  visibleBounds={x:b.x,y:b.y,w:b.w,h:b.h};positionUI();keepOriginalVisible();
});
new ResizeObserver(resize).observe(viewport);window.addEventListener('load',resize);reset();
window.addEventListener('message',e=>{if(e.origin!==location.origin||e.source!==parent||e.data?.type!=='marr-demo-mode')return;mode=e.data.mode==='translate'?'translate':'ask';document.querySelectorAll('[data-mode]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.mode===mode)));example();if(e.data.mode==='annotate'){expanded=true;visible('#more-tools',true);$('[data-tool="expand"]').setAttribute('aria-expanded','true');positionUI();}});
const params=new URLSearchParams(location.search);const sceneKind=['ask','work'].includes(params.get('scene'))?params.get('scene'):'translate';
setMode(sceneKind);document.body.classList.toggle('embedded',params.get('embed')==='1');document.body.classList.toggle('product-scene',params.get('product')==='1');reset();resize();
let lastStoryKey='',storyManual=false;
function beginInteraction(){if(storyManual)return;storyManual=true;document.body.classList.add('is-manual');document.body.classList.remove('invite-select');parent.postMessage({type:'marr-story-interact'},location.origin);}

function storyRender(data){if(storyManual)return;if(data.kind==='work'){workRender(data);return;}const next=clamp(Number(data.phase)||0,0,3),p=clamp(Number(data.progress)||0,0,1);const kind=data.kind==='ask'?'ask':'translate',key=kind+':'+next,changed=key!==lastStoryKey;setMode(kind);document.body.classList.toggle('invite-select',next===0);if(changed){reset();lastStoryKey=key;if(mode==='translate'){if(next===1)example();if(next>=2){example();translate();if(next===3)compare();}}else{if(next>=1){example();expanded=true;visible('#more-tools',true);$('[data-tool="expand"]').setAttribute('aria-expanded','true');positionUI();const w=selection.w;marks=[{type:'rectangle',a:{x:10,y:9},b:{x:w-14,y:44}},{type:'number',a:{x:13,y:75},b:{x:13,y:75},number:1}];renderMarks();}if(next===3){visible('#selection',false);visible('#tools',false);visible('#capture-composer',false);visible('#panel',true);addMessage('这段文字想表达什么？');}}}
if(mode==='translate'&&next===1){const r=rect($('.paragraph')),f=clamp((p-.25)/.17,.02,1);selection={x:r.x-9,y:r.y-9,w:(r.w+18)*f,h:(r.h+18)*f};place($('#selection'),selection);visible('#tools',f>.85);visible('#capture-composer',f>.85);positionUI();}
if(mode==='ask'&&next===2){const text='这段文字想表达什么？';$('#question').value=text.slice(0,Math.max(1,Math.round(clamp((p-.5)/.17,0,1)*text.length)));}}
window.addEventListener('message',e=>{if(e.origin!==location.origin||e.source!==parent)return;if(e.data?.type==='marr-story')storyRender(e.data);if(e.data?.type==='marr-story-manual'){storyManual=!!e.data.enabled;document.body.classList.toggle('is-manual',storyManual);document.body.classList.remove('invite-select');setMode(e.data.kind);lastStoryKey='';reset();if(storyManual)desktop.focus({preventScroll:true});}});
if(parent!==window)parent.postMessage({type:'marr-story-ready'},location.origin);

desktop.addEventListener('keydown',e=>{if(e.key==='Enter'&&e.target===desktop&&!selection){e.preventDefault();if(parent!==window)beginInteraction();example();}});

desktop.addEventListener('pointerdown',e=>{if(parent!==window&&!storyManual&&e.target.closest('#original,#compare,#tools,#capture-composer,#panel'))beginInteraction();},true);
desktop.addEventListener('focusin',e=>{if(parent!==window&&!storyManual&&e.target.matches('input,button,#original'))beginInteraction();});
desktop.addEventListener('keydown',e=>{if(parent!==window&&!storyManual&&e.target.matches('input,button,#original')&&!['Tab','Shift','Control','Alt','Meta'].includes(e.key))beginInteraction();},true);



function workSelection(){example();expanded=true;visible('#more-tools',true);$('[data-tool="expand"]').setAttribute('aria-expanded','true');positionUI();}
function workRender(data){
  const next=clamp(Number(data.phase)||0,0,3),key='work:'+next,p=clamp(Number(data.progress)||0,0,1);
  setMode('work');document.body.classList.toggle('invite-select',next===0);
  if(key!==lastStoryKey){lastStoryKey=key;reset();if(next>=1){workSelection();}if(next===3){visible('#selection',false);visible('#tools',false);visible('#capture-composer',false);visible('#panel',true);showWork('把框中的卡片圆角加大，按钮移到箭头的位置。');}}
  if(selection&&(next===1||next===2)){const w=selection.w,h=selection.h;const f=next===1?clamp((p-.25)/.18,.04,1):1;marks=[{type:'rectangle',a:{x:9,y:9},b:{x:9+(w-18)*f,y:9+(h-18)*f}}];if(next===2){const a={x:45,y:45},f=clamp((p-.5)/.18,.03,1);marks.push({type:'arrow',a,b:{x:a.x+(w-50-a.x)*f,y:a.y+(h-30-a.y)*f}});}renderMarks();}
}
function showWork(question){document.body.classList.add('work-done');$('#panel').classList.add('work-panel');$('#panel').setAttribute('aria-label','Work 任务窗口');document.querySelectorAll('.panel-tabs span').forEach(s=>s.classList.toggle('chosen',s.textContent==='Work'));$('.panel-title').textContent='调整卡片布局';const q=document.createElement('div');q.className='user-message';q.textContent=question;const result=document.createElement('div');result.className='work-result';result.innerHTML='<details class="work-trace"><summary>Processed '+icons.chevron+'</summary><p>读取界面与标注</p><p>调整卡片与按钮布局</p></details><p>已按标注调整卡片圆角与按钮位置。</p><div class="file-review"><div>Edited 1 file <span class="additions">+8</span> <span class="deletions">−4</span></div><details><summary>ProjectCard.tsx '+icons.chevron+'</summary><pre>border-radius: 24px;\njustify-content: flex-end;</pre></details></div>';$('#messages').append(q,result);$('#messages').scrollTop=$('#messages').scrollHeight;}
if(params.get('hero')==='1'){document.body.classList.add('hero-scene');storyRender({kind:'ask',phase:3,progress:.9});}
