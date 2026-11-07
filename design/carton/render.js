const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  for (const name of process.argv.slice(2)) {
    const svg = fs.readFileSync(`${name}.svg`, 'utf8');
    await page.setContent(`<html><body style="margin:0;background:#000">${svg}</body></html>`);
    await page.screenshot({ path: `${name}.png`, clip: { x: 0, y: 0, width: 1024, height: 1024 } });
  }
  await browser.close();
})();
