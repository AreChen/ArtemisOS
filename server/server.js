// Local test server only. Production hosting should use HTTPS and the same
// static manifests/ and objects/ layout behind the organization's web server.
const http = require('http');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, 'repository');
const port = Number(process.env.ARTEMIS_UPDATE_TEST_PORT || '18765');
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid test port');
http.createServer((request, response) => {
  const pathname = new URL(request.url, 'http://127.0.0.1').pathname;
  if (request.method === 'GET' && pathname === '/health') {
    response.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' })
      .end(JSON.stringify({ product: 'ArtemisOS-local-update-server', schema: 1 }));
    return;
  }
  if (!['GET', 'HEAD'].includes(request.method) ||
      !/^\/(?:manifests\/\d+\.\d+\.\d+\.(?:json|sig)|objects\/[0-9a-f]{64})$/.test(pathname)) {
    response.writeHead(404).end();
    return;
  }
  const filename = path.join(root, pathname.slice(1));
  fs.stat(filename, (error, info) => {
    if (error || !info.isFile()) { response.writeHead(404).end(); return; }
    response.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': info.size,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff'
    });
    if (request.method === 'HEAD') response.end();
    else fs.createReadStream(filename).on('error', () => response.destroy()).pipe(response);
  });
}).listen(port, '127.0.0.1', () => console.log('ArtemisOS test update server listening on 127.0.0.1:' + port));
