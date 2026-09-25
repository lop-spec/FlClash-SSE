// Hosted job logs need a signed-in viewer, so failed tests are also published
// as annotations, which the public check-run API exposes.
const fs = require('node:fs');

const events = fs.existsSync(process.argv[2])
  ? fs.readFileSync(process.argv[2], 'utf8').split('\n').flatMap((line) => {
    try { return [JSON.parse(line)]; } catch { return []; }
  })
  : [];
const tests = new Map();
const errors = new Map();
const prints = new Map();
for (const event of events) {
  if (event.type === 'testStart') tests.set(event.test.id, event.test);
  if (event.type === 'print') prints.set(event.testID, `${prints.get(event.testID) || ''}${event.message}\n`);
  if (event.type === 'error') {
    const trace = String(event.stackTrace || '').split('\n').slice(0, 8).join('\n');
    errors.set(event.testID, `${errors.get(event.testID) || ''}${event.error}\n${trace}\n`);
  }
}
const escape = (text) => text.replace(/%/g, '%25').replace(/\r/g, '').replace(/\n/g, '%0A');
let published = 0;
for (const [id, error] of errors) {
  const test = tests.get(id) || {};
  const title = String(test.name || 'flutter test').replace(/[,:]/g, ' ').slice(0, 200);
  const output = (prints.get(id) || '').slice(-4000);
  console.log(`::error title=${escape(title)}::${escape(`${output}${error}`.slice(-8000))}`);
  if (++published === 10) break;
}
if (published === 0) console.log('::error title=flutter test::failed without a JSON error event; see the job log');
