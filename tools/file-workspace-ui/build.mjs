import './patch-monaco.mjs';
import {build} from 'esbuild';
import {readFile,writeFile,readdir,mkdir,cp,rm,rename} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const tooling=path.dirname(fileURLToPath(import.meta.url)),repo=path.resolve(tooling,'../..');
const source=path.join(repo,'sources/FileWorkspace/Resources'),target=path.join(source,'FileWorkspaceUI'),staging=target+'.staging';
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
async function files(dir){const result=[];for(const entry of (await readdir(dir,{withFileTypes:true})).sort((a,b)=>a.name.localeCompare(b.name,'en'))){const p=path.join(dir,entry.name);if(entry.isSymbolicLink())throw new Error('Symlink in build inputs');if(entry.isDirectory())result.push(...await files(p));else result.push(p);}return result;}
await rm(staging,{recursive:true,force:true});await mkdir(staging,{recursive:true});
const monaco=path.join(tooling,'node_modules/monaco-editor/esm/vs');
await build({absWorkingDir:tooling,entryPoints:{app:path.join(source,'src/bootstrap.mjs'),'workers/editor.worker':monaco+'/editor/editor.worker.js','workers/json.worker':monaco+'/language/json/json.worker.js','workers/css.worker':monaco+'/language/css/css.worker.js','workers/html.worker':monaco+'/language/html/html.worker.js','workers/ts.worker':monaco+'/language/typescript/ts.worker.js'},outdir:staging,entryNames:'[dir]/[name]',chunkNames:'chunks/[name]-[hash]',assetNames:'assets/[name]-[hash]',bundle:true,splitting:true,format:'esm',target:'safari16.4',minify:true,sourcemap:false,legalComments:'linked',loader:{'.ttf':'file','.woff2':'file'},nodePaths:[path.join(tooling,'node_modules')],logLevel:'warning'});
for(const name of ['index.html','icons','fonts','licenses'])await cp(path.join(source,name),path.join(staging,name),{recursive:true});
const mime={'.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.html':'text/html; charset=utf-8','.svg':'image/svg+xml','.ttf':'font/ttf','.woff2':'font/woff2','.txt':'text/plain; charset=utf-8'};
const manifest={version:1,files:[],inputs:[]};
for(const filename of await files(staging)){const bytes=await readFile(filename);manifest.files.push({path:path.relative(staging,filename),bytes:bytes.length,sha256:hash(bytes),mime:mime[path.extname(filename)]??'application/octet-stream'});}
const inputs=[path.join(source,'index.html'),...await files(path.join(source,'src')),...await files(path.join(source,'css')),...await files(path.join(source,'icons')),...await files(path.join(source,'fonts')),...await files(path.join(source,'licenses')), ...['package.json','package-lock.json','build.mjs','patch-monaco.mjs','verify-resources.mjs','patches/monaco-editor@0.55.1.patch'].map(x=>path.join(tooling,x))];
for(const filename of inputs.sort()){manifest.inputs.push({path:path.relative(repo,filename),sha256:hash(await readFile(filename))});}
await writeFile(path.join(staging,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
await rm(target,{recursive:true,force:true});await rename(staging,target);
const inputLines=['$(SRCROOT)/tools/copy_file_workspace_ui.py','$(SRCROOT)/sources/FileWorkspace/Resources/FileWorkspaceUI/manifest.json',...manifest.inputs.map(x=>'$(SRCROOT)/'+x.path),...manifest.files.map(x=>'$(SRCROOT)/sources/FileWorkspace/Resources/FileWorkspaceUI/'+x.path)];
const outputLines=['manifest.json',...manifest.files.map(x=>x.path)].map(x=>'$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/FileWorkspaceUI/'+x);
await writeFile(path.join(tooling,'inputs.xcfilelist'),inputLines.join('\n')+'\n');
await writeFile(path.join(tooling,'outputs.xcfilelist'),outputLines.join('\n')+'\n');
console.log(`Packaged ${manifest.files.length} offline file UI assets.`);
