const { test, expect } = require('@playwright/test');
const path = require('path');

const LOCAL_FILE = `file://${path.resolve(__dirname, '../index.html')}`;
const LIVE_URL = 'https://pi2s3.com';

for (const [label, url] of [['local', LOCAL_FILE], ['live', LIVE_URL]]) {
  test(`[${label}] hero cards — screenshot mobile`, async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 }); // iPhone 14
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    // Scroll to cards
    await page.evaluate(() => {
      const el = document.querySelector('[data-testid="feature-cards"]') ||
        Array.from(document.querySelectorAll('div')).find(d =>
          d.innerText && d.innerText.includes('NEW IN V1.7'));
      if (el) el.scrollIntoView();
    });
    await page.waitForTimeout(500);

    await page.screenshot({
      path: path.resolve(__dirname, `../test-results/hero-cards-${label}.png`),
      fullPage: false,
    });
  });

  test(`[${label}] hero cards — computed styles`, async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    const styles = await page.evaluate(() => {
      // Find all 4 feature cards by scanning for the "New in v1.7" container
      const allDivs = Array.from(document.querySelectorAll('div'));
      const cards = allDivs.filter(d => {
        const bg = window.getComputedStyle(d).backgroundColor;
        return bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent' &&
          d.children.length > 0 && d.offsetWidth > 200 && d.offsetWidth < 500;
      }).slice(0, 8);

      return cards.map(card => ({
        text: card.innerText.substring(0, 60).replace(/\n/g, ' '),
        backgroundColor: window.getComputedStyle(card).backgroundColor,
        borderColor: window.getComputedStyle(card).borderColor,
        borderWidth: window.getComputedStyle(card).borderWidth,
      }));
    });

    console.log(`\n[${label}] Computed card styles:\n`, JSON.stringify(styles, null, 2));

    // At least one card should have a non-transparent background
    expect(styles.length).toBeGreaterThan(0);
  });

  test(`[${label}] hero cards — HTML source check`, async ({ page }) => {
    await page.goto(url, { waitUntil: 'domcontentloaded' });

    const html = await page.content();

    // Check for new card styles (amber card should have fbbf24)
    const hasAmber = html.includes('fbbf24');
    const hasTeal = html.includes('5eead4') || html.includes('94,234,212');
    const hasGlow = html.includes('box-shadow');
    const hasNewBadge = html.includes('New in v1.7');

    console.log(`\n[${label}] HTML checks:`, { hasAmber, hasTeal, hasGlow, hasNewBadge });

    expect(hasAmber, 'amber color (fbbf24) should be in HTML').toBe(true);
    expect(hasTeal, 'teal color should be in HTML').toBe(true);
    expect(hasNewBadge, '"New in v1.7" label should be present').toBe(true);
  });
}
