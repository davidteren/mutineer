// Apply the theme in <head>, before the first paint. No framework required.
(function () {
  var root = document.documentElement;
  var system = window.matchMedia('(prefers-color-scheme: light)');
  var saved;
  try { saved = localStorage.getItem('mutineer-theme'); } catch (e) {}
  var explicit = saved === 'light' || saved === 'dark';
  root.setAttribute('data-theme', explicit ? saved : (system.matches ? 'light' : 'dark'));
  // Motion follows the visitor's system setting. It is set in <head> so the
  // motion styles apply from the first paint.
  var motion = 'IntersectionObserver' in window && !window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (motion) root.classList.add('motion');

  document.addEventListener('DOMContentLoaded', function () {
    var btn = document.getElementById('theme');
    function sync() {
      if (!btn) return;
      var dark = root.getAttribute('data-theme') === 'dark';
      btn.setAttribute('aria-label', dark ? 'Dark theme. Switch to light mode' : 'Light theme. Switch to dark mode');
      btn.innerHTML = '◐ <span>' + (dark ? 'Dark' : 'Light') + '</span>';
      btn.title = dark ? 'Switch to light mode' : 'Switch to dark mode';
    }
    sync();
    if (btn) {
      btn.hidden = false;
      btn.addEventListener('click', function () {
        var next = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
        explicit = true;
        root.setAttribute('data-theme', next);
        try { localStorage.setItem('mutineer-theme', next); } catch (e) {}
        sync();
      });
    }
    system.addEventListener('change', function (event) {
      if (explicit) return;
      root.setAttribute('data-theme', event.matches ? 'light' : 'dark');
      sync();
    });

    // Copy controls report failure and remain reusable after repeated clicks.
    document.querySelectorAll('.copy').forEach(function (button) {
      var timer, pending = false;
      button.hidden = false;
      button.setAttribute('aria-live', 'polite');
      button.addEventListener('click', async function () {
        if (pending) return;
        pending = true;
        clearTimeout(timer);
        try {
          await navigator.clipboard.writeText(button.getAttribute('data-copy') || '');
          button.textContent = 'Copied ✓';
        } catch (e) {
          button.textContent = 'Select text';
        }
        pending = false;
        timer = setTimeout(function () { button.textContent = 'Copy'; }, 1800);
      });
    });

    // Docs: highlight the table-of-contents entry for the section in view.
    var tocLinks = Array.prototype.slice.call(document.querySelectorAll('.doc-side a[href^="#"]'));
    if (tocLinks.length && 'IntersectionObserver' in window) {
      var byId = {};
      tocLinks.forEach(function (a) { byId[a.getAttribute('href').slice(1)] = a; });
      var seen = new Set();
      var obs = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) seen.add(e.target.id); else seen.delete(e.target.id);
        });
        tocLinks.forEach(function (a) { a.classList.remove('active'); });
        for (var i = 0; i < tocLinks.length; i++) {
          var id = tocLinks[i].getAttribute('href').slice(1);
          if (seen.has(id)) { tocLinks[i].classList.add('active'); break; }
        }
      }, { rootMargin: '-70px 0px -70% 0px' });
      Object.keys(byId).forEach(function (id) {
        var el = document.getElementById(id);
        if (el) obs.observe(el);
      });
    }

    // Motion: a scroll progress bar, count-ups, and sections that rise into view.
    if (motion) {
      // One observer per threshold, shared by every element that uses it. Each
      // observer has its own callback map, so one element can wait at two
      // thresholds.
      var observers = {};
      var once = function (el, fn, threshold) {
        var t = threshold == null ? 0.2 : threshold;
        var o = observers[t];
        if (!o) {
          o = observers[t] = { callbacks: new Map() };
          o.io = new IntersectionObserver(function (entries) {
            entries.forEach(function (e) {
              if (!e.isIntersecting) return;
              o.io.unobserve(e.target);
              var fn = o.callbacks.get(e.target);
              o.callbacks.delete(e.target);
              if (fn) fn(e.target);
            });
          }, { threshold: t });
        }
        o.callbacks.set(el, fn);
        o.io.observe(el);
      };
      // Runs a count-up until it ends or counter.finish() stops it.
      var count = function (counter, ms) {
        var start = performance.now();
        (function tick(now) {
          if (counter.finished) return;
          var p = Math.min(1, (now - start) / ms), eased = 1 - Math.pow(1 - p, 3);
          counter.el.textContent = counter.format(counter.from + (counter.to - counter.from) * eased);
          if (p < 1) requestAnimationFrame(tick); else counter.finish();
        })(start);
      };
      var grouped = function (n) { return Math.round(n).toLocaleString('en-US'); };

      var bar = document.createElement('div');
      bar.className = 'scroll-progress';
      document.body.appendChild(bar);
      var progress = function () {
        var h = document.documentElement.scrollHeight - innerHeight;
        bar.style.transform = 'scaleX(' + (h > 0 ? scrollY / h : 0) + ')';
      };
      addEventListener('scroll', progress, { passive: true });
      addEventListener('resize', progress);
      progress();

      var install = document.querySelector('#install .codeblock .typed-text');
      // Items that come into view in the same frame stagger by 80 ms; an item
      // that comes in alone starts at once.
      var batch = 0, batchFrame = null;
      var show = function (el) {
        el.style.setProperty('--d', Math.min(batch++, 6) * 80 + 'ms');
        if (!batchFrame) batchFrame = requestAnimationFrame(function () { batch = 0; batchFrame = null; });
        el.classList.add('is-in');
      };
      ['.sec-head', '.step', '.usecase', '.card', '.evidence-strip', '.cta', '#install .codeblock', '#install .sub'].forEach(function (sel) {
        document.querySelectorAll(sel).forEach(function (el) {
          // The hero already animates in on load; hiding it again would flicker.
          if (el.closest('.hero')) return;
          el.classList.add('reveal');
          once(el, show);
        });
      });
      // Table rows cascade as one group when the table first shows, so a row
      // scrolled into view later is not held back by its position.
      document.querySelectorAll('.table-wrap tbody').forEach(function (body) {
        var rows = Array.prototype.slice.call(body.rows);
        rows.forEach(function (row, i) {
          row.style.setProperty('--d', Math.min(i, 20) * 28 + 'ms');
          row.classList.add('reveal');
        });
        once(body, function () { rows.forEach(function (row) { row.classList.add('is-in'); }); }, 0);
      });
      // In testing, Chrome did not report the fully clipped install line as
      // intersecting, so its column starts the typing as soon as any of it
      // shows, even when a restored scroll position hides the label above.
      if (install) {
        install.classList.add('typed');
        once(install.closest('.codeblock').parentElement, function () { install.classList.add('is-in'); }, 0);
      }

      // Count-ups: each .odo counts from data-from to the number in the HTML.
      // While it counts, a hidden copy holds the real value for screen readers;
      // when it ends, the copy goes so copy and find see the number once.
      var counters = [];
      document.querySelectorAll('.odo[data-from]').forEach(function (el) {
        var text = el.textContent, card = el.closest('.hero-proof');
        var counter = {
          el: el,
          to: parseInt(text.replace(/,/g, ''), 10),
          from: +el.getAttribute('data-from'),
          // Keep leading zeros only where the page writes them ("01").
          format: /,/.test(text) ? grouped : function (n) { return String(Math.round(n)).padStart(/^0\d/.test(text) ? text.length : 1, '0'); },
          meter: card && card.querySelector('.proof-meter span'),
          real: document.createElement('span'),
          finished: false,
          // Shows the real value and drops the hidden copy; later frames stop.
          finish: function () {
            if (counter.finished) return;
            counter.finished = true;
            el.textContent = text;
            counter.real.remove();
            el.removeAttribute('aria-hidden');
            if (counter.meter) counter.meter.classList.add('go');
          }
        };
        counter.real.className = 'visually-hidden';
        counter.real.textContent = text;
        el.setAttribute('aria-hidden', 'true');
        el.parentNode.insertBefore(counter.real, el.nextSibling);
        el.textContent = counter.format(counter.from);
        counters.push(counter);
        once(el, function () {
          if (counter.finished) return;
          if (counter.meter) counter.meter.classList.add('go');
          count(counter, counter.from > counter.to ? 1800 : 900);
        }, 0.5);
      });
      // Printing before a count ends would show a start or middle value.
      addEventListener('beforeprint', function () { counters.forEach(function (c) { c.finish(); }); });
    }
  });
})();
