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
