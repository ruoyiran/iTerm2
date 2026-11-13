import {setUILocale} from './portable/local-state.ts';
import {applyLegacyStyles} from './portable/webkit-compatibility.mjs';
import {DocumentTransfers} from './document-transfers.mjs';
import '../css/orca-generated.css';
import '../css/workspace.css';
import {MessageBridge} from './bridge.mjs';
import {Explorer} from './explorer.mjs';
const themeQuery=matchMedia('(prefers-color-scheme: dark)');const applyTheme=()=>{document.documentElement.classList.toggle('dark',themeQuery.matches);applyLegacyStyles(themeQuery.matches)};applyTheme();themeQuery.addEventListener('change',applyTheme);
const post=message=>window.webkit.messageHandlers.fileWorkspace.postMessage(message);
const bridge=new MessageBridge(post);const root=document.getElementById('workspace');let surface=null,configuration=0;const transfers=new Map(),documents=new DocumentTransfers();
window.fileWorkspace={async receive(message){
 if(message.type==='configure') {
  const version=++configuration;const keepExplorer=message.payload.purpose==='explorer'&&surface instanceof Explorer&&bridge.identity?.viewIdentifier===message.viewIdentifier;if(keepExplorer)surface.beginContextTransition();else{surface?.dispose();surface=null;}transfers.clear();documents.reset();bridge.configure(message);
  setUILocale(message.payload.locale??'en');const t=key=>message.payload.labels?.[key]??key;const send=(type,payload,id)=>bridge.send(type,payload,id);
  if(message.payload.purpose==='editor'){const {FileEditor}=await import('./editor.mjs');if(version!==configuration)return;surface=new FileEditor(root,send,t);}else if(!keepExplorer)surface=new Explorer(root,send,t);
  bridge.send('ready',{});return;
 }
 if(!bridge.accept(message)||!surface)return;
 if(['documentStart','documentText','documentEnd'].includes(message.type)){const assembled=documents.receive(message.type,message.payload);if(message.type==='documentStart'&&message.payload.snapshot&&documents.transfers.get(message.payload.transferIdentifier)?.snapshot===message.payload.snapshot)surface.beginDocument?.(message.payload.snapshot.documentIdentifier);if(assembled)await surface.receive('document',assembled,message.requestIdentifier);return;}
 if(message.type==='chunk') {
  const p=message.payload;if(!Number.isSafeInteger(p.index)||!Number.isSafeInteger(p.total)||p.total<1||p.total>4096||typeof p.text!=='string'||p.text.length>262144)return;
  let transfer=transfers.get(p.identifier);if(p.index===0){if(transfers.size>=2)return;transfer={parts:[],total:p.total,length:0};transfers.set(p.identifier,transfer);}
  if(!transfer||p.index!==transfer.parts.length||p.total!==transfer.total){transfers.delete(p.identifier);return;}if(transfer.length+p.text.length>300*1024*1024){transfers.delete(p.identifier);return;}transfer.parts.push(p.text);transfer.length+=p.text.length;
  if(transfer.parts.length===transfer.total){transfers.delete(p.identifier);await this.receive(JSON.parse(transfer.parts.join('')));}return;
 }
 await surface.receive(message.type,message.payload,message.requestIdentifier);
}};
post({type:'bootstrap',protocolVersion:1});
