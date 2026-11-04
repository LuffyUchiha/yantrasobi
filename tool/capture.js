// Captures real screenshots of the web build in headless Chromium.
// Usage: node tool/capture.js <build/web dir> <out dir> <script.json>
// script.json: [{"action":"wait","ms":1000} | {"action":"tap","x":..,"y":..} |
//               {"action":"drag","from":[x,y],"to":[x,y],"ms":600,"hold":0} |
//               {"action":"shot","name":"library"} | {"action":"press","x":..,"y":..,"ms":..}]
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const [root, outDir, scriptPath] = process.argv.slice(2);
const steps = JSON.parse(fs.readFileSync(scriptPath, 'utf8'));
const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm',
  '.json': 'application/json', '.png': 'image/png', '.otf': 'font/otf', '.ttf': 'font/ttf', '.frag': 'application/octet-stream' };

const server = http.createServer((req, res) => {
  let p = decodeURIComponent(req.url.split('?')[0]);
  if (p.endsWith('/')) p += 'index.html';
  const f = path.join(root, p);
  fs.readFile(f, (err, data) => {
    if (err) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(f)] || 'application/octet-stream',
      'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp' });
    res.end(data);
  });
});

(async () => {
  await new Promise(r => server.listen(0, r));
  const port = server.address().port;
  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 412, height: 870 }, deviceScaleFactor: 1, hasTouch: false });
  const logs = [];
  page.on('console', m => logs.push(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', e => logs.push(`[pageerror] ${e.message}`));
  // CanvasKit normally comes from the gstatic CDN; serve the bundled copy instead.
  await page.route(/https:\/\/www\.gstatic\.com\/flutter-canvaskit\/[^/]+\/(.*)/, async (route) => {
    const rel = route.request().url().replace(/https:\/\/www\.gstatic\.com\/flutter-canvaskit\/[^/]+\//, '');
    const f = path.join(root, 'canvaskit', rel);
    if (!fs.existsSync(f)) return route.abort();
    await route.fulfill({ body: fs.readFileSync(f), contentType: types[path.extname(f)] || 'application/octet-stream' });
  });
  await page.goto(`http://127.0.0.1:${port}/`);
  fs.mkdirSync(outDir, { recursive: true });
  for (const s of steps) {
    if (s.action === 'wait') await page.waitForTimeout(s.ms);
    else if (s.action === 'tap') { await page.mouse.click(s.x, s.y); }
    else if (s.action === 'press') { await page.mouse.move(s.x, s.y); await page.mouse.down(); await page.waitForTimeout(s.ms); await page.mouse.up(); }
    else if (s.action === 'down') { await page.mouse.move(s.x, s.y); await page.mouse.down(); }
    else if (s.action === 'move') { await page.mouse.move(s.x, s.y, { steps: s.steps || 10 }); }
    else if (s.action === 'up') { await page.mouse.up(); }
    else if (s.action === 'wheel') { await page.mouse.move(s.x || 200, s.y || 500); await page.mouse.wheel(0, s.dy); }
    else if (s.action === 'drag') {
      await page.mouse.move(s.from[0], s.from[1]); await page.mouse.down();
      await page.mouse.move(s.to[0], s.to[1], { steps: 20 });
      if (s.hold) await page.waitForTimeout(s.hold);
      await page.mouse.up();
    }
    else if (s.action === 'shot') await page.screenshot({ path: path.join(outDir, `${s.name}.png`) });
  }
  fs.writeFileSync(path.join(outDir, 'console.log'), logs.join('\n'));
  await browser.close();
  server.close();
})().catch(e => { console.error(e); process.exit(1); });
