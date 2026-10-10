// Renders each flow frame at 2x and the full board, using the Playwright copy shared with the slop scanner.
// PAGE picks the mockup (default index.html, iteration 1); OUT is relative to the project root.
// e.g. PAGE=iteration-2.html OUT=docs/flow/iteration-2 node tools/render.mjs [filter]
import {createRequire} from 'node:module';
import {homedir} from 'node:os';
import {mkdirSync} from 'node:fs';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {dirname, resolve} from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const {chromium} = createRequire(pathToFileURL(resolve(homedir(), '.cache/distro-deck') + '/'))('playwright');
const out = resolve(here, '../..', process.env.OUT || 'docs/flow/iteration-1');
mkdirSync(out, {recursive: true});
const url = pathToFileURL(resolve(here, '..', process.env.PAGE || 'index.html')).href;
const only = process.argv[2];

const browser = await chromium.launch();
const open = async (scale) => {
  const page = await browser.newPage({viewport: {width: 2900, height: 2300}, deviceScaleFactor: scale});
  page.on('pageerror', e => { console.error('page error:', e.message); process.exitCode = 1; });
  await page.goto(url);
  await page.waitForFunction(() => window.__ready === true);
  return page;
};

const frames = await open(2);
await frames.evaluate(() => document.body.classList.add('export'));
const ids = await frames.$$eval('.screen', els => els.map(e => e.dataset.id));
for (const id of ids.filter(i => !only || i.includes(only))) {
  await frames.locator(`.screen[data-id="${id}"]`).screenshot({path: `${out}/${id}.png`});
}
if (!only) {
  const board = await open(1.4);
  await board.locator('#board').screenshot({path: `${out}/flow.png`});
}
await browser.close();
console.log(`rendered ${only ? 'matching' : ids.length} frames${only ? '' : ' + flow.png'} to ${out}`);
