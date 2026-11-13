import test from 'node:test';
import assert from 'node:assert/strict';
import { DocumentSync, RawText } from '../../../sources/FileWorkspace/Resources/src/document-sync.mjs';
test('normalized edits preserve untouched mixed line endings and UTF16 offsets', () => {
 const raw = new RawText('a\r\n😀b\rc\n');
 assert.equal(raw.normalized, 'a\n😀b\nc\n');
 const edits = raw.applyModelChanges([{rangeOffset:4, rangeLength:1, text:'B'}]);
 assert.deepEqual(edits,[{location:5,length:1,replacement:'B'}]);
 assert.equal(raw.text,'a\r\n😀B\rc\n');
 raw.applyModelChanges([{rangeOffset:5,rangeLength:0,text:'\nx'}]);
 assert.equal(raw.text,'a\r\n😀B\r\nx\rc\n');
});
test('surrogate boundaries and overlapping edits are rejected atomically', () => {
 const raw=new RawText('😀abcd');
 assert.throws(()=>raw.applyModelChanges([{rangeOffset:1,rangeLength:0,text:'x'}]));
 assert.throws(()=>raw.applyModelChanges([{rangeOffset:2,rangeLength:2,text:'x'},{rangeOffset:3,rangeLength:1,text:'y'}]));
 assert.equal(raw.text,'😀abcd');
});
test('one transaction in flight, ordered acknowledgments and composition barrier', async () => {
 const sent=[];const sync=new DocumentSync({send:x=>sent.push(x)});
 sync.open({documentIdentifier:'doc',revision:'9007199254740993',text:'a'});
 sync.change([{rangeOffset:1,rangeLength:0,text:'b'}]);
 sync.change([{rangeOffset:2,rangeLength:0,text:'c'}]);
 assert.equal(sent.length,1);assert.equal(sent[0].expectedRevision,'9007199254740993');
 let done=false;sync.composing=true;const barrier=sync.flush(true).then(()=>done=true);
 sync.ack({sequence:'1',revision:'9007199254740994'});assert.equal(sent.length,2);
 sync.ack({sequence:'2',revision:'9007199254740995'});
 await Promise.resolve();assert.equal(done,false);
 sync.endComposition();await barrier;assert.equal(done,true);assert.equal(sync.raw.text,'abc');
 assert.throws(()=>sync.change([{rangeOffset:3,rangeLength:0,text:'d'}]));
});
test('stale acknowledgment never discards local edits', () => {
 const sync=new DocumentSync({send:()=>{}});sync.open({documentIdentifier:'d',revision:'3',text:'x'});
 sync.change([{rangeOffset:1,rangeLength:0,text:'y'}]);
 assert.throws(()=>sync.ack({sequence:'9',revision:'4'}));
 assert.equal(sync.raw.text,'xy');assert.equal(sync.hasPendingEdits,true);
});
test('a paste preserves its own line separators while typing uses document separators',()=>{
 const raw=new RawText('a\r\nb');
 raw.applyModelChanges([{rangeOffset:1,rangeLength:0,text:'x\ny\nz',rawText:'x\ny\rz'}]);
 assert.equal(raw.text,'ax\ny\rz\r\nb');
});
