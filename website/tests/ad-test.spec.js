const { test, expect } = require('@playwright/test');

const SITES = [
  'https://pi2s3.com',
  'https://cloudtorepo.com',
];

for (const url of SITES) {
  test(`${url} — ad container hidden when no ad served`, async ({ page }) => {
    await page.goto(url, { waitUntil: 'networkidle' });

    // Wait for AdSense script to run
    await page.waitForTimeout(3000);

    const adTop = page.locator('#ad-top');

    // Container should either not exist or be hidden
    const isVisible = await adTop.isVisible();
    expect(isVisible, `#ad-top should be hidden (no approved ad yet)`).toBe(false);
  });

  test(`${url} — no blank gap below nav`, async ({ page }) => {
    await page.goto(url, { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);

    const adTop = page.locator('#ad-top');
    const box = await adTop.boundingBox();

    // If element is display:none, boundingBox returns null — that's correct
    // If it's visible, its height should be > 50 (real ad) or 0
    if (box) {
      expect(box.height, `#ad-top should not be a blank gap`).toBeGreaterThan(50);
    }
  });
}
