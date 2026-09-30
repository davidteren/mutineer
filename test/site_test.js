// Run with: node --test test/site_test.js
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const BASE = 'https://davidteren.github.io/mutineer';
const ALTERNATE = 'rel="alternate" type="text/markdown"';
// `rake site:build` output. Two files checked here (json-schema.html,
// sitemap.xml) are Pages build artifacts, not committed — run
// `bundle exec rake site:build` before this suite.
const SITE = '_site';

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
