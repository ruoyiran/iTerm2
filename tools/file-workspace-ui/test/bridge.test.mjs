import test from 'node:test';import assert from 'node:assert/strict';
import {MessageBridge} from '../../../sources/FileWorkspace/Resources/src/bridge.mjs';
test('renderer/context fences reject stale replies and JSON values remain data',()=>{
 const out=[];const bridge=new MessageBridge(x=>out.push(x));
 bridge.configure({rendererEpoch:'e',viewIdentifier:'v',contextToken:'a',generation:'9007199254740999'});
 const id=bridge.send('openFile',{path:'/root/<script>.txt'});
 assert.equal(out[0].payload.path,'/root/<script>.txt');assert.equal(out[0].generation,'9007199254740999');
 assert.equal(bridge.accept({...out[0],contextToken:'old'}),false);
 assert.equal(bridge.accept({...out[0],requestIdentifier:id}),true);
 assert.equal(bridge.accept({...out[0],protocolVersion:2}),false);
});
test('large messages split at Unicode boundaries and reassemble exactly',()=>{
 const out=[];const bridge=new MessageBridge(x=>out.push(x));bridge.configure({rendererEpoch:'e',viewIdentifier:'v',contextToken:'t',generation:'1'});
 const text='a'.repeat(131000)+'😀'.repeat(100000);bridge.send('edits',{text});
 assert.ok(out.length>1);assert.ok(out.every(x=>x.type==='chunkNative'));
 const message=JSON.parse(out.map(x=>x.payload.text).join(''));assert.equal(message.payload.text,text);
 assert.ok(out.every(x=>!/[\uD800-\uDBFF]$/.test(x.payload.text)));
});
