import {execFileSync, spawnSync} from 'node:child_process';
import {realpathSync} from 'node:fs';

export function stageOutput(repository, filename) {
  const result = spawnSync('git', ['rev-parse', '--show-toplevel'], {
    cwd: repository, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (result.status !== 0 || realpathSync(result.stdout.trim()) !== realpathSync(repository)) return false;
  execFileSync('git', ['add', filename], {cwd: repository});
  return true;
}
