const { chromium } = require('playwright');
const path = require('path');

const pages = [
  { name: 'index',     url: 'https://pi2s3.com/',             expect: ['The AMI for your', 'How it works'] },
  { name: 'setup',     url: 'https://pi2s3.com/setup.html',   expect: ['Install pi2s3 in minutes', 'Prerequisites'] },
  { name: 'recovery',  url: 'https://pi2s3.com/recovery.html',expect: ['Restore, clone', 'Restore to a new Pi'] },
  { name: 'reference', url: 'https://pi2s3.com/reference.html',expect: ['Configuration, monitoring', 'Troubleshooting'] },
];

(async () => {
  const browser = await chromium.launch({ args: ['--disable-cache'] });
  let allOk = true;

  for (const p of pages) {
    const page = await browser.newPage();
    await page.setViewportSize({ width: 1280, height: 900 });
    const res = await page.goto(p.url, { waitUntil: 'domcontentloaded' });

    const status = res.status();
    const text = await page.evaluate(() => document.body.textContent);
    const missing = p.expect.filter(s => !text.includes(s));

    await page.screenshot({ path: path.resolve(__dirname, `../test-results/live-${p.name}.png`) });

    if (status !== 200 || missing.length) {
      console.log(`FAIL [${p.name}] HTTP ${status} missing: ${missing.join(', ')}`);
      allOk = false;
    } else {
      console.log(`OK   [${p.name}] HTTP ${status}`);
    }
    await page.close();
  }

  await browser.close();
  process.exit(allOk ? 0 : 1);
})();
