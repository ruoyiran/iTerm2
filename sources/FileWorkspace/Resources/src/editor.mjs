import * as monaco from 'monaco-editor/esm/vs/editor/editor.main.js';
import {DocumentSync} from './document-sync.mjs';
import {element,button} from './explorer.mjs';
globalThis.MonacoEnvironment={getWorker(_id,label){const name=label==='json'?'json':['css','scss','less'].includes(label)?'css':['html','handlebars','razor'].includes(label)?'html':['typescript','javascript'].includes(label)?'ts':'editor';return new Worker(new URL(`./workers/${name}.worker.js`,location.href),{type:'module'});}};
monaco.languages.typescript?.typescriptDefaults.setDiagnosticsOptions({noSemanticValidation:true,noSyntaxValidation:true,noSuggestionDiagnostics:true});
monaco.languages.typescript?.javascriptDefaults.setDiagnosticsOptions({noSemanticValidation:true,noSyntaxValidation:true,noSuggestionDiagnostics:true});
const models=new Map();
export class FileEditor {
 constructor(root,send,t) {
  this.root=root;this.send=send;this.t=t;this.suppress=false;this.authorized=false;this.readOnly=true;this.sync=new DocumentSync({send:payload=>send('edits',payload),changed:()=>this.status()});
  root.className='editor-shell';const toolbar=element('div','editor-toolbar');this.title=element('span','editor-title');toolbar.append(this.title);
  this.buttons=new Map();for(const [command,symbol] of [['save','save'],['saveAs','save-all'],['undo','undo-2'],['redo','redo-2'],['find','search'],['toggleMarkdownPreview','eye'],['pin','pin']]){const control=button(t(command),()=>this.command(command),symbol);toolbar.append(control);this.buttons.set(command,control);}
  this.error=element('div','editor-error');this.error.hidden=true;this.container=element('div','editor-container');this.footer=element('div','editor-status');root.replaceChildren(toolbar,this.error,this.container,this.footer);
  this.editor=monaco.editor.create(this.container,{model:null,automaticLayout:true,readOnly:true,fontFamily:'SF Mono, Menlo, monospace',fontSize:13,minimap:{enabled:false},scrollBeyondLastLine:false,renderWhitespace:'selection',contextmenu:false,theme:matchMedia('(prefers-color-scheme: dark)').matches?'vs-dark':'vs',padding:{top:8},ariaLabel:t('editor')});
  this.subscriptions=[this.editor.onDidChangeModelContent(event=>{if(this.suppress)return;try{const changes=event.changes.map(change=>({...change,rawText:event.changes.length===1?this.rawPaste:undefined}));this.rawPaste=null;this.sync.change(changes);this.send('pin',{});}catch(error){this.failure(error);}}),this.editor.onDidFocusEditorText(()=>this.send('focus',{})),this.editor.onDidChangeCursorSelection(()=>this.viewState()),this.editor.onDidScrollChange(()=>this.viewState())];
  this.onCompositionStart=()=>{this.sync.composing=true;this.status();};this.onCompositionEnd=()=>{this.sync.endComposition();if(this.sync.suspended)this.editor.updateOptions({readOnly:true});};this.container.addEventListener('compositionstart',this.onCompositionStart);this.container.addEventListener('compositionend',this.onCompositionEnd);
  this.key=e=>{if(e.isComposing||this.sync.composing)return;if(e.metaKey||e.ctrlKey){const key=e.key.toLowerCase();const command=key==='s'?(e.shiftKey?'saveAs':'save'):key==='z'?(e.shiftKey?'redo':'undo'):key==='f'?'find':null;if(command){e.preventDefault();e.stopImmediatePropagation();this.command(command);}}};this.container.addEventListener('keydown',this.key,true);
  this.pasteHandler=e=>{if(this.readOnly||!this.authorized)return;const text=e.clipboardData?.getData('text/plain');if(text!==undefined){e.preventDefault();this.paste(text);}};this.container.addEventListener('paste',this.pasteHandler,true);
  this.context=e=>{e.preventDefault();this.send('editorContextMenu',{});};this.container.addEventListener('contextmenu',this.context);
 }
 command(command) {if(command==='find'){this.editor.getAction('actions.find').run();return;}if(command==='findNext'){this.editor.getAction('editor.action.nextMatchFindAction').run();return;}if(command==='findPrevious'){this.editor.getAction('editor.action.previousMatchFindAction').run();return;}if(command==='selectAll'){this.editor.setSelection(this.editor.getModel().getFullModelRange());return;}this.send('command',{command});}
 document(snapshot,edits) {
  const changed=this.sync.documentIdentifier!==snapshot.documentIdentifier;
  if(changed){this.sync.open(snapshot);this.setModel(snapshot);}else if(this.sync.remote(snapshot,edits))this.replaceModel();
  this.readOnly=!!snapshot.isReadOnly;this.title.textContent=(snapshot.filePath??'').split('/').pop();this.editor.updateOptions({readOnly:this.readOnly||!this.authorized});for(const command of ['save','undo','redo'])this.buttons.get(command).disabled=this.readOnly;this.buttons.get('toggleMarkdownPreview').disabled=snapshot.kind!==1;this.status();
 }
 setModel(snapshot) {
  const id=snapshot.documentIdentifier;let model=models.get(id);if(!model){const extension='.'+(snapshot.filePath??'').split('.').pop();const language=monaco.languages.getLanguages().find(x=>x.extensions?.includes(extension))?.id??'plaintext';model=monaco.editor.createModel(this.sync.raw.normalized,language,monaco.Uri.parse(`inmemory://file/${id}`));models.set(id,model);}
  this.suppress=true;try{model.setEOL(monaco.editor.EndOfLineSequence.LF);if(model.getValue()!==this.sync.raw.normalized)model.setValue(this.sync.raw.normalized);this.editor.setModel(model);}finally{this.suppress=false;}
  let bytes=0;for(const m of models.values())bytes+=m.getValueLength()*2;for(const [key,m] of models){if(models.size<=8&&bytes<=32*1024*1024)break;if(key===id)continue;bytes-=m.getValueLength()*2;m.dispose();models.delete(key);}
 }
 replaceModel(){const state=this.editor.saveViewState();this.suppress=true;try{this.editor.getModel().setValue(this.sync.raw.normalized);if(state)this.editor.restoreViewState(state);}finally{this.suppress=false;}}
 status(){if(!this.sync.raw)return;this.send('status',{hasPendingEdits:this.sync.hasPendingEdits,isComposing:this.sync.composing,hasSelection:!this.editor.getSelection()?.isEmpty()});this.footer.textContent=this.sync.error?this.t('syncError'):this.readOnly?this.t('readOnly'):this.sync.hasPendingEdits?this.t('savingEdits'):this.t('ready');}
 viewState(){const selection=this.editor.getSelection();if(!selection)return;this.send('viewState',{schemaVersion:1,selectionStartLine:selection.selectionStartLineNumber,selectionStartColumn:selection.selectionStartColumn,selectionEndLine:selection.positionLineNumber,selectionEndColumn:selection.positionColumn,scrollTop:this.editor.getScrollTop(),scrollLeft:this.editor.getScrollLeft()});}
 failure(error){this.error.hidden=false;this.error.textContent=this.t('syncError');this.editor.updateOptions({readOnly:true});this.send('error',{code:3});}
 async receive(type,payload,requestIdentifier) {
  try {
   if(type==='document')this.document(payload.snapshot,payload.edits);
   if(type==='ack')this.sync.ack(payload);
   if(type==='viewFlags')this.buttons.get('pin').disabled=!payload.preview;
   if(type==='editAuthority'){this.authorized=payload.granted;this.sync.resume();this.editor.updateOptions({readOnly:this.readOnly||!this.authorized});}
   if(type==='flush'){const barrier=this.sync.flush(payload.suspend);if(payload.suspend&&!this.sync.composing)this.editor.updateOptions({readOnly:true});await barrier;this.editor.updateOptions({readOnly:this.readOnly||!this.authorized||this.sync.suspended});this.viewState();this.send('flushResult',{revision:String(this.sync.revision),sequence:String(this.sync.sequence)},requestIdentifier);}
   if(type==='resume'){this.sync.resume();this.editor.updateOptions({readOnly:this.readOnly||!this.authorized});}
   if(type==='focus')this.editor.focus();
   if(type==='command')this.command(payload.command);
   if(type==='reveal'){const position={lineNumber:Math.max(1,payload.lineNumber),column:Math.max(1,payload.utf16Column)};this.editor.setPosition(position);this.editor.revealPositionInCenter(position);}
   if(type==='restoreViewState'){this.editor.setSelection({selectionStartLineNumber:payload.selectionStartLine,selectionStartColumn:payload.selectionStartColumn,positionLineNumber:payload.selectionEndLine,positionColumn:payload.selectionEndColumn});this.editor.setScrollPosition({scrollTop:payload.scrollTop,scrollLeft:payload.scrollLeft});}
   if(type==='paste'&&!this.readOnly&&this.authorized)this.paste(payload.text);
   if(type==='copySelection'){const text=this.editor.getModel().getValueInRange(this.editor.getSelection());this.send('clipboard',{text});if(payload.cut&&!this.readOnly&&this.authorized&&!this.sync.suspended)this.editor.executeEdits('native-cut',[{range:this.editor.getSelection(),text:''}]);}
  } catch(error){if(type==='flush')this.send('flushResult',{error:3},requestIdentifier);this.failure(error);}
 }
 paste(text){if(this.sync.suspended||this.sync.error)return;if(typeof text!=='string'||text.length>10*1024*1024)return;this.rawPaste=text;try{this.editor.executeEdits('native-paste',[{range:this.editor.getSelection(),text,forceMoveMarkers:true}]);}finally{this.rawPaste=null;}}
 dispose(){this.subscriptions.forEach(s=>s.dispose());this.container.removeEventListener('compositionstart',this.onCompositionStart);this.container.removeEventListener('compositionend',this.onCompositionEnd);this.container.removeEventListener('keydown',this.key,true);this.container.removeEventListener('contextmenu',this.context);this.container.removeEventListener('paste',this.pasteHandler,true);this.editor.dispose();this.root.replaceChildren();}
}
