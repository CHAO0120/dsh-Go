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
  // The cause is usually earlier than the last lines, and a step shows ten errors at most.
  const lines = report.nativeHost ?? [];
  const telling = lines.filter((line) => /error|Error|ERR_|cannot|Cannot|failed|fatal|throw|at .*:d+/.test(line));
  for (const line of [...telling.slice(0, 5), ...lines.slice(-3)]) console.log('::error title=engine log::' + clean(line));
}
