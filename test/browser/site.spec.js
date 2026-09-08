const { test, expect } = require('@playwright/test');

test('theme, keyboard disclosure, copy and mobile navigation work together', async ({ page, context }) => {
  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce' });
  await page.goto('/');
  const root = page.locator('html');
  await expect(root).toHaveAttribute('data-theme', 'dark');
  const summary = page.locator('.boundary-test summary');
  await summary.focus();
  await page.keyboard.press('Enter');
  await expect(page.locator('.boundary-test')).toHaveAttribute('open', '');
  await expect(page.getByText('assert_equal 0, calculator.discount(10)')).toBeVisible();
  await page.getByRole('button', { name: 'Dark theme. Switch to light mode' }).click();
  await page.reload();
  await expect(root).toHaveAttribute('data-theme', 'light');
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.locator('.copy').first().click();
  await expect(page.locator('.copy').first()).toHaveText('Copied ✓');
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe('gem install mutineer');
  await page.setViewportSize({ width: 390, height: 844 });
  for (const path of ['/', '/agentic-coding.html', '/json-schema.html', '/sample-report.html']) {
    await page.goto(path);
    await expect(root).toHaveAttribute('data-theme', 'light');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    for (const label of ['Install', 'Agent & CI', 'JSON schema', 'Sample report', 'GitHub ↗']) {
      await expect(page.getByRole('navigation', { name: 'Primary', exact: true }).getByRole('link', { name: label, exact: true })).toBeVisible();
    }
  }
  await page.getByRole('navigation', { name: 'Primary', exact: true }).getByRole('link', { name: 'JSON schema', exact: true }).click();
  await expect(page).toHaveURL(/json-schema.html$/);
  await expect(page.getByRole('region', { name: 'Summary fields', exact: true })).toBeVisible();
});

test('content and disclosure remain usable without JavaScript', async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false });
  try {
    const page = await context.newPage();
    await page.goto('http://127.0.0.1:8766/');
    await expect(page.getByRole('heading', { level: 1 })).toHaveText('Make yourtests prove it.');
    await page.locator('.boundary-test summary').click();
    await expect(page.locator('.boundary-test')).toHaveAttribute('open', '');
    await expect(page.locator('#theme')).toBeHidden();
    await expect(page.locator('.copy').first()).toBeHidden();
  } finally {
    await context.close();
  }
});
