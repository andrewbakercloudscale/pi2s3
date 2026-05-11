const { test, expect } = require('@playwright/test');

const QA_URL = 'https://wp-qa.andrewbaker.ninja';

test('QA WordPress — tunnel reachable (nginx-health)', async ({ page }) => {
    const response = await page.goto(`${QA_URL}/nginx-health`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    expect(response.status()).toBe(200);
});

test('QA WordPress — REST API responds', async ({ page }) => {
    const response = await page.goto(`${QA_URL}/wp-json/wp/v2/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    expect(response.status()).toBe(200);
    const body = await page.locator('body').textContent();
    expect(body).toContain('namespace');
});

test('QA WordPress — screenshot', async ({ page }) => {
    const path = require('path');
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto(`${QA_URL}/wp-json/wp/v2/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.screenshot({
        path: path.resolve(__dirname, '../test-results/qa-site.png'),
        fullPage: false,
    });
    const body = await page.locator('body').textContent();
    expect(body).toContain('namespace');
});
