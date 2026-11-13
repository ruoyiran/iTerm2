import '../css/workspace.css';
import {MessageBridge} from './bridge.mjs';
import {Explorer} from './explorer.mjs';
const post=message=>window.webkit.messageHandlers.fileWorkspace.postMessage(message);
const bridge=new MessageBridge(post);const root=document.getElementById('workspace');let surface=null,configuration=0;const transfers=new Map();
window.fileWorkspace={async receive(message){
 if(message.type==='configure') {
  const version=++configuration;const keepExplorer=message.payload.purpose==='explorer'&&surface instanceof Explorer&&bridge.identity?.viewIdentifier===message.viewIdentifier;if(keepExplorer)surface.beginContextTransition();else{surface?.dispose();surface=null;}transfers.clear();bridge.configure(message);
  const t=key=>message.payload.labels?.[key]??key;const send=(type,payload,id)=>bridge.send(type,payload,id);
  if(message.payload.purpose==='editor'){const {FileEditor}=await import('./editor.mjs');if(version!==configuration)return;surface=new FileEditor(root,send,t);}else if(!keepExplorer)surface=new Explorer(root,send,t);
  bridge.send('ready',{});return;
 }
 if(!bridge.accept(message)||!surface)return;
 if(message.type==='chunk') {
  const p=message.payload;if(!Number.isSafeInteger(p.index)||!Number.isSafeInteger(p.total)||p.total<1||p.total>256||typeof p.text!=='string'||p.text.length>262144)return;
  let transfer=transfers.get(p.identifier);if(p.index===0){if(transfers.size>=2)return;transfer={parts:[],total:p.total};transfers.set(p.identifier,transfer);}
  if(!transfer||p.index!==transfer.parts.length||p.total!==transfer.total){transfers.delete(p.identifier);return;}transfer.parts.push(p.text);
  if(transfer.parts.length===transfer.total){transfers.delete(p.identifier);await this.receive(JSON.parse(transfer.parts.join('')));}return;
 }
 await surface.receive(message.type,message.payload,message.requestIdentifier);
}};
post({type:'bootstrap',protocolVersion:1});
