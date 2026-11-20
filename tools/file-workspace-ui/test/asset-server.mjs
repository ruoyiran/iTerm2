import http from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';

export async function assetServer(directory) {
  const manifest = JSON.parse(await readFile(path.join(directory, 'manifest.json'), 'utf8'));
  const records = new Map(manifest.files.map(record => [record.path, record]));
  return http.createServer(async (request, response) => {
    try {
      const logical = decodeURIComponent(request.url.split('?')[0]).replace(/^\//, '');
      const record = records.get(logical);
      if (!record) throw new Error('Unknown asset');
      const data = await readFile(path.join(directory, record.storagePath ?? record.path));
      response.setHeader('Content-Type', record.mime);
      response.setHeader('Content-Length', data.length);
      if (record.encoding) response.setHeader('Content-Encoding', record.encoding);
      response.end(request.method === 'HEAD' ? undefined : data);
    } catch {
      response.statusCode = 404;
      response.end();
    }
  });
}
