const { test, expect } = require('@playwright/test');

test('theme, keyboard disclosure, copy and mobile navigation work together', async ({ page, context }) => {
  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce' });
  await page.goto('/');
  const root = page.locator('html');
  // Reduced motion: no motion layer, and every number is final at once.
  await expect(root).not.toHaveClass(/\bmotion\b/);
  await expect(page.locator('.scroll-progress, .visually-hidden, .reveal')).toHaveCount(0);
  expect(await page.locator('.odo').allTextContents()).toEqual(['20', '01', '8,170', '24']);
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
  await expect(page.getByRole('heading', { name: 'Exit codes', exact: true })).toBeVisible();
  await expect(page.getByRole('region', { name: 'Exit codes', exact: true })).toBeVisible();
});

test('markdown twins and agent entrypoints are served', async ({ request }) => {
  for (const path of ['/index.md', '/agentic-coding.md', '/json-schema.md', '/llms.txt', '/llms-full.txt', '/skill.md', '/agents.txt', '/sitemap.xml', '/api/']) {
    const res = await request.get(path);
    expect(res.ok(), `${path} should be 200`).toBeTruthy();
  }
  const html = await request.get('/');
  expect(await html.text()).toContain('rel="alternate" type="text/markdown"');
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

test('printing before scrolling shows the real numbers', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  await page.goto('/');
  expect(await page.locator('.evidence-strip .odo').textContent()).toBe('\u20070');
  await page.evaluate(() => dispatchEvent(new Event('beforeprint')));
  expect(await page.locator('.odo').allTextContents()).toEqual(['20', '01', '8,170', '24']);
  await expect(page.locator('.visually-hidden')).toHaveCount(0);
});

test('turning on reduced motion mid-visit finishes the counts', async ({ page }) => {
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  await page.setViewportSize({ width: 1280, height: 1100 });
  await page.goto('/', { waitUntil: 'domcontentloaded' });
  const hero = page.locator('.hero-proof .odo');
  // The 1.8 s count must still be running, or this test proves nothing.
  expect(await hero.textContent()).not.toBe('8,170');
  await page.emulateMedia({ reducedMotion: 'reduce' });
  // The change arrives asynchronously; a short window is enough only if it finishes the count.
  await expect.poll(() => hero.textContent(), { timeout: 300 }).toBe('8,170');
  await expect(page.locator('.hero-proof .visually-hidden')).toHaveCount(0);
});

test('motion keeps step labels, true numbers and every section visible', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'light', reducedMotion: 'no-preference' });
  await page.setViewportSize({ width: 390, height: 844 });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('/');
  await expect(page.locator('html')).toHaveClass(/\bmotion\b/);
  // Screen readers, find-in-page and copy get the real figure at once.
  await expect(page.locator('.hero-proof .visually-hidden').first()).toHaveText('8,170');
  const labels = await page.locator('.step').evaluateAll(steps => steps.map(s => getComputedStyle(s, '::before').content));
  expect(labels).toEqual(Array(3).fill(expect.stringMatching(/counter\(step\)/)));
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  for (let y = 0; y < height; y += 300) {
    await page.evaluate(top => scrollTo(0, top), y);
    await page.waitForTimeout(40);
  }
  await page.waitForTimeout(2000);
  const state = await page.evaluate(() => ({
    hidden: [...document.querySelectorAll('.reveal, .typed')].filter(e => getComputedStyle(e).opacity === '0' || getComputedStyle(e).clipPath.includes('100%')).length,
    numbers: [...document.querySelectorAll('.odo')].map(e => e.textContent),
    overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
  }));
  expect(state).toEqual({ hidden: 0, numbers: ['20', '01', '8,170', '24'], overflow: 0 });
  // After counting, each number reads once (no hidden copy left behind).
  expect(await page.locator('.hero-proof-num').innerText()).toMatch(/^8,170\s/);
  await expect(page.locator('.odo[aria-hidden], .visually-hidden')).toHaveCount(0);
  expect(errors).toEqual([]);
});
