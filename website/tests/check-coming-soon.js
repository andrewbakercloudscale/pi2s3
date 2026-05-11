const { chromium } = require('playwright');
const path = require('path');

(async () => {
  const browser = await chromium.launch({ args: ['--disable-cache'] });
  const page = await browser.newPage();
  await page.setViewportSize({ width: 1280, height: 1200 });
  await page.goto('https://pi2s3.com', { waitUntil: 'networkidle' });

  const html = await page.content();
  console.log('Coming Soon count:', (html.match(/Coming Soon/g) || []).length);
  console.log('Has pairing section:', html.includes('hot standby'));

  // Screenshot pairing section
  const section = await page.$('#pairing');
  if (section) {
    await section.screenshot({ path: path.resolve(__dirname, '../test-results/pairing-live.png') });
    console.log('Screenshotted #pairing section');
  }

  await browser.close();
})();
