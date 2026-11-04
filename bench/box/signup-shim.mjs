// Bench-only proxy for POST /metadata (Caddy sends only that route here; see bench/README.md "Sign-up").
// Twenty v2.55 lets a new email join an existing workspace only through its public invite link, which the
// /welcome page never sends. This adds the workspace's invite hash to signUpInWorkspace calls that carry
// no invitation, so any new address can sign up from the normal page. Everything else passes unchanged.
import http from 'node:http';

const LISTEN_PORT = Number(process.env.SHIM_PORT ?? 3090);
const INVITE_HASH = process.env.BENCH_INVITE_HASH;
const MAX_JSON_BYTES = 2 * 1024 * 1024;
const UPSTREAM_HEADER = 'x-bench-upstream';

if (!INVITE_HASH) {
  console.error('BENCH_INVITE_HASH is not set');
  process.exit(1);
}

const addInviteHash = (operation) => {
  if (typeof operation?.query !== 'string' || !operation.query.includes('signUpInWorkspace')) {
    return false;
  }
  const variables = operation.variables ?? {};
  if (variables.workspaceInviteHash || variables.workspacePersonalInviteToken) {
    return false;
  }
  operation.variables = { ...variables, workspaceInviteHash: INVITE_HASH };
  return true;
};

const rewriteBody = (body) => {
  try {
    const parsed = JSON.parse(body.toString('utf8'));
    const operations = Array.isArray(parsed) ? parsed : [parsed];
    const changed = operations.map(addInviteHash).some(Boolean);
    return changed ? Buffer.from(JSON.stringify(parsed)) : body;
  } catch {
    return body;
  }
};

const forward = (req, res, upstream, body) => {
  const [host, port] = upstream.split(':');
  const headers = { ...req.headers };
  delete headers[UPSTREAM_HEADER];
  if (body) {
    headers['content-length'] = String(body.length);
    delete headers['transfer-encoding'];
  }
  const proxied = http.request({ host, port: Number(port), method: req.method, path: req.url, headers }, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode ?? 502, upstreamRes.rawHeaders);
    upstreamRes.pipe(res);
  });
  proxied.on('error', () => {
    if (!res.headersSent) res.writeHead(502);
    res.end();
  });
  if (body) proxied.end(body);
  else req.pipe(proxied);
};

http
  .createServer((req, res) => {
    const upstream = req.headers[UPSTREAM_HEADER];
    if (typeof upstream !== 'string' || !/^127\.0\.0\.1:\d+$/.test(upstream)) {
      res.writeHead(400).end();
      return;
    }
    const isJson = (req.headers['content-type'] ?? '').includes('application/json');
    const length = Number(req.headers['content-length'] ?? 0);
    if (!isJson || length > MAX_JSON_BYTES) {
      forward(req, res, upstream);
      return;
    }
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      chunks.push(chunk);
    });
    req.on('end', () => {
      const body = Buffer.concat(chunks, size);
      forward(req, res, upstream, size <= MAX_JSON_BYTES ? rewriteBody(body) : body);
    });
  })
  .listen(LISTEN_PORT, '127.0.0.1');
