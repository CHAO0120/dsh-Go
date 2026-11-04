// Puts the round's result where it can be read without signing in to GitHub.
import { readFileSync } from 'node:fs';

const report = JSON.parse(readFileSync(process.argv[2] + '/report.json', 'utf8'));
const clean = (text) => String(text).replace(/%/g, '%25').replace(/\s+/g, ' ').slice(0, 500);
console.log('::notice title=engine round::' + clean(JSON.stringify({
  status: report.status, stage: report.stage, readyMs: report.readyMs,
  restart: report.restart, restartReadyMs: report.restartReadyMs, approvals: report.approvals,
})));
if (report.status !== 'PASS') {
  console.log('::error title=engine round::' + clean(report.error));
  for (const line of (report.nativeHost ?? []).slice(-8)) console.log('::error title=engine log::' + clean(line));
}
