const { test, expect } = require('@playwright/test');
const path = require('path');

const LIVE_URL = 'https://pi2s3.com';

const pages = ['', 'setup.html', 'recovery.html', 'reference.html'];

for (const page of pages) {
  const url = page ? `${LIVE_URL}/${page}` : LIVE_URL;
  const label = page || 'index.html';

  test(`[${label}] favicon link points to favicon.jpeg`, async ({ page: pw }) => {
    await pw.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });

    const href = await pw.locator('link[rel="icon"]').getAttribute('href');
    expect(href).toBe('favicon.jpeg');

    const type = await pw.locator('link[rel="icon"]').getAttribute('type');
    expect(type).toBe('image/jpeg');
  });

  test(`[${label}] favicon.jpeg loads (HTTP 200)`, async ({ page: pw }) => {
    const response = await pw.goto(`${LIVE_URL}/favicon.jpeg`, { waitUntil: 'load', timeout: 30000 });
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('image/jpeg');
  });
}

test('live index — favicon screenshot', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto(LIVE_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.screenshot({
    path: path.resolve(__dirname, '../test-results/live-favicon-check.png'),
    fullPage: false,
  });
});
