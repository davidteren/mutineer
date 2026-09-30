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
      // keeps its own callbacks, so one element can wait at two thresholds.
      var observers = {};
      var once = function (el, fn, threshold) {
        var t = threshold || 0.2;
        var o = observers[t];
        if (!o) {
          o = observers[t] = { callbacks: new Map() };
          o.io = new IntersectionObserver(function (entries) {
            entries.forEach(function (e) {
              if (!e.isIntersecting) return;
              o.io.unobserve(e.target);
              var fns = o.callbacks.get(e.target) || [];
              o.callbacks.delete(e.target);
              fns.forEach(function (f) { f(e.target); });
            });
          }, { threshold: t });
        }
        o.callbacks.set(el, (o.callbacks.get(el) || []).concat(fn));
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

      var install = document.querySelector('#install .codeblock');
      ['.sec-head', '.step', '.usecase', '.card', '.evidence-strip', '.cta', '.table-wrap tbody tr', '#install .codeblock', '#install .sub'].forEach(function (sel) {
        document.querySelectorAll(sel).forEach(function (el) {
          // The hero already animates in on load; hiding it again would flicker.
          if (el === install || el.closest('.hero')) return;
          var row = el.tagName === 'TR';
          var i = Array.prototype.indexOf.call(el.parentElement.children, el);
          el.style.setProperty('--d', Math.min(i, row ? 20 : 6) * (row ? 28 : 80) + 'ms');
          el.classList.add('reveal');
          once(el, function (x) { x.classList.add('is-in'); }, row ? 0.1 : 0.2);
        });
      });
      // In testing, Chrome did not report the fully clipped install line as
      // intersecting, so the label above it starts the typing.
      if (install && install.previousElementSibling) {
        install.classList.add('typed');
        once(install.previousElementSibling, function () { install.classList.add('is-in'); }, 0.5);
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
          format: /,/.test(text) ? grouped : function (n) { return String(Math.round(n)).padStart(text.length, '0'); },
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
        // Reserve the wider of the two values so the caption beside it does not move.
        el.style.display = 'inline-block';
        var endWidth = el.getBoundingClientRect().width;
        el.textContent = counter.format(counter.from);
        el.style.minWidth = Math.ceil(Math.max(endWidth, el.getBoundingClientRect().width)) + 'px';
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
