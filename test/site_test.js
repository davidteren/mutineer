// Run with: node --test test/site_test.js
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const BASE = 'https://davidteren.github.io/mutineer';
const ALTERNATE = 'rel="alternate" type="text/markdown"';
// `rake site:build` output. Two files checked here (json-schema.html,
// sitemap.xml) are Pages build artifacts, not committed — run
// `bundle exec rake site:build` before this suite.
const SITE = '_site';

test('built pages have valid local links and unique anchors, including the API', () => {
  const result = spawnSync('python3', ['test/site_links.py', SITE], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.error?.message || result.stderr || result.stdout);
});

test('link checker rejects files outside the published tree and root-absolute URLs', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mutineer-site-links-'));
  try {
    const site = path.join(directory, 'site');
    fs.mkdirSync(site);
    fs.writeFileSync(path.join(directory, 'outside.txt'), 'This file is not published.');
    fs.writeFileSync(path.join(site, 'index.html'), '<a href="../outside.txt">outside</a>');
    const result = spawnSync('python3', ['test/site_links.py', site], { encoding: 'utf8' });
    assert.equal(result.status, 1, result.error?.message || result.stdout);
    assert.match(result.stderr, /outside site/);
    fs.writeFileSync(path.join(site, 'inside.txt'), 'This file is published under /mutineer/.');
    fs.writeFileSync(path.join(site, 'index.html'), '<a href="/inside.txt">wrong origin path</a>');
    const absolute = spawnSync('python3', ['test/site_links.py', site], { encoding: 'utf8' });
    assert.equal(absolute.status, 1, absolute.error?.message || absolute.stdout);
    assert.match(absolute.stderr, /root-absolute URL/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('link checker rejects a missing file, fragment or site URL, and a duplicate anchor', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mutineer-site-links-'));
  try {
    fs.writeFileSync(path.join(directory, 'page.html'), '<h2 id="here">here</h2>');
    const cases = {
      'missing file': '<a href="gone.html">x</a>',
      'missing fragment': '<a href="page.html#nowhere">x</a>',
      'duplicate anchor': '<a href="page.html">x</a><p id="twice"></p><p id="twice"></p>',
      'missing file.*davidteren': `<a href="${BASE}/gone.html">x</a>`,
      'missing fragment.*davidteren': `<a href="${BASE}/page.html#nowhere">x</a>`
    };
    for (const [message, html] of Object.entries(cases)) {
      fs.writeFileSync(path.join(directory, 'index.html'), html);
      const result = spawnSync('python3', ['test/site_links.py', directory], { encoding: 'utf8' });
      assert.equal(result.status, 1, `${message}: ${result.error?.message || result.stdout}`);
      assert.match(result.stderr, new RegExp(message));
    }
    fs.writeFileSync(path.join(directory, 'index.html'), `<a href="${BASE}/page.html#here">ok</a>`);
    const good = spawnSync('python3', ['test/site_links.py', directory], { encoding: 'utf8' });
    assert.equal(good.status, 0, good.stderr);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('HTML pages with markdown twins advertise rel=alternate', () => {
  const twins = {
    [`${SITE}/index.html`]: `${BASE}/index.md`,
    [`${SITE}/agentic-coding.html`]: `${BASE}/agentic-coding.md`,
    [`${SITE}/json-schema.html`]: `${BASE}/json-schema.md`
  };
  for (const [html, href] of Object.entries(twins)) {
    const source = fs.readFileSync(html, 'utf8');
    assert.match(source, new RegExp(ALTERNATE.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
    assert.match(source, new RegExp(href.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  }
});

test('index.md landing twin exists and sitemap lists the same Pages URLs as llms.txt', () => {
  const indexMd = fs.readFileSync(`${SITE}/index.md`, 'utf8');
  assert.match(indexMd, /gem install mutineer/);
  assert.match(indexMd, /mutineer run/);
  const llms = fs.readFileSync(`${SITE}/llms.txt`, 'utf8');
  assert.match(llms, /## Optional/);
  assert.match(llms, new RegExp(`${BASE}/skill\\.md`));
  const pagesUrls = [...llms.matchAll(/https:\/\/davidteren\.github\.io\/mutineer[^)\s]*/g)].map((m) => m[0]);
  pagesUrls.push(`${BASE}/llms.txt`);
  const sitemap = fs.readFileSync(`${SITE}/sitemap.xml`, 'utf8');
  const unique = [...new Set(pagesUrls)];
  assert.ok(unique.length >= 8, 'llms.txt should list the docs + optional Pages URLs');
  for (const url of unique) {
    assert.match(sitemap, new RegExp(`<loc>${url.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}</loc>`));
  }
});


// A small browser boundary checks theme selection and copy feedback without a dependency.
test('site follows system theme until chosen, tolerates blocked storage, and reports copy failures', async () => {
  for (const saved of [null, 'invalid', 'dark', 'light']) {
    const events = {}, attrs = {}, button = { hidden: true, setAttribute(k, v) { attrs[k] = v; }, addEventListener(k, v) { events[k] = v; } };
    const root = { setAttribute(k, v) { attrs[k] = v; }, getAttribute(k) { return attrs[k]; } };
    const copy = { hidden: true, setAttribute() {}, getAttribute() { return 'gem install mutineer'; }, addEventListener(k, fn) { this.click = fn; } };
    const system = { matches: true, addEventListener(k, fn) { this.change = fn; } };
    let ready, reset, copied;
    const context = {
      document: { documentElement: root, getElementById() { return button; }, addEventListener(k, fn) { ready = fn; }, querySelectorAll(selector) { return selector === '.copy' ? [copy] : []; } },
      window: { matchMedia() { return system; } },
      localStorage: { getItem() { return saved; }, setItem() { throw Error('blocked'); } },
      navigator: { clipboard: { async writeText(text) { copied = text; } } },
      setTimeout(fn) { reset = fn; }, clearTimeout() {}
    };
    vm.runInNewContext(fs.readFileSync('docs/assets/mutineer.js', 'utf8'), context);
    assert.equal(attrs['data-theme'], saved === 'dark' ? 'dark' : 'light');
    ready();
    assert.equal(button.hidden, false);
    system.change({ matches: false });
    assert.equal(attrs['data-theme'], saved === 'light' ? 'light' : 'dark');
    events.click();
    const chosen = attrs['data-theme'];
    system.change({ matches: chosen !== 'light' });
    assert.equal(attrs['data-theme'], chosen);
    assert.match(attrs['aria-label'], new RegExp(chosen === 'dark' ? '^Dark theme' : '^Light theme'));
    await copy.click();
    assert.equal(copied, 'gem install mutineer');
    assert.equal(copy.textContent, 'Copied ✓');
    reset();
    assert.equal(copy.textContent, 'Copy');
    let finishCopy, calls = 0;
    context.navigator.clipboard.writeText = () => { calls++; return new Promise(resolve => { finishCopy = resolve; }); };
    const firstClick = copy.click();
    await copy.click();
    assert.equal(calls, 1, 'overlapping clicks must share the pending write');
    finishCopy();
    await firstClick;
    assert.equal(copy.textContent, 'Copied ✓');
    reset();
    context.navigator.clipboard.writeText = async () => { throw Error('denied'); };
    await copy.click();
    assert.equal(copy.textContent, 'Select text');
    reset();
    assert.equal(copy.textContent, 'Copy');
    context.localStorage.getItem = () => { throw Error('blocked'); };
    vm.runInNewContext(fs.readFileSync('docs/assets/mutineer.js', 'utf8'), context);
    assert.equal(attrs['data-theme'], 'light');
  }
});
