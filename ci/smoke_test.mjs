// Browsertest van de web-build: opent de app als iPhone (WebKit) en als
// desktop-Chrome, uploadt een foto, laat schilderen en exporteert een SVG.
// Gebruik: node ci/smoke_test.mjs <url> <uitvoermap>
import { chromium, webkit, devices } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';

const [url, outDir] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const photo = path.resolve('ci/test_photo.jpg');
const report = [];
let failed = false;

async function swipe(page, x, y1, y2) {
  await page.evaluate(async ([x, y1, y2]) => {
    const target = document.querySelector('flutter-view') || document.body;
    const fire = (type, y) => target.dispatchEvent(new PointerEvent(type, {
      pointerId: 7, pointerType: 'touch', isPrimary: true, bubbles: true,
      cancelable: true, composed: true, clientX: x, clientY: y,
      buttons: type === 'pointerup' ? 0 : 1, pressure: type === 'pointerup' ? 0 : 0.5,
    }));
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    fire('pointerdown', y1);
    const steps = 14;
    for (let i = 1; i <= steps; i++) { await sleep(16); fire('pointermove', y1 + (y2 - y1) * i / steps); }
    await sleep(16);
    fire('pointerup', y2);
  }, [x, y1, y2]);
}

async function run(name, browserType, contextOpts) {
  const browser = await browserType.launch();
  const context = await browser.newContext({ ...contextOpts, acceptDownloads: true });
  const page = await context.newPage();
  const logs = [];
  page.on('console', (m) => logs.push(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', (e) => logs.push(`[pageerror] ${e.message}`));
  const shot = (s) => page.screenshot({ path: path.join(outDir, `${name}-${s}.png`) });
  const vp = page.viewportSize();
  const result = { name, ok: false, notes: [] };
  try {
    await page.goto(url, { waitUntil: 'load' });
    // wait until Flutter has rendered its view
    await page.waitForSelector('flutter-view, flt-glass-pane', { timeout: 60000 });
    await page.waitForTimeout(4000);
    await shot('1-start');

    // tap the empty state in the centre of the canvas area
    const isNarrow = vp.width < 900;
    const canvasH = isNarrow ? (vp.height - 56) * 0.45 : vp.height - 56;
    const canvasW = isNarrow ? vp.width : vp.width - 340;
    const [chooser] = await Promise.all([
      page.waitForEvent('filechooser', { timeout: 15000 }),
      page.mouse.click(canvasW / 2, 56 + canvasH / 2),
    ]);
    await chooser.setFiles(photo);
    result.notes.push('foto gekozen');

    await page.waitForTimeout(3000);
    await shot('2-bezig');
    await page.waitForTimeout(9000);
    await shot('3-halverwege');
    await page.waitForTimeout(12000);
    await shot('4-klaar');

    if (isNarrow) {
      // touch swipe up over the settings panel (real touch pointer events)
      await swipe(page, vp.width / 2, vp.height - 60, vp.height - 360);
      await page.waitForTimeout(1200);
      await shot('5-geveegd');
      await swipe(page, vp.width / 2, 140, 40);
      await page.waitForTimeout(600);
    }

    // SVG export: first icon in the app bar (right side: [svg][png][8px])
    const [download] = await Promise.all([
      page.waitForEvent('download', { timeout: 60000 }),
      page.mouse.click(vp.width - 8 - 24 - 48, 28),
    ]);
    const svgPath = path.join(outDir, `${name}-export.svg`);
    await download.saveAs(svgPath);
    const size = fs.statSync(svgPath).size;
    const head = fs.readFileSync(svgPath, 'utf8').slice(0, 200);
    result.notes.push(`svg ${download.suggestedFilename()} ${(size / 1e6).toFixed(1)} MB`);
    if (!head.includes('<svg')) throw new Error('download is geen svg');
    // keep repo small: only keep the first 300 KB of the svg as a sample
    if (size > 300000) fs.truncateSync(svgPath, 300000);
    result.ok = true;
  } catch (e) {
    result.notes.push(`FOUT: ${e.message}`);
    await shot('fout').catch(() => {});
    failed = true;
  }
  fs.writeFileSync(path.join(outDir, `${name}-console.txt`), logs.join('\n'));
  const errs = logs.filter((l) => /error|exception/i.test(l));
  if (errs.length) result.notes.push(`console-fouten: ${errs.slice(0, 5).join(' | ')}`);
  report.push(result);
  await browser.close();
}

await run('iphone', webkit, devices['iPhone 13']);
await run('desktop', chromium, { viewport: { width: 1280, height: 800 } });

const text = report
  .map((r) => `${r.ok ? 'OK ' : 'FOUT'} ${r.name}: ${r.notes.join('; ')}`)
  .join('\n');
fs.writeFileSync(path.join(outDir, 'rapport.txt'), text + '\n');
console.log(text);
console.log(`::${failed ? 'error' : 'notice'} title=Browsertest::${text.replace(/\n/g, '%0A')}`);
process.exit(failed ? 1 : 0);
