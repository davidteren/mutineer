// Run with: node --test test/site_test.js
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

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
