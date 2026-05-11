const { chromium } = require('playwright');
const path = require('path');

const pages = [
  { name: 'index',     file: 'index.html',     expect: ['The AMI for your', 'How it works', 'partclone'] },
  { name: 'setup',     file: 'setup.html',     expect: ['Install pi2s3 in minutes', 'Prerequisites', 'Quick start'] },
  { name: 'recovery',  file: 'recovery.html',  expect: ['Restore, clone', 'Restore to a new Pi', 'hot standby'] },
  { name: 'reference', file: 'reference.html', expect: ['Configuration, monitoring', 'Troubleshooting', 'PHP-FPM'] },
];

(async () => {
  const browser = await chromium.launch();
  let allOk = true;

  for (const p of pages) {
    const page = await browser.newPage();
    await page.setViewportSize({ width: 1280, height: 900 });
    const url = `file://${path.resolve(__dirname, '..', p.file)}`;
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    const text = await page.evaluate(() => document.body.textContent);
    const missing = p.expect.filter(s => !text.includes(s));

    await page.screenshot({ path: path.resolve(__dirname, `../test-results/page-${p.name}.png`) });

    if (missing.length) {
      console.log(`FAIL [${p.name}] missing: ${missing.join(', ')}`);
      allOk = false;
    } else {
      console.log(`OK   [${p.name}]`);
    }
    await page.close();
  }

  await browser.close();
  process.exit(allOk ? 0 : 1);
})();
