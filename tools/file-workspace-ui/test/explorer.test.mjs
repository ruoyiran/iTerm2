import test from 'node:test';import assert from 'node:assert/strict';import {Window} from 'happy-dom';
import {Explorer} from '../../../sources/FileWorkspace/Resources/src/explorer.mjs';
test('file activation emits preview/pin intents with literal filenames; contents submit respects IME',()=>{
 const w=new Window();globalThis.document=w.document;globalThis.window=w;globalThis.requestAnimationFrame=fn=>fn();
 const root=document.createElement('div');document.body.append(root);let n=0;const sent=[];
 const explorer=new Explorer(root,(type,payload,requestIdentifier)=>{const id=requestIdentifier??String(++n);sent.push({type,payload,id});return id;},key=>key);
 explorer.receive('context',{token:'x',rootDirectory:'/r',title:'repo'});
 const request=sent.find(x=>x.type==='listDirectory');assert.ok(request);
 explorer.receive('listing',{token:'x',requestIdentifier:request.id,directoryPath:'/r',entries:[{path:'/r/<b>.txt',name:'<b>.txt',isDirectory:false}]});
 const row=root.querySelector('[data-path]');assert.ok(row);assert.equal(row.textContent.includes('<b>.txt'),true);assert.equal(row.querySelector('b'),null);
 row.dispatchEvent(new w.MouseEvent('click',{bubbles:true}));assert.equal(row.isConnected,true);assert.equal(sent.filter(x=>x.type==='openFile').at(-1).payload.activation,'preview');
 row.dispatchEvent(new w.MouseEvent('dblclick',{bubbles:true}));assert.equal(sent.filter(x=>x.type==='openFile').at(-1).payload.activation,'pinned');
 root.querySelector('[data-mode="contents"]').click();const query=root.querySelector('[data-query="contents"]');query.value='hello';
 query.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Enter',isComposing:true,bubbles:true}));assert.notEqual(sent.at(-1).type,'searchContents');
 query.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Enter',bubbles:true}));assert.equal(sent.at(-1).type,'searchContents');assert.equal(sent.at(-1).payload.query.text,'hello');
 explorer.dispose();w.happyDOM.abort();
});
test('a directory error offers retry and does not masquerade as an empty folder',()=>{
 const w=new Window();globalThis.document=w.document;globalThis.window=w;globalThis.requestAnimationFrame=fn=>fn();const root=document.createElement('div');document.body.append(root);const sent=[];
 const explorer=new Explorer(root,(type,payload,id)=>{sent.push({type,payload,id});return id;},key=>key);
 explorer.receive('context',{token:'a',rootDirectory:'/r',title:'repo'});const request=sent.find(x=>x.type==='listDirectory');
 explorer.receive('listing',{token:'a',requestIdentifier:request.id,directoryPath:'/r',entries:[],error:'Cannot read folder'});
 assert.match(root.querySelector('[role="status"]').textContent,/Cannot read folder/);
 root.querySelector('[data-retry]').click();assert.equal(sent.at(-1).type,'listDirectory');assert.equal(sent.at(-1).payload.directoryPath,'/r');explorer.dispose();w.happyDOM.abort();
});
function fixture() {
 const w=new Window();globalThis.document=w.document;globalThis.window=w;globalThis.requestAnimationFrame=fn=>fn();
 const root=document.createElement('div');document.body.append(root);const sent=[];
 const explorer=new Explorer(root,(type,payload,id=crypto.randomUUID())=>{sent.push({type,payload,id});return id;},key=>key);
 const listing=(request,entries)=>explorer.receive('listing',{token:'scope',requestIdentifier:request.id,directoryPath:request.payload.directoryPath,entries});
 explorer.receive('context',{token:'scope',rootDirectory:'/r',title:'repo'});
 return {w,root,sent,explorer,listing,close(){explorer.dispose();w.happyDOM.abort();}};
}
test('Contents keys follow the focused result and never mutate a hidden Names selection',()=>{
 const f=fixture();try {
  f.listing(f.sent.find(x=>x.type==='listDirectory'),[{path:'/r/a',name:'a',isDirectory:false}]);
  f.root.querySelector('[data-path]').click();f.root.querySelector('[data-mode="contents"]').click();
  const query=f.root.querySelector('[data-query="contents"]');query.value='b';query.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
  const search=f.sent.findLast(x=>x.type==='searchContents');
  f.explorer.receive('search',{token:'scope',requestIdentifier:search.id,matches:[{path:'/r/b',relativePath:'b',lines:[{lineNumber:7,snippet:'bee',snippetColumn:0,ranges:[{location:1,length:1}]}]}],isComplete:true});
  const result=f.root.querySelector('.result-match');result.focus();const start=f.sent.length;
  for(const [key,metaKey] of [['Delete',false],['Backspace',true]])result.dispatchEvent(new f.w.KeyboardEvent('keydown',{key,metaKey,bubbles:true,cancelable:true}));
  assert.equal(f.sent.slice(start).some(x=>['trash','rename'].includes(x.type)),false);
  result.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
  const opened=f.sent.findLast(x=>x.type==='openFile');assert.equal(opened.payload.path,'/r/b');assert.equal(opened.payload.lineNumber,7);
  result.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:'ArrowUp',bubbles:true,cancelable:true}));
  assert.equal(document.activeElement.classList.contains('result-group'),true);
  assert.equal(f.sent.slice(start).some(x=>x.payload.paths?.includes('/r/a')||x.payload.path==='/r/a'),false);
 } finally {f.close();}
});
test('refresh rejects stale requests and reloads retained nested expansions as parents arrive',()=>{
 const f=fixture();try {
  const directory={path:'/r/d',name:'d',isDirectory:true,isExpandable:true};const nested={path:'/r/d/n',name:'n',isDirectory:true,isExpandable:true};
  f.listing(f.sent.find(x=>x.type==='listDirectory'),[directory]);f.root.querySelector('[data-path="/r/d"]').click();
  f.listing(f.sent.findLast(x=>x.type==='listDirectory'),[nested]);f.root.querySelector('[data-path="/r/d/n"]').click();
  const stale=f.sent.findLast(x=>x.type==='listDirectory');f.explorer.refresh();const root=f.sent.findLast(x=>x.type==='listDirectory');
  f.listing(stale,[{path:'/r/d/n/old',name:'old'}]);f.listing(root,[directory]);
  const child=f.sent.findLast(x=>x.type==='listDirectory');assert.equal(child.payload.directoryPath,'/r/d');assert.notEqual(child.id,stale.id);
  f.listing(child,[nested]);const reload=f.sent.findLast(x=>x.type==='listDirectory');assert.equal(reload.payload.directoryPath,'/r/d/n');assert.notEqual(reload.id,stale.id);
  f.listing(reload,[{path:'/r/d/n/new',name:'new'}]);assert.ok(f.root.querySelector('[data-path="/r/d/n/new"]'));assert.equal(f.root.querySelector('[data-path="/r/d/n/old"]'),null);
 } finally {f.close();}
});
test('focusQuery selects and reveals both query modes before focusing',()=>{
 const f=fixture();try {
  f.explorer.receive('focusQuery',{contents:true});assert.equal(document.activeElement.dataset.query,'contents');assert.equal(document.activeElement.parentElement.hidden,false);
  f.explorer.receive('focusQuery',{contents:false});assert.equal(document.activeElement.dataset.query,'names');assert.equal(document.activeElement.parentElement.hidden,false);
 } finally {f.close();}
});
test('result group activation retains focus for the next navigation key',()=>{
 const f=fixture();try {
  f.root.querySelector('[data-mode="contents"]').click();const query=f.root.querySelector('[data-query="contents"]');query.value='match';query.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
  const search=f.sent.findLast(x=>x.type==='searchContents');f.explorer.receive('search',{token:'scope',requestIdentifier:search.id,matches:['a','b'].map(name=>({path:'/r/'+name,relativePath:name,lines:[{lineNumber:1,snippet:name,snippetColumn:0,ranges:[{location:0,length:1}]}]})),isComplete:true});
  f.root.querySelector('.result-group').focus();document.activeElement.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
  assert.equal(document.activeElement.isConnected,true);assert.equal(document.activeElement.classList.contains('result-group'),true);assert.equal(document.activeElement.textContent,'a');
  document.activeElement.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));assert.equal(document.activeElement.textContent,'b');
  document.activeElement.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:' ',bubbles:true,cancelable:true}));assert.equal(document.activeElement.textContent,'b');
 }finally{f.close();}
});
test('a real scroll rerender preserves the PageDown target for subsequent keys',()=>{
 const f=fixture();try {
  f.root.querySelector('[data-mode="contents"]').click();const query=f.root.querySelector('[data-query="contents"]');query.value='match';query.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
  const search=f.sent.findLast(x=>x.type==='searchContents');f.explorer.receive('search',{token:'scope',requestIdentifier:search.id,matches:[{path:'/r/b',relativePath:'b',lines:Array.from({length:100},(_,index)=>({lineNumber:index+1,snippet:'match',snippetColumn:0,ranges:[{location:0,length:5}]}))}],isComplete:true});
  f.root.querySelector('.result-match').focus();document.activeElement.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:'PageDown',bubbles:true,cancelable:true}));
  assert.ok(f.explorer.viewport.scrollTop>0);f.explorer.viewport.dispatchEvent(new f.w.Event('scroll'));
  assert.equal(document.activeElement.isConnected,true);assert.equal(document.activeElement.classList.contains('result-match'),true);assert.equal(document.activeElement.querySelector('.line-number').textContent,'11');
  document.activeElement.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true,cancelable:true}));document.activeElement.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
  const opened=f.sent.findLast(x=>x.type==='openFile');assert.equal(opened.payload.path,'/r/b');assert.equal(opened.payload.lineNumber,12);
 }finally{f.close();}
});
test('recent owner contexts retain queries and expansions with bounded RAM cache',()=>{
 const w=new Window();globalThis.document=w.document;globalThis.window=w;globalThis.requestAnimationFrame=fn=>fn();const root=document.createElement('div');document.body.append(root);const sent=[];
 const e=new Explorer(root,(type,payload,id)=>{sent.push({type,payload,id});return id;},key=>key);
 e.receive('context',{token:'a',rootDirectory:'/a',projectIdentifier:'p',worktreeIdentifier:'w'});e.names.value='needle';e.state.expanded.add('/a/dir');
 e.receive('context',{token:'b',rootDirectory:'/b',projectIdentifier:'p',worktreeIdentifier:'w'});
 e.receive('context',{token:'c',rootDirectory:'/a',projectIdentifier:'p',worktreeIdentifier:'w'});
 assert.equal(e.names.value,'needle');assert.ok(e.state.expanded.has('/a/dir'));assert.equal(e.state.scope.token,'c');
 for(let i=0;i<8;i++)e.receive('context',{token:String(i),rootDirectory:'/root'+i,projectIdentifier:'p',worktreeIdentifier:'w'});
 assert.ok(e.recentContexts.size<=4);e.dispose();w.happyDOM.abort();
});
test('context changes invalidate retained create forms and detached menu callbacks',()=>{
 for(const sameRoot of [false,true])for(const kind of ['createFile','createFolder']) {
  const f=fixture();try {
   f.explorer.inline(kind,null);const form=f.explorer.form;form.querySelector('input').value='old-intent';
   f.explorer.receive('context',{token:'next',rootDirectory:sameRoot?'/r':'/other',projectIdentifier:'new-owner',worktreeIdentifier:'new-tree'});
   const before=f.sent.length;form.dispatchEvent(new f.w.Event('submit',{bubbles:true,cancelable:true}));
   assert.equal(f.sent.slice(before).some(message=>message.type===kind),false);assert.equal(f.root.querySelector('.inline-input'),null);
   f.explorer.menu(new f.w.MouseEvent('contextmenu'),null);const menu=f.explorer.menuNode;const button=menu.querySelector('button');
   f.explorer.receive('context',{token:'third',rootDirectory:sameRoot?'/r':'/third',projectIdentifier:'third-owner',worktreeIdentifier:'new-tree'});
   button.click();assert.equal(f.root.querySelector('.inline-input'),null);assert.equal(f.explorer.menuNode===null,true);
  }finally{f.close();}
 }
});
test('disposing a suspended explorer releases the shared root for its next renderer owner',()=>{
 const f=fixture();try {
  f.explorer.beginContextTransition();assert.equal(f.root.inert,true);
  f.explorer.dispose();assert.equal(f.root.inert,false);assert.equal(f.root.children.length,0);
 }finally{f.close();}
});
test('undo remains available after the last row disappears and in Contents mode',()=>{
 const f=fixture();try {
  f.listing(f.sent.find(x=>x.type==='listDirectory'),[]);
  for(const mode of ['names','contents']) {
   f.explorer.setMode(mode);const before=f.sent.length;
   f.explorer.viewport.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:'z',metaKey:true,bubbles:true,cancelable:true}));
   f.explorer.viewport.dispatchEvent(new f.w.KeyboardEvent('keydown',{key:'z',metaKey:true,shiftKey:true,bubbles:true,cancelable:true}));
   assert.deepEqual(f.sent.slice(before).map(message=>message.type),['undo','redo']);
  }
 }finally{f.close();}
});
test('oversized UTF8 queries and filters report errors without a pending request and recover on correction',()=>{
 for(const mode of ['names','contents'])for(const invalid of ['a'.repeat(2049),'😀'.repeat(513)]) {
  const f=fixture();try {
   f.listing(f.sent.find(x=>x.type==='listDirectory'),[]);f.explorer.setMode(mode);
   const input=mode==='names'?f.explorer.names:f.explorer.contents;input.value=invalid;const before=f.sent.length;f.explorer.search(mode);
   assert.equal(f.sent.slice(before).some(message=>['searchNames','searchContents'].includes(message.type)),false);
   assert.equal(f.explorer.state.searching,false);assert.equal(f.explorer.status.textContent,'searchTooLong');
   input.value='valid';f.explorer.search(mode);assert.equal(f.sent.at(-1).type,mode==='names'?'searchNames':'searchContents');assert.equal(f.explorer.state.searching,true);
  }finally{f.close();}
 }
 const f=fixture();try {
  f.explorer.setMode('contents');f.explorer.contents.value='valid';f.explorer.include.value='a'.repeat(2049);const before=f.sent.length;f.explorer.search('contents');
  assert.equal(f.sent.slice(before).some(message=>message.type==='searchContents'),false);assert.equal(f.explorer.state.searching,false);assert.equal(f.explorer.status.textContent,'searchTooLong');
 }finally{f.close();}
});
test('filesystem events refresh only loaded visible directories without clearing rows or showing Loading',()=>{
 const f=fixture();try {
  const dir={path:'/r/src',name:'src',isDirectory:true,isExpandable:true};
  f.listing(f.sent.find(x=>x.type==='listDirectory'),[dir,{path:'/r/Library',name:'Library',isDirectory:true,isExpandable:true}]);
  f.root.querySelector('[data-path="/r/src"]').click();f.listing(f.sent.findLast(x=>x.type==='listDirectory'),[{path:'/r/src/a',name:'a',isDirectory:false}]);
  f.root.querySelector('[data-path="/r/src/a"]').click();const stable=f.root.querySelector('[data-path="/r/src/a"]');const start=f.sent.length;
  f.explorer.receive('filesystemChanges',{token:'scope',paths:['/r/Library/Caches/background.log','/r/.hidden','/other/a']});
  assert.equal(f.sent.length,start);assert.equal(f.root.querySelector('[data-path="/r/src/a"]'),stable);assert.notEqual(f.explorer.status.textContent,'loading');
  f.explorer.receive('filesystemChanges',{token:'scope',paths:['/r/src/new','/r/src/a']});
  assert.deepEqual(f.sent.slice(start).map(x=>[x.type,x.payload.directoryPath]),[['listDirectory','/r/src']]);
  assert.ok(f.root.querySelector('[data-path="/r/src/a"]'));assert.equal(f.root.querySelector('[data-path="/r/src/a"]').getAttribute('aria-selected'),'true');
  assert.notEqual(f.explorer.status.textContent,'loading');
  f.explorer.receive('filesystemChanges',{token:'scope',paths:['/r/src/another']});
  assert.equal(f.sent.length,start+1);
  f.listing(f.sent.at(-1),[{path:'/r/src/a',name:'a',isDirectory:false},{path:'/r/src/new',name:'new',isDirectory:false}]);
  assert.ok(f.root.querySelector('[data-path="/r/src/new"]'));assert.equal(f.sent.length,start+2);
 }finally{f.close();}
});
test('collapsed directory changes evict stale cached contents without fetching until expansion',()=>{
 const f=fixture();try {
  const dir={path:'/r/d',name:'d',isDirectory:true,isExpandable:true};f.listing(f.sent.find(x=>x.type==='listDirectory'),[dir]);
  f.root.querySelector('[data-path="/r/d"]').click();f.listing(f.sent.findLast(x=>x.type==='listDirectory'),[{path:'/r/d/old',name:'old'}]);
  f.root.querySelector('[data-path="/r/d"]').click();const before=f.sent.length;
  f.explorer.receive('filesystemChanges',{token:'scope',paths:['/r/d/new']});assert.equal(f.sent.length,before);
  f.root.querySelector('[data-path="/r/d"]').click();assert.equal(f.sent.at(-1).type,'listDirectory');assert.equal(f.sent.at(-1).payload.directoryPath,'/r/d');
 }finally{f.close();}
});
test('removing an expanded directory rejects its pending and cached child listings',()=>{
 const f=fixture();try {
  const dir={path:'/r/src',name:'src',isDirectory:true,isExpandable:true};f.listing(f.sent.find(x=>x.type==='listDirectory'),[dir]);
  f.root.querySelector('[data-path="/r/src"]').click();f.listing(f.sent.findLast(x=>x.type==='listDirectory'),[{path:'/r/src/a',name:'a'}]);
  f.explorer.receive('filesystemChanges',{token:'scope',paths:['/r/src/a']});const stale=f.sent.at(-1);
  f.explorer.receive('filesystemChanges',{token:'scope',paths:['/r/src']});const parent=f.sent.findLast(x=>x.payload.directoryPath==='/r');f.listing(parent,[]);
  f.explorer.receive('listing',{token:'scope',requestIdentifier:stale.id,directoryPath:'/r/src',entries:[],error:'Missing directory'});
  assert.equal(f.root.querySelector('[data-path="/r/src"]'),null);assert.notEqual(f.explorer.status.textContent,'Missing directory');assert.equal(f.root.querySelector('[data-retry]'),null);
 }finally{f.close();}
});
test('Git metadata rescans the loaded subtree without refreshing a collapsed parent',()=>{
 const f=fixture();try {
  const dir={path:'/r/repo',name:'repo',isDirectory:true,isExpandable:true};f.listing(f.sent.find(x=>x.type==='listDirectory'),[dir]);const before=f.sent.length;
  f.explorer.receive('filesystemChanges',{token:'scope',paths:[],rescanDirectories:['/r/repo']});assert.equal(f.sent.length,before);
  f.root.querySelector('[data-path="/r/repo"]').click();f.listing(f.sent.findLast(x=>x.type==='listDirectory'),[{path:'/r/repo/a',name:'a'}]);const expanded=f.sent.length;
  f.explorer.receive('filesystemChanges',{token:'scope',paths:[],rescanDirectories:['/r/repo']});
  assert.deepEqual(f.sent.slice(expanded).map(x=>x.payload.directoryPath),['/r/repo']);
 }finally{f.close();}
});
test('menus close on outside pointer events even when another control stops bubbling',()=>{
 const f=fixture();try {
  f.explorer.more(new f.w.MouseEvent('click',{clientX:100,clientY:30}));const menu=f.explorer.menuNode;assert.ok(menu);
  const outside=document.createElement('div');document.body.append(outside);outside.addEventListener('pointerdown',event=>event.stopPropagation());
  outside.dispatchEvent(new f.w.PointerEvent('pointerdown',{bubbles:true}));assert.equal(f.explorer.menuNode===null,true);assert.equal(menu.isConnected,false);
 }finally{f.close();}
});
test('native focus changes and browser blur dismiss menus without activating an item',()=>{
 const f=fixture();try {
  for(const close of [()=>f.explorer.receive('dismissMenu',{}),()=>f.w.dispatchEvent(new f.w.Event('blur'))]) {
   f.explorer.more(new f.w.MouseEvent('click',{clientX:100,clientY:30}));const before=f.sent.length;
   close();assert.equal(f.explorer.menuNode===null,true);assert.equal(f.sent.length,before);
  }
 }finally{f.close();}
});
test('expanding a directory preserves existing row nodes and scroll position while loading only its children',()=>{
 const f=fixture();try {
  f.listing(f.sent.find(x=>x.type==='listDirectory'),[{path:'/r/d',name:'d',isDirectory:true,isExpandable:true},{path:'/r/sibling',name:'sibling',isDirectory:false}]);
  const directory=f.root.querySelector('[data-path="/r/d"]'),sibling=f.root.querySelector('[data-path="/r/sibling"]');f.explorer.viewport.scrollTop=50;const before=f.sent.length;
  directory.click();assert.equal(f.root.querySelector('[data-path="/r/d"]')===directory,true);assert.equal(f.root.querySelector('[data-path="/r/sibling"]')===sibling,true);
  assert.notEqual(f.explorer.status.textContent,'loading');assert.equal(f.explorer.viewport.scrollTop,50);
  assert.deepEqual(f.sent.slice(before).filter(x=>x.type==='listDirectory').map(x=>x.payload.directoryPath),['/r/d']);
  f.listing(f.sent.findLast(x=>x.type==='listDirectory'),[{path:'/r/d/child',name:'child',isDirectory:false}]);
  assert.equal(f.root.querySelector('[data-path="/r/d"]')===directory,true);assert.equal(f.root.querySelector('[data-path="/r/sibling"]')===sibling,true);assert.equal(f.explorer.viewport.scrollTop,50);
  assert.ok(f.root.querySelector('[data-path="/r/d/child"]'));directory.click();assert.equal(f.root.querySelector('[data-path="/r/sibling"]')===sibling,true);
 }finally{f.close();}
});
