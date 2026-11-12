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
