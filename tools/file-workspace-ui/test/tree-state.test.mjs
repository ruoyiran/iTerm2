import test from 'node:test';import assert from 'node:assert/strict';
import {TreeState,snippetParts} from '../../../sources/FileWorkspace/Resources/src/tree-state.mjs';
const ctx={token:'a',rootDirectory:'/root'};
const entries=[{path:'/root/a',name:'a',isDirectory:true,isExpandable:true},{path:'/root/b',name:'b',isDirectory:false}];
test('context change retires loading, rejects old listings and resets selection',()=>{
 const s=new TreeState();s.context(ctx);s.begin('r','/root');s.context({token:'b',rootDirectory:'/other'});
 assert.equal(s.listing('a','r','/root',entries),false);assert.equal(s.pending.size,0);assert.deepEqual(s.rows(),[]);
});
test('lazy projection and range selection include visible descendants',()=>{
 const s=new TreeState();s.context(ctx);s.begin('r','/root');s.listing('a','r','/root',entries);
 assert.equal(s.rows().length,2);s.toggle('/root/a');s.begin('c','/root/a');s.listing('a','c','/root/a',[{path:'/root/a/x',name:'x'}]);
 s.select('/root/a','replace');s.select('/root/b','range');assert.deepEqual([...s.selected],['/root/a','/root/a/x','/root/b']);
 s.toggle('/root/a');assert.equal(s.rows().length,2);assert.equal(s.selected.size,3);
});
test('search batches merge repeated groups, clip highlights and reject old request',()=>{
 const s=new TreeState();s.context(ctx);s.startSearch('query');
 s.search('a','query',{matches:[{path:'/root/b',relativePath:'b',lines:[{lineNumber:1,snippet:'abc',snippetColumn:100,ranges:[{location:99,length:2}]}]}]});
 s.search('a','query',{matches:[{path:'/root/b',relativePath:'b',lines:[{lineNumber:2,snippet:'def',snippetColumn:0,ranges:[]}]}],isComplete:true});
 assert.equal(s.matches.get('/root/b').lines.length,2);
 assert.deepEqual(snippetParts('abc',[{location:99,length:2}],100),[{text:'a',match:true},{text:'bc',match:false}]);
 assert.equal(s.search('a','old',{matches:[]}),false);
});
