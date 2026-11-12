import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
execFileSync('python3',[fileURLToPath(new URL('../copy_file_workspace_ui.py',import.meta.url)),'--verify'],{stdio:'inherit'});
