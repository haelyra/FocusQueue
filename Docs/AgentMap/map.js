'use strict';

// Intentionally synthetic. No local file access, provider hooks, or app launching.
const tasks = [
  {id:'map', label:'Workspace map', ref:'DESIGN / 01', status:'2 agents · 1 blocked', path:'ECCFocusQueue-agent-map', summary:'Add a visual map beside the central plan. Keep tracking modular, expose evidence, and preserve the queue as the user’s anchor.'},
  {id:'plan', label:'Central plan experience', ref:'BUILD / 02', status:'1 agent · working', path:'ECCFocusQueue', summary:'Refine the embedded plan, supporting documents, and task-specific conversation. Preserve concurrent edits.'},
  {id:'mail', label:'Connector readiness', ref:'VERIFY / 03', status:'2 agents · 1 stale', path:'ECCFocusQueue-connectors', summary:'Verify connector readiness and preserve a clear, inspectable handoff with supporting reports.'}
];
const agents = {
  designer:{id:'designer',name:'Codex · Map design',short:'Codex',task:'map',state:'working',color:'var(--accent)',summary:'Comparing layouts and writing the design handoff.',age:'40s ago',evidence:'Declared scope + progress heartbeat',input:'Central plan and task brief',output:'workspace-map.html'},
  collector:{id:'collector',name:'Claude · Collector',short:'Claude',task:'map',state:'blocked',color:'var(--blue)',summary:'Waiting for agreement on the map snapshot contract.',age:'2m ago',evidence:'Explicit blocked progress report',input:'Snapshot contract decision',output:'MapSnapshot.swift'},
  ui:{id:'ui',name:'Claude · Plan UI',short:'Claude',task:'plan',state:'working',color:'var(--blue)',summary:'Refining the document tabs and task conversation.',age:'25s ago',evidence:'Declared scope + progress heartbeat',input:'Central plan',output:'PlanCanvasView.swift'},
  connector:{id:'connector',name:'Codex · Connectors',short:'Codex',task:'mail',state:'stale',color:'var(--amber)',summary:'Last reported: checking connector configuration. Current activity unknown.',age:'12m ago',evidence:'Heartbeat expired; last report retained',input:'Connector readiness notes',output:'readiness.md'},
  verifier:{id:'verifier',name:'Claude · Verification',short:'Claude',task:'mail',state:'completed',color:'var(--blue)',summary:'Recorded the verification result and supporting report.',age:'3m ago',evidence:'Explicit completion report',input:'readiness.md',output:'verification.pdf'}
};
const state = {task:'map',view:'directory',scope:'task',query:'',attention:false,changes:false,selected:'',zoom:1};
let graph={nodes:[],edges:[],labels:[],bounds:[],lanes:[],width:1050,height:425};
const $ = id => document.getElementById(id);
const escapeHTML = value => String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const taskFor = id => tasks.find(t=>t.id===id);
const ownersFor = task => Object.values(agents).filter(a=>a.task===task).map(a=>a.id);
const taskPath = task => `/demo/workspaces/${taskFor(task).path}`;
function add(id,label,kind,x,y,extra={}) {
  const node={id,label,kind,x,y,w:172,h:78,summary:'',evidence:'Recorded task metadata',age:'Demo snapshot',...extra};
  graph.nodes.push(node); return node;
}
function edge(from,to,label='',intent=false){graph.edges.push({from,to,label,intent});}
function agentNode(id,x,y){const a=agents[id];return add('agent-'+id,a.name,'agent',x,y,{owners:[id],task:a.task,state:a.state,meta:a.state+' · '+a.age,summary:a.summary,evidence:a.evidence,age:a.age,color:a.color,changed:['designer','collector','verifier'].includes(id),input:a.input,output:a.output});}
function root(x,y){return add('queue','Focus Queue','orchestrator',x,y,{w:146,summary:'One queue coordinates priorities and points to each task’s central plan and work location.',meta:'Queue orchestrator',evidence:'Recorded queue order',output:'Task priorities and assignments'});}
function worktree(t,x,y,w=172){return add('wt-'+t.id,t.path,'worktree',x,y,{w,task:t.id,path:taskPath(t.id),owners:ownersFor(t.id),summary:'A physical workspace boundary. Agent scope is reported separately from Git changes.',evidence:'Observed Git worktree + registered task context',meta:t.id==='plan'?'main checkout':'isolated worktree',changed:t.id==='map'});}
function artifact(id,label,task,x,y,extra={}){
  const suffix=label.split('.').pop();
  return add(id,label,['swift','py','js'].includes(suffix)?'code':suffix==='md'?'markdown':suffix==='pdf'?'pdf':'html',x,y,{task,path:taskPath(task)+'/'+label,evidence:'Observed path; ownership declared',...extra});
}
function buildDirectory(){
  const active=state.scope==='all'?tasks:[taskFor(state.task)];
  graph.height=active.length===1?425:active.length*355+45;graph.width=1110;
  graph.labels=[['QUEUE',20],['WORKSPACE',199],['DIRECTORY',420],['MODULE / OWNER',638],['FILE / OUTPUT',856]];
  root(20,active.length===1?188:70);
  active.forEach((t,i)=>{
    const y=active.length===1?184:75+i*355;
    const wt=worktree(t,199,y,186);edge('queue',wt.id);
    graph.bounds.push({x:188,y:y-28,w:901,h:253,label:'WORKSPACE BOUNDARY · '+t.path});
    const map=t.id==='map', plan=t.id==='plan';
    const folder=add('folder-'+t.id,map?'Sources/':plan?'Sources/':'Docs/','folder',420,y,{task:t.id,path:taskPath(t.id)+(map||plan?'/Sources':'/Docs'),meta:'Relevant paths only',summary:'Directories expand left to right. Quiet paths remain collapsed.',evidence:'Observed path hierarchy'});
    edge(wt.id,folder.id);
    const module=add('module-'+t.id,map?'FocusQueueMap/':plan?'ECCFocusQueue/':'Readiness/','folder',638,y,{task:t.id,path:folder.path+(map?'/FocusQueueMap':plan?'/ECCFocusQueue':'/Readiness'),owners:ownersFor(t.id),summary:'Agent chips indicate declared work in this area. Multiple owners can share a path.',meta:'Declared scope',evidence:'Agent declarations + directory hierarchy'});
    edge(folder.id,module.id);
    const file=artifact('file-'+t.id,map?'MapSnapshot.swift':plan?'PlanCanvasView.swift':'readiness.md',t.id,856,y,{owners:map?['collector']:plan?['ui']:['connector'],meta:map?'Blocked · contract decision':plan?'Working · UI refinement':'Stale · last report 12m',state:map?'blocked':plan?'working':'stale',changed:map,summary:map?'Proposed collector output. Waiting for the snapshot contract.':plan?'The UI agent reports work on this file.':'The connector agent previously reported this output; its activity report is stale.'});
    file.path=module.path+'/'+file.label;edge(module.id,file.id);
    const output=artifact('output-'+t.id,map?'workspace-map.html':plan?'central-plan.md':'verification.pdf',t.id,856,y+113,{owners:map?['designer']:plan?['ui']:['verifier'],meta:map?'Design output · new':plan?'Shared context':'Completed · 3m ago',state:map?'working':plan?'working':'completed',changed:map||t.id==='mail',summary:'A supporting artifact outside the source directory. Open with the renderer appropriate to its type.'});
    output.path=taskPath(t.id)+(map?'/Docs/':plan?'/':'/Reports/')+output.label;
    const artifactDirectory=add('artifact-dir-'+t.id,map?'Docs/':plan?'Workspace root':'Reports/','folder',638,y+113,{task:t.id,path:taskPath(t.id)+(map?'/Docs':plan?'':'/Reports'),summary:'Supporting artifacts retain their physical directory. External context will appear as a separately referenced location.',evidence:'Observed path hierarchy'});
    if(plan){edge(wt.id,output.id,'root artifact');graph.nodes=graph.nodes.filter(n=>n.id!==artifactDirectory.id);}
    else {edge(wt.id,artifactDirectory.id);edge(artifactDirectory.id,output.id);}
    if(active.length===1){ownersFor(t.id).forEach((id,j)=>{agentNode(id,420+j*218,55);edge('agent-'+id,['designer','verifier'].includes(id)?output.id:file.id,'scope',true);});}
    else graph.lanes.push({label:t.label,y:y-48});
  });
}
function buildFlow(){
  const active=state.scope==='all'?tasks:[taskFor(state.task)];
  graph.width=1090;graph.height=active.length*340+45;
  graph.labels=[['COORDINATES',20],['INPUT / CONTEXT',200],['AGENT',431],['OUTPUT',660],['NEXT',879]];
  root(20,105);
  active.forEach((t,i)=>{
    const y=75+i*340;
    const input=artifact('plan-'+t.id,'central-plan.md',t.id,200,y,{owners:ownersFor(t.id),summary:'An explicitly declared input. Reading a plan and retaining every detail are different facts.',evidence:'Declared input context',meta:'Task brief + decisions'});
    edge('queue',input.id,'assigns');
    ownersFor(t.id).forEach((id,j)=>{
      const a=agents[id],ay=y+j*145;
      const an=agentNode(id,431,ay);edge(input.id,an.id,'input',true);
      const out=artifact('result-'+id,a.output,t.id,660,ay,{owners:[id],state:a.state,meta:a.state==='completed'?'Produced · reported':'Intended output',evidence:a.state==='completed'?'Reported completion':'Declared output',summary:a.state==='completed'?'The agent reported this artifact in its completion handoff.':'The agent intends to produce or update this artifact.',changed:['designer','verifier'].includes(id)});
      edge(an.id,out.id,a.state==='completed'?'produced':'produces',a.state!=='completed');
      const next=add('next-'+id,id==='collector'?'Contract decision':a.state==='completed'?'Review available':'User review','handoff',879,ay,{w:166,task:t.id,owners:[id],meta:id==='collector'?'Blocking dependency':'Next handoff',state:id==='collector'?'blocked':'',summary:id==='collector'?'The collector agent explicitly depends on the snapshot contract decision. This edge points toward the waiting agent.':'A declared checkpoint for the output. Completion and review are separate states.',evidence:'Declared dependency'});
      if(id==='collector')edge(next.id,an.id,'unblocks',true);else edge(out.id,next.id,'review',true);
    });
    graph.lanes.push({label:t.label,y:y-26});
  });
}
function buildFleet(){
  const active=state.scope==='all'?tasks:[taskFor(state.task)];
  graph.width=1110;graph.height=active.length*210+50;
  graph.labels=[['QUEUE',20],['TASK',198],['WORKSPACE',414],['AGENTS',642],['LATEST / NEXT',862]];
  root(20,90);
  active.forEach((t,i)=>{
    const y=70+i*210;
    const tn=add('task-'+t.id,t.label,'task',198,y,{task:t.id,meta:t.status,summary:t.summary,owners:ownersFor(t.id)});edge('queue',tn.id);
    worktree(t,414,y,190);edge(tn.id,'wt-'+t.id);
    ownersFor(t.id).forEach((id,j)=>{agentNode(id,642,y+j*94);edge('wt-'+t.id,'agent-'+id);});
    const names={map:'Snapshot decision',plan:'Plan tabs updated',mail:'Verification ready'};
    add('latest-'+t.id,names[t.id],'handoff',862,y,{task:t.id,owners:ownersFor(t.id),state:t.id==='map'?'blocked':t.id==='mail'?'stale':'working',meta:t.id==='map'?'1 blocked agent':t.id==='mail'?'1 stale report · 1 result':'Latest reported change',summary:t.id==='map'?'Agree on the snapshot contract to unblock the collector.':t.id==='mail'?'A verification result is ready, while another agent’s report needs refreshing.':'The plan agent reports that document tab refinement is underway.',evidence:'Explicit agent progress / completion',changed:true});
    ownersFor(t.id).forEach(id=>edge('agent-'+id,'latest-'+t.id,'',true));
    graph.lanes.push({label:t.label,y:y-22,line:y+190});
  });
}
function relevant(node){
  const haystack=[node.label,node.path,node.summary,...(node.owners||[]).map(id=>agents[id].name)].join(' ').toLowerCase();
  if(state.query&&!haystack.includes(state.query.toLowerCase()))return false;
  if(state.changes&&!node.changed)return false;
  if(state.attention&&!(node.state==='blocked'||node.state==='stale'||(node.owners||[]).some(id=>['blocked','stale'].includes(agents[id].state))))return false;
  return true;
}
function render(){
  graph={nodes:[],edges:[],labels:[],bounds:[],lanes:[],width:1050,height:425};
  ({directory:buildDirectory,flow:buildFlow,fleet:buildFleet})[state.view]();
  const filtered=state.query||state.attention||state.changes;
  const matches=new Set(graph.nodes.filter(relevant).map(n=>n.id));
  const context=new Set(matches);context.add('queue');
  // Restore context upstream, without pulling in unrelated descendants.
  if(filtered){let changed=true;while(changed){changed=false;for(const e of graph.edges){if(context.has(e.to)&&!context.has(e.from)){context.add(e.from);changed=true;}}}}
  const svg=$('edges');svg.setAttribute('viewBox',`0 0 ${graph.width} ${graph.height}`);
  svg.innerHTML='<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="var(--border)"/></marker></defs>'+graph.edges.map(e=>{
    const a=graph.nodes.find(n=>n.id===e.from),b=graph.nodes.find(n=>n.id===e.to);
    const backward=b.x<a.x;
    const x1=backward?a.x:a.x+a.w,x2=backward?b.x+b.w:b.x,y1=a.y+a.h/2,y2=b.y+b.h/2;
    const d=backward?`M${x1},${y1+22} C${x1-30},${y1+90} ${x2+30},${y2+90} ${x2},${y2+22}`:`M${x1},${y1} C${(x1+x2)/2},${y1} ${(x1+x2)/2},${y2} ${x2},${y2}`;
    const dim=filtered&&!(context.has(e.from)&&context.has(e.to));
    return `<path d="${d}" class="edge ${e.intent?'intent':''} ${dim?'dim':''}" ${state.view==='flow'?'marker-end="url(#arrow)"':''}/>`+(e.label&&!dim?`<text x="${(x1+x2)/2}" y="${backward?y1+90:(y1+y2)/2-7}" text-anchor="middle" class="edge-label">${escapeHTML(e.label)}</text>`:'');
  }).join('');
  $('nodes').innerHTML=graph.labels.map(([label,x])=>`<span class="axis-label" style="left:${x}px">${label}</span>`).join('')+
    graph.bounds.map(b=>`<div class="worktree-boundary" style="left:${b.x}px;top:${b.y}px;width:${b.w}px;height:${b.h}px"><span class="boundary-caption">${escapeHTML(b.label)}</span></div>`).join('')+
    graph.lanes.map(l=>`<span class="lane-label" style="top:${l.y}px">${escapeHTML(l.label)}</span>`+(l.line?`<span class="lane-line" style="top:${l.line}px"></span>`:'')).join('')+
    graph.nodes.map(n=>`<button class="node ${n.id==='queue'?'root':''} ${n.changed&&state.changes?'changed':''} ${filtered&&!context.has(n.id)?'dim':''}" data-node="${n.id}" style="left:${n.x}px;top:${n.y}px;width:${n.w}px;min-height:${n.h}px;--owner:${n.color||'var(--border)'}" aria-label="${escapeHTML(n.kind+': '+n.label+(n.meta?', '+n.meta:''))}" aria-pressed="false"><small class="node-kind">${escapeHTML(n.kind)}</small><strong>${escapeHTML(n.label)}</strong>${n.meta?`<small class="node-meta">${n.state?`<i class="status-dot ${n.state}"></i>`:''}${escapeHTML(n.meta)}</small>`:''}${n.owners&&n.kind!=='agent'?`<span class="owner-chips">${n.owners.map(id=>`<span class="owner-chip" style="--owner:${agents[id].color}">${escapeHTML(agents[id].short)}</span>`).join('')}</span>`:''}</button>`).join('');
  $('diagram').style.width=graph.width+'px';$('diagram').style.height=graph.height+'px';setZoom(state.zoom);
  $('empty').hidden=!filtered||matches.size>0;
  $('view-description').textContent={directory:'Physical hierarchy: outer workspace → deeper directory → file. Owners appear on their declared scope.',flow:'Logical flow: context → agent → output → handoff. Dashed links show declared intent.',fleet:'Aligned task lanes: scan workspaces, owners, and the next decision. Expand detail by selecting an item.'}[state.view];
  $('scope').value=state.scope;
  $('task-heading').textContent=taskFor(state.task).label;
  $('plan-title').textContent=taskFor(state.task).label;
  $('plan-summary').textContent=taskFor(state.task).summary;
  document.querySelectorAll('[data-view]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.view===state.view)));
  $('task-list').innerHTML=tasks.map(t=>`<button class="task-button" data-task="${t.id}" aria-pressed="${t.id===state.task}"><small>${t.ref}</small><strong>${t.label}</strong><span class="task-status">${t.status}</span></button>`).join('');
  if(!graph.nodes.some(n=>n.id===state.selected))state.selected=state.view==='directory'?'wt-'+state.task:state.view==='flow'?'agent-'+ownersFor(state.task)[0]:'task-'+state.task;
  selectNode(state.selected);
}
function actionFor(n){
  if(n.kind==='agent')return ['Focus agent terminal','Would focus the registered provider session using Focus Queue’s existing terminal routing.'];
  if(['worktree','folder'].includes(n.kind))return ['Open in Finder','Would open the exact folder in Finder: '+n.path];
  if(n.kind==='markdown')return ['Open plan canvas','Would render this Markdown in the embedded plan canvas. PDF is an optional preference.'];
  if(n.kind==='pdf')return ['Open PDF','Would open this artifact in the preferred PDF viewer.'];
  if(n.kind==='html')return ['Open in browser','Would open this HTML artifact in the browser.'];
  if(n.kind==='code')return ['Open read-only Neovim','Would launch a terminal with argument array [nvim, -R, -M, --, path]. Your code viewer preference is read-only Neovim.'];
  return ['Inspect task context','Would select the linked task or dependency in the existing task inspector.'];
}
function selectNode(id){
  const n=graph.nodes.find(n=>n.id===id);if(!n)return;state.selected=id;
  document.querySelectorAll('[data-node]').forEach(b=>{const selected=b.dataset.node===id;b.classList.toggle('selected',selected);b.setAttribute('aria-pressed',String(selected));});
  const [action]=actionFor(n);
  const ownerNames=(n.owners||[]).map(id=>agents[id].name).join(', ');
  const rows=[['Location',n.path|| (n.task?taskPath(n.task):'All registered tasks')],['Owners',ownerNames||'No file owner inferred'],['Evidence',n.evidence],['Freshness',n.age],['Input',n.input],['Output',n.output],['Task',n.task?taskFor(n.task).label:undefined]].filter(([,v])=>v);
  $('details').innerHTML=`<p class="eyebrow">${escapeHTML(n.kind)} / INSPECT</p><h3>${escapeHTML(n.label)}</h3><p class="detail-summary">${escapeHTML(n.summary||'Select a related agent to inspect its progress, inputs, and intended outputs.')}</p><dl>${rows.map(([k,v])=>`<dt>${k}</dt><dd>${escapeHTML(v)}</dd>`).join('')}</dl><button class="open-action" id="open-node">${action}</button><p class="action-explanation">Prototype action preview. All paths and activity are illustrative.</p>`;
  $('open-node').addEventListener('click',()=>previewOpen(n));
}
let toastTimer;
function toast(message){$('toast').textContent=message;$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').hidden=true,8000);}
function previewOpen(n){selectNode(n.id);toast('Action preview: '+actionFor(n)[1]);}
function setZoom(value){state.zoom=Math.min(1.5,Math.max(.45,value));$('diagram').style.zoom=String(state.zoom);$('zoom-value').textContent=Math.round(state.zoom*100)+'%';}
function setTab(map){$('map-panel').hidden=!map;$('plan-panel').hidden=map;for(const id of ['plan-tab','map-tab']){const selected=(id==='map-tab')===map;$(id).setAttribute('aria-selected',String(selected));$(id).tabIndex=selected?0:-1;}}
document.querySelectorAll('[data-view]').forEach(b=>b.addEventListener('click',()=>{state.view=b.dataset.view;if(state.view==='fleet')state.scope='all';render();fit();}));
$('task-list').addEventListener('click',e=>{const b=e.target.closest('[data-task]');if(!b)return;state.task=b.dataset.task;state.scope='task';state.selected='';render();fit();});
$('nodes').addEventListener('click',e=>{const b=e.target.closest('[data-node]');if(b)selectNode(b.dataset.node);});
$('nodes').addEventListener('dblclick',e=>{const b=e.target.closest('[data-node]');if(b)previewOpen(graph.nodes.find(n=>n.id===b.dataset.node));});
$('scope').addEventListener('change',e=>{state.scope=e.target.value;render();fit();});
$('search').addEventListener('input',e=>{state.query=e.target.value;render();});
for(const id of ['attention','changes'])$(id).addEventListener('click',()=>{state[id]=!state[id];$(id).setAttribute('aria-pressed',String(state[id]));render();});
$('theme').addEventListener('click',()=>{const dark=document.documentElement.dataset.theme!=='graphite';document.documentElement.dataset.theme=dark?'graphite':'paper';$('theme').textContent=dark?'Use paper theme':'Use graphite theme';});
$('zoom-in').addEventListener('click',()=>setZoom(state.zoom+.1));$('zoom-out').addEventListener('click',()=>setZoom(state.zoom-.1));
function fit(){setZoom(Math.min(1,Math.max(.65,($('map-scroll').clientWidth-20)/graph.width)));$('map-scroll').scrollLeft=0;}
$('reset').addEventListener('click',fit);
$('plan-tab').addEventListener('click',()=>setTab(false));$('map-tab').addEventListener('click',()=>setTab(true));$('return-map').addEventListener('click',()=>{setTab(true);$('map-tab').focus();});
document.querySelector('.document-tabs').addEventListener('keydown',e=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;e.preventDefault();const map=e.key==='Home'?false:e.key==='End'?true:$('map-tab').getAttribute('aria-selected')!=='true';setTab(map);$(map?'map-tab':'plan-tab').focus();});
$('context-chat').addEventListener('click',()=>{const n=graph.nodes.find(n=>n.id===state.selected);const message=`Context preview: ${n.label}. ${n.summary} Evidence: ${n.evidence}.`; $('conversation-summary').textContent=message;toast('This context would be attached to the existing task conversation. No message has been sent.');});
render();
// Keep readable labels on entry; Fit is explicit when a wider overview is wanted.
