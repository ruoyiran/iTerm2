import {TreeState,snippetParts} from './tree-state.mjs';
export function element(tag, className, text) { const node=document.createElement(tag); if(className)node.className=className;if(text!==undefined)node.textContent=text;return node; }
export function icon(name) { const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox','0 0 24 24');svg.setAttribute('aria-hidden','true');const use=document.createElementNS(svg.namespaceURI,'use');use.setAttribute('href',`./icons/lucide.svg#${name}`);svg.append(use);return svg; }
export function button(label, action, symbol) { const b=element('button','icon-button');b.type='button';b.title=label;b.setAttribute('aria-label',label);if(symbol)b.append(icon(symbol));else b.textContent=label;b.addEventListener('click',action);return b; }
const parentPath=path=>path.slice(0,path.lastIndexOf('/'))||'/';
export class Explorer {
  constructor(root, send, translate) {
    this.root=root;this.contextReady=false;this.root.inert=true;this.send=(type,payload,id)=>this.contextReady?send(type,payload,id):null;this.t=translate;this.state=new TreeState();this.mode='names';this.collapsed=new Set();this.focused=null;this.resultFocus=null;this.rows=[];this.composing=false;this.nameTimer=null;this.scope=null;
    this.build();this.focusHandler=()=>this.send('focus',{});this.root.addEventListener('focusin',this.focusHandler);
  }
  build() {
    const t=this.t;this.root.className='explorer';
    const activity=element('div','activity');const active=button(t('files'),()=>this.names.focus(),'files');active.classList.add('active');activity.append(active);
    const pane=element('div','explorer-pane');const toolbar=element('div','explorer-toolbar');this.title=element('span','root-title',t('selectProject'));
    toolbar.append(this.title,button(t('collapseAll'),()=>{this.state.expanded.clear();this.render();},'list-collapse'),button(t('refresh'),()=>this.refresh(),'refresh-cw'),button(t('more'),event=>this.more(event),'ellipsis'));
    const strip=element('div','query-strip');const modes=element('div','segments');
    for(const mode of ['names','contents']) { const b=button(t(mode),()=>this.setMode(mode));b.dataset.mode=mode;b.setAttribute('aria-pressed',String(this.mode===mode));modes.append(b); }
    this.names=this.query('names','list-filter');this.contents=this.query('contents','search');
    this.names.placeholder=t('findFiles');this.contents.placeholder=t('search');
    this.nameRow=this.names.parentElement;this.contentRow=this.contents.parentElement;this.contentRow.hidden=true;
    this.flags={caseSensitive:false,wholeWord:false,regularExpression:false};
    for(const [key,symbol] of [['caseSensitive','case-sensitive'],['wholeWord','whole-word'],['regularExpression','regex']]) {
      const b=button(t(key),()=>{this.flags[key]=!this.flags[key];b.setAttribute('aria-pressed',String(this.flags[key]));},symbol);b.dataset.flag=key;b.setAttribute('aria-pressed','false');this.contentRow.append(b);
    }
    this.filters=element('details','filters');const summary=element('summary','',t('searchDetails'));this.include=element('input');this.exclude=element('input');
    for(const [input,label] of [[this.include,'include'],[this.exclude,'exclude']]) {input.placeholder=t(label);input.setAttribute('aria-label',t(label));}
    this.filters.append(summary,this.include,this.exclude);this.filters.hidden=true;
    strip.append(modes,this.nameRow,this.contentRow,this.filters);this.status=element('div','explorer-status');this.status.setAttribute('role','status');
    this.viewport=element('div','tree-viewport');this.viewport.tabIndex=0;this.viewport.setAttribute('role','tree');this.viewport.setAttribute('aria-multiselectable','true');
    this.summary=element('div','search-summary');this.summary.hidden=true;
    this.canvas=element('div','tree-canvas');this.viewport.append(this.canvas);this.viewport.addEventListener('scroll',()=>this.renderRows());this.viewport.addEventListener('keydown',e=>this.key(e));
    this.viewport.addEventListener('contextmenu',e=>{if(e.target===this.viewport||e.target===this.canvas){e.preventDefault();this.menu(e,null);}});
    pane.append(toolbar,strip,this.summary,this.status,this.viewport);this.root.replaceChildren(activity,pane);
  }
  query(mode,symbol) {
    const row=element('div','query-row');row.append(icon(symbol));const input=element('input');input.type='text';input.spellcheck=false;input.dataset.query=mode;input.setAttribute('aria-label',this.t(mode));
    input.addEventListener('compositionstart',()=>this.composing=true);input.addEventListener('compositionend',()=>{this.composing=false;if(mode==='names')this.scheduleNames();});
    input.addEventListener('input',()=>{if(mode==='names'&&!this.composing)this.scheduleNames();});
    input.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.isComposing&&!this.composing){e.preventDefault();this.search(mode);}if(e.key==='Escape'){input.value='';this.search(mode);}});
    row.append(input,button(this.t('clear'),()=>{input.value='';this.search(mode);input.focus();},'x'));return input;
  }
  setMode(mode) { const hadFocus=document.activeElement===this.names||document.activeElement===this.contents;this.mode=mode;this.nameRow.hidden=mode!=='names';this.contentRow.hidden=mode!=='contents';this.filters.hidden=mode!=='contents';for(const b of this.root.querySelectorAll('[data-mode]'))b.setAttribute('aria-pressed',String(b.dataset.mode===mode));this.cancelSearch();this.state.nameResults=null;this.render();if(hadFocus)(mode==='names'?this.names:this.contents).focus();if(mode==='names'&&this.names.value)this.search(mode); }
  scheduleNames() {clearTimeout(this.nameTimer);this.nameTimer=setTimeout(()=>this.search('names'),180);}
  cancelSearch() {if(this.state.searchIdentifier)this.send('cancelSearch',{identifier:this.state.searchIdentifier});this.state.searchIdentifier=null;this.state.searching=false;}
  search(mode) {
    if(!this.scope)return;this.cancelSearch();const value=(mode==='names'?this.names:this.contents).value;
    this.state.error=null;if(!value){this.state.nameResults=null;this.state.matches.clear();this.render();return;}
    const globs=input=>input.value.split(',').map(s=>s.trim()).filter(Boolean),includeGlobs=globs(this.include),excludeGlobs=globs(this.exclude);
    const filters=mode==='contents'?[...includeGlobs,...excludeGlobs]:[];
    if(filters.length>128||[value,...filters].some(text=>new TextEncoder().encode(text).length>2048)){this.state.error=this.t('searchTooLong');this.render();return;}
    const id=crypto.randomUUID();this.resultFocus=null;this.state.startSearch(id,mode==='names');
    this.send(mode==='names'?'searchNames':'searchContents',mode==='names'?{query:value}:{query:{text:value,...this.flags,includeGlobs,excludeGlobs}},id);this.render();
  }
  list(path) { const id=crypto.randomUUID();this.state.begin(id,path);this.send('listDirectory',{directoryPath:path},id); }
  refresh() {
    if(!this.scope)return;this.cancelSearch();this.state.pending.clear();this.state.error=null;this.refreshing=true;
    this.send('refresh',{directoryPath:this.scope.rootDirectory});this.list(this.scope.rootDirectory);
    if((this.mode==='names'?this.names:this.contents).value)this.search(this.mode);this.render();
  }
  reloadExpanded(entries) {
    for(const row of entries??[])if(row.isExpandable&&this.state.expanded.has(row.path)&&!this.state.directories.has(row.path)&&![...this.state.pending.values()].includes(row.path))this.list(row.path);
  }
  toggle(row) {if(!row.isExpandable)return;this.state.toggle(row.path);if(this.state.expanded.has(row.path)&&!this.state.directories.has(row.path))this.list(row.path);this.render();}
  open(row,activation='preview',placement='tab',lineNumber=0,utf16Column=0) { if(row.isDirectory){this.toggle(row);return;}this.send('openFile',{path:row.path,activation,placement,lineNumber,utf16Column}); }
  contextKey(scope) {return scope?.rootDirectory?JSON.stringify([scope.projectIdentifier,scope.worktreeIdentifier,scope.rootDirectory]):null;}
  rememberContext() {
    this.recentContexts??=new Map();const key=this.contextKey(this.scope);if(!key)return;
    this.recentContexts.delete(key);
    const rows=[...this.state.directories.values()].reduce((n,d)=>n+d.entries.length,0);
    if(rows<=10000&&this.state.expanded.size<=10000)this.recentContexts.set(key,{state:this.state,names:this.names.value,contents:this.contents.value,include:this.include.value,exclude:this.exclude.value,flags:{...this.flags},mode:this.mode});
    while(this.recentContexts.size>4)this.recentContexts.delete(this.recentContexts.keys().next().value);
  }
  invalidateTransientUI() {
    this.transientGeneration=(this.transientGeneration??0)+1;clearTimeout(this.nameTimer);
    this.form?.remove();this.form=null;this.formRequest=null;this.composing=false;this.closeMenu();
  }
  beginContextTransition() {
    this.invalidateTransientUI();this.cancelSearch();this.contextReady=false;this.root.inert=true;
  }
  changeContext(payload) {
    this.invalidateTransientUI();this.cancelSearch();this.rememberContext();this.resultFocus=null;this.scope=payload.rootDirectory?payload:null;
    const saved=this.recentContexts.get(this.contextKey(this.scope));this.recentContexts.delete(this.contextKey(this.scope));
    this.state=saved?.state??new TreeState();this.state.scope=this.scope;this.state.pending.clear();
    this.title.textContent=payload.title||this.t('selectProject');this.names.value=saved?.names??'';this.contents.value=saved?.contents??'';
    this.include.value=saved?.include??'';this.exclude.value=saved?.exclude??'';this.flags=saved?.flags??{caseSensitive:false,wholeWord:false,regularExpression:false};
    for(const b of this.contentRow.querySelectorAll('[data-flag]'))b.setAttribute('aria-pressed',String(this.flags[b.dataset.flag]));
    this.contextReady=true;this.root.inert=false;
    this.setMode(saved?.mode??'names');if(this.scope)this.refresh();
  }
  receive(type,payload) {
    if(type==='context') this.changeContext(payload);
    if(type==='refresh') this.refresh();
    if(type==='listing'&&this.refreshing&&payload.token===this.scope?.token&&payload.directoryPath===this.scope.rootDirectory&&this.state.pending.get(payload.requestIdentifier)===payload.directoryPath){this.state.directories.clear();this.refreshing=false;}
    if(type==='listing'&&this.state.listing(payload.token,payload.requestIdentifier,payload.directoryPath,payload.entries,payload.error)&&!payload.error)this.reloadExpanded(payload.entries);
    if(type==='search')this.state.search(payload.token,payload.requestIdentifier,payload);
    if(type==='complete'){if(payload.error)this.state.error=payload.error;if(payload.requestIdentifier===this.formRequest){this.formRequest=null;if(!payload.error){this.form?.remove();this.form=null;}}}
    if(type==='operationState')this.operations=payload;
    if(type==='reveal') {this.focused=payload.path;this.state.select(payload.path,'replace');const root=this.scope?.rootDirectory;let path=parentPath(payload.path);while(root&&path.startsWith(root)&&path!==root){this.state.expanded.add(path);if(!this.state.directories.has(path))this.list(path);path=parentPath(path);}}
    if(type==='focusQuery'){const mode=payload.contents?'contents':'names';if(this.mode!==mode)this.setMode(mode);(payload.contents?this.contents:this.names).focus();}
    this.render();
  }
  render() {
    this.rows=[];let height=0;
    if(this.mode==='contents') {
      for(const group of this.state.matches.values()) {this.rows.push({kind:'group',key:JSON.stringify(['group',group.path]),group,top:height,height:28});height+=28;if(!this.collapsed.has(group.path))for(const line of group.lines){this.rows.push({kind:'match',key:JSON.stringify(['match',group.path,line.lineNumber,line.ranges[0]?.location??0]),group,line,top:height,height:22});height+=22;}}
    } else for(const row of this.state.rows()){this.rows.push({kind:'entry',row,top:height,height:26});height+=26;}
    this.canvas.style.height=`${height}px`;
    this.summary.hidden=this.mode!=='contents'||!this.state.matches.size;const matches=[...this.state.matches.values()].reduce((sum,group)=>sum+group.lines.reduce((count,line)=>count+line.ranges.length,0),0);this.summary.replaceChildren(element('span','',this.t('results')),element('strong','',new Intl.NumberFormat().format(matches)),element('span','',this.t('files')),element('strong','',new Intl.NumberFormat().format(this.state.matches.size)));
    const s=this.state;const failedDirectory=[...s.directories.entries()].find(([,value])=>value.error);this.status.textContent=s.error||failedDirectory?.[1].error||(!this.scope?this.t('selectProject'):s.searching||s.pending.size?this.t('loading'):s.truncated?this.t('truncated'):s.skipped?this.t('skipped'):this.rows.length?'':this.mode==='contents'?(this.contents.value?this.t('noResults'):this.t('typeSearch')):this.t('empty'));
    if(failedDirectory){const retry=button(this.t('retry'),()=>{s.directories.delete(failedDirectory[0]);this.list(failedDirectory[0]);this.render();});retry.dataset.retry='true';this.status.append(retry);}this.status.hidden=!this.status.textContent;this.renderRows();
  }
  renderRows() {
    const restoreFocus=this.mode==='contents'&&(this.canvas.contains(document.activeElement)||document.activeElement===this.viewport);
    const min=this.viewport.scrollTop-520,max=this.viewport.scrollTop+(this.viewport.clientHeight||600)+520;
    const children=[];
    for(const [index,item] of this.rows.entries()) {if(item.top+item.height<min||item.top>max)continue;let node;
      if(item.kind==='entry')node=this.entry(item.row);
      else if(item.kind==='group') {node=button(item.group.relativePath,()=>{if(this.collapsed.has(item.group.path))this.collapsed.delete(item.group.path);else this.collapsed.add(item.group.path);this.render();});node.className='result-group';node.prepend(icon(this.collapsed.has(item.group.path)?'chevron-right':'chevron-down'));}
      else {node=element('button','result-match');node.type='button';node.append(element('span','line-number',String(item.line.lineNumber)));for(const part of snippetParts(item.line.snippet,item.line.ranges,item.line.snippetColumn))node.append(element(part.match?'mark':'span','',part.text));node.addEventListener('click',()=>this.open({path:item.group.path},'preview','tab',item.line.lineNumber,(item.line.ranges[0]?.location??0)+1));node.addEventListener('dblclick',()=>this.open({path:item.group.path},'pinned','tab',item.line.lineNumber,(item.line.ranges[0]?.location??0)+1));}
      if(item.kind!=='entry'){node.dataset.resultIndex=String(index);node.dataset.resultKey=item.key;node.addEventListener('focus',()=>{this.resultFocus={key:item.key,path:item.group.path};});}
      node.style.top=`${item.top}px`;node.style.height=`${item.height}px`;children.push(node);
    }
    this.canvas.replaceChildren(...children);
    if(restoreFocus&&this.resultFocus){
      let key=this.resultFocus.key;if(!this.rows.some(row=>row.key===key))key=JSON.stringify(['group',this.resultFocus.path]);
      const target=[...this.canvas.querySelectorAll('[data-result-key]')].find(node=>node.dataset.resultKey===key);
      (target??this.viewport).focus({preventScroll:true});
    }
  }
  entry(row) {
    const node=element('button','tree-row');node.type='button';node.dataset.path=row.path;node.setAttribute('role','treeitem');node.setAttribute('aria-level',String(row.depth+1));node.setAttribute('aria-selected',String(this.state.selected.has(row.path)));if(row.isExpandable)node.setAttribute('aria-expanded',String(this.state.expanded.has(row.path)));node.style.paddingLeft=`${row.depth*16+8}px`;
    node.append(icon(row.isExpandable?(this.state.expanded.has(row.path)?'chevron-down':'chevron-right'):row.isSymbolicLink?'link':'file'),icon(row.isDirectory?'folder':'file-text'),element('span','filename',row.name));node.title=row.relativePath||row.path;
    node.addEventListener('click',event=>{this.focused=row.path;this.state.select(row.path,event.shiftKey?(event.metaKey?'additive-range':'range'):event.metaKey?'toggle':'replace');for(const visible of this.canvas.querySelectorAll('[data-path]'))visible.setAttribute('aria-selected',String(this.state.selected.has(visible.dataset.path)));if(!event.shiftKey&&!event.metaKey)this.open(row);this.viewport.focus();});
    node.addEventListener('dblclick',()=>{if(!row.isDirectory)this.open(row,'pinned');});
    node.addEventListener('contextmenu',event=>{event.preventDefault();if(!this.state.selected.has(row.path))this.state.select(row.path,'replace');this.focused=row.path;this.renderRows();this.menu(event,row);});
    node.draggable=true;node.addEventListener('dragstart',event=>{if(!this.state.selected.has(row.path))this.state.select(row.path,'replace');event.dataTransfer?.setData('application/x-iterm-file-selection',JSON.stringify({token:this.scope.token,paths:[...this.state.selected]}));});
    node.addEventListener('dragover',event=>{if(row.isExpandable){event.preventDefault();node.classList.add('drop-target');}});node.addEventListener('dragleave',()=>node.classList.remove('drop-target'));
    node.addEventListener('drop',event=>{event.preventDefault();node.classList.remove('drop-target');try{const data=JSON.parse(event.dataTransfer.getData('application/x-iterm-file-selection'));if(data.token===this.scope.token&&Array.isArray(data.paths))this.send('move',{paths:data.paths,directoryPath:row.path});}catch{}});return node;
  }
  key(event) {
    if(event.isComposing||this.composing||['INPUT','TEXTAREA'].includes(event.target.tagName))return;
    if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='z'){event.preventDefault();this.send(event.shiftKey?'redo':'undo',{});return;}
    if(this.mode==='contents'){this.resultKey(event);return;}
    const current=this.focused??this.state.rows()[0]?.path;const row=this.state.rows().find(r=>r.path===current);if(!row)return;
    if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='c'){event.preventDefault();this.send(event.shiftKey?'copyRelativePaths':'copyAbsolutePaths',{paths:[...this.state.selected]});return;}
    if(event.key==='Backspace'&&(event.metaKey||event.ctrlKey)||event.key==='Delete'){event.preventDefault();this.send('trash',{paths:[...this.state.selected]});return;}
    if(event.key==='Enter'){event.preventDefault();this.inline('rename',row);return;}
    if(event.key===' '){event.preventDefault();this.open(row);return;}
    const target=this.state.navigate(event.key,current);if(!target)return;event.preventDefault();if(target.toggle){this.toggle(row);return;}this.focused=target.path;this.state.select(target.path,event.shiftKey?'range':'replace');this.render();const index=this.state.rows().findIndex(r=>r.path===target.path);this.viewport.scrollTop=Math.max(0,index*26-100);
  }
  resultKey(event) {
    const target=event.target.closest('[data-result-key]');
    const key=target?.dataset.resultKey??this.resultFocus?.key;const index=this.rows.findIndex(row=>row.key===key);const item=this.rows[index];
    if(event.key==='Delete'||event.key==='Backspace'||((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='z')){event.preventDefault();return;}
    if(!item)return;
    if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='c'){event.preventDefault();this.send(event.shiftKey?'copyRelativePaths':'copyAbsolutePaths',{paths:[item.group.path]});return;}
    if(event.key==='Enter'||event.key===' '){event.preventDefault();if(item.kind==='match')this.open({path:item.group.path},'pinned','tab',item.line.lineNumber,(item.line.ranges[0]?.location??0)+1);else {if(this.collapsed.has(item.group.path))this.collapsed.delete(item.group.path);else this.collapsed.add(item.group.path);this.render();}return;}
    const changes={ArrowUp:-1,ArrowDown:1,PageUp:-10,PageDown:10};let next;
    if(event.key in changes)next=index+changes[event.key];else if(event.key==='Home')next=0;else if(event.key==='End')next=this.rows.length-1;
    else if(event.key==='ArrowLeft'&&item.kind==='match')next=this.rows.findIndex(row=>row.kind==='group'&&row.group.path===item.group.path);
    else return;
    event.preventDefault();next=Math.max(0,Math.min(this.rows.length-1,next));const row=this.rows[next];
    this.viewport.scrollTop=Math.max(0,row.top-100);this.renderRows();this.canvas.querySelector(`[data-result-index="${next}"]`)?.focus();
  }
  menu(event,row) {
    this.closeMenu();const menu=element('div','context-menu');menu.setAttribute('role','menu');const paths=row&&this.state.selected.has(row.path)?[...this.state.selected]:row?[row.path]:[];const directoryPath=row?.isDirectory?row.path:row?parentPath(row.path):this.scope?.rootDirectory;
    const add=(key,fn,symbol)=>{const item=button(this.t(key),()=>{this.closeMenu();fn();},symbol);item.append(element('span','',this.t(key)));item.setAttribute('role','menuitem');menu.append(item);};
    add('newFile',()=>this.inline('createFile',row),'file-plus');add('newFolder',()=>this.inline('createFolder',row),'folder-plus');
    if(row){add('copyFiles',()=>this.send('copyFiles',{paths}),'copy');add('copyPath',()=>this.send('copyAbsolutePaths',{paths}),'copy');add('copyRelativePath',()=>this.send('copyRelativePaths',{paths}),'copy');if(!row.isDirectory)add('duplicate',()=>this.inline('duplicateFile',row),'files');}
    const placements=[['tab','newTab'],['verticalSplit','splitRight'],['horizontalSplit','splitDown'],['window','newWindow']];
    for(const [group,label] of [['openFile','openFile'],['openTerminal','openTerminal']]) {
      if(group==='openFile'&&(!row||row.isDirectory))continue;const details=element('details');details.append(element('summary','',this.t(label)));
      for(const [placement,key] of placements){const b=button(this.t(key),()=>{this.closeMenu();if(group==='openFile')this.open(row,'pinned',placement);else this.send('openTerminal',{directoryPath,placement});});details.append(b);}menu.append(details);
    }
    if(directoryPath){add('findInFolder',()=>this.send('findInFolder',{directoryPath}),'search');add('addProject',()=>this.send('addFolderAsProject',{directoryPath}),'folder-plus');}
    if(row){add('reveal',()=>this.send('revealInFinder',{paths}),'external-link');add('openExternally',()=>this.send('openExternally',{paths}),'external-link');add('rename',()=>this.inline('rename',row),'pencil');add('trash',()=>this.send('trash',{paths}),'trash-2');}
    this.showMenu(menu,event);
  }
  more(event) {
    this.closeMenu();const menu=element('div','context-menu');for(const [key,label] of [['showsHiddenFiles','showHidden'],['showsGitIgnoredFiles','showIgnored']]) {const b=button(this.t(label),()=>{this.send('setVisibility',{showsHiddenFiles:!!this.scope?.showsHiddenFiles,showsGitIgnoredFiles:!!this.scope?.showsGitIgnoredFiles,[key]:!this.scope?.[key]});this.closeMenu();});b.prepend(document.createTextNode(this.scope?.[key]?'✓ ':''));menu.append(b);}menu.append(button(this.t('returnToRoot'),()=>{this.send('returnToRoot',{});this.closeMenu();}));this.showMenu(menu,event);
  }
  showMenu(menu,event) {const scope=this.scope,generation=this.transientGeneration;const fence=event=>{if(this.scope!==scope||this.transientGeneration!==generation||this.menuNode!==menu){event.preventDefault();event.stopImmediatePropagation();}};menu.addEventListener('click',fence,true);menu.addEventListener('keydown',fence,true);this.menuNode=menu;menu.style.left=`${Math.min(event.clientX||0,Math.max(0,window.innerWidth-220))}px`;menu.style.top=`${Math.min(event.clientY||32,Math.max(0,window.innerHeight-400))}px`;this.root.append(menu);menu.addEventListener('keydown',e=>{if(e.key==='Escape')this.closeMenu();});const close=e=>{if(!menu.contains(e.target))this.closeMenu();};this.menuCloser=close;document.addEventListener('pointerdown',close);menu.querySelector('button')?.focus();}
  closeMenu(){if(this.menuCloser)document.removeEventListener('pointerdown',this.menuCloser);this.menuNode?.remove();this.menuNode=null;}
  inline(kind,row) {
    this.closeMenu();this.form?.remove();const scope=this.scope,generation=this.transientGeneration;const form=element('form','inline-input');const current=()=>this.scope===scope&&this.transientGeneration===generation&&this.form===form;const input=element('input');input.setAttribute('aria-label',this.t(kind==='rename'?'rename':'name'));input.value=kind==='rename'?row.name:'';form.append(icon(kind==='createFolder'?'folder-plus':'file-plus'),input,button(this.t('cancel'),()=>form.remove(),'x'));this.viewport.before(form);this.form=form;
    form.addEventListener('submit',event=>{event.preventDefault();if(!current()||this.composing||!input.value)return;const directoryPath=row?.isDirectory?row.path:row?parentPath(row.path):this.scope?.rootDirectory;this.formRequest=this.send(kind,{paths:row?[row.path]:[],directoryPath,name:input.value});});input.addEventListener('compositionstart',()=>{if(current())this.composing=true;});input.addEventListener('compositionend',()=>{if(current())this.composing=false;});input.addEventListener('keydown',event=>{if(current()&&event.key==='Escape')form.remove();});input.focus();input.select();
  }
  dispose() {this.beginContextTransition();this.root.removeEventListener('focusin',this.focusHandler);clearTimeout(this.nameTimer);this.cancelSearch();this.closeMenu();this.root.replaceChildren();this.root.inert=false;}
}
