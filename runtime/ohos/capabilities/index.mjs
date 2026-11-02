import { STATUS_CODES } from 'node:http';
import { readPublicationCapabilities } from '../publication/capabilities.mjs';

export const name = 'dsh-go-ohos-runtime-capabilities';
const publicationSymbol = Symbol.for('dsh.go.ohos.publication');
const simulationSymbol = Symbol.for('dsh.go.ohos.sim');

export function apply(ctx) {
  if (process.platform !== 'openharmony' && globalThis[simulationSymbol] !== true) return;
  ctx.inject(['webServer'], webCtx => {
    webCtx.effect(() => webCtx.webServer.register({
      kind: 'exact',
      path: '/dsh-go/v1/runtime-capabilities',
      handler(req, res) {
        // Use the existing connection's Host/Origin/authentication decision,
        // including its not-ready state. A read-only route gets no exemption.
        const connection = webCtx.get('connection');
        const rejection = connection === undefined ? 503 : connection.requestRejection(req);
        const status = rejection ?? (req.method === 'GET' ? 200 : 405);
        const headers = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff',
          'content-type': status === 200 ? 'application/json; charset=utf-8' : 'text/plain; charset=utf-8' };
        if (status === 405) headers.allow = 'GET';
        if (status !== 200) {
          res.writeHead(status, headers);
          res.end(req.method === 'HEAD' ? undefined : `${STATUS_CODES[status]}\n`);
          return;
        }
        // Read on every request. No discovery, syscall trial, or persistence is
        // performed here. O6 fields outside this implemented slice stay absent.
        const service = globalThis[publicationSymbol];
        const body = { v: 1, platform: process.platform, arch: process.arch,
          nodeVersion: process.versions.node, simulated: globalThis[simulationSymbol] === true,
          ...(service?.protocolVersion === 1 ? { bootId: service.ownerId } : {}),
          ...readPublicationCapabilities() };
        res.writeHead(200, headers);
        res.end(JSON.stringify(body));
      },
    }), 'ohos runtime capabilities');
  });
}
