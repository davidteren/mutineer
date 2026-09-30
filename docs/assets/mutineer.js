// Apply the theme in <head>, before the first paint. No framework required.
(function () {
  var root = document.documentElement;
  var system = window.matchMedia('(prefers-color-scheme: light)');
  var saved;
  try { saved = localStorage.getItem('mutineer-theme'); } catch (e) {}
  var explicit = saved === 'light' || saved === 'dark';
  root.setAttribute('data-theme', explicit ? saved : (system.matches ? 'light' : 'dark'));
  // Motion is opt-out by the visitor's system setting. Set before the first
  // paint so content that animates in never flashes first.
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
      var once = function (el, fn, threshold) {
        var io = new IntersectionObserver(function (entries) {
          entries.forEach(function (e) { if (e.isIntersecting) { io.unobserve(e.target); fn(e.target); } });
        }, { threshold: threshold || 0.2 });
        io.observe(el);
      };
      var count = function (el, from, to, ms, format) {
        var start = performance.now();
        (function tick(now) {
          var p = Math.min(1, (now - start) / ms), eased = 1 - Math.pow(1 - p, 3);
          el.textContent = format(from + (to - from) * eased);
          if (p < 1) requestAnimationFrame(tick);
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
      progress();
    
      ['.sec-head', '.step', '.usecase', '.card', '.evidence-strip', '.cta', '.table-wrap tbody tr', '#install .codeblock', '#install .sub'].forEach(function (sel) {
        document.querySelectorAll(sel).forEach(function (el) {
          var row = el.tagName === 'TR';
          var i = Array.prototype.indexOf.call(el.parentElement.children, el);
          el.style.setProperty('--d', Math.min(i, row ? 20 : 6) * (row ? 28 : 80) + 'ms');
          el.classList.add('reveal');
          once(el, function (x) { x.classList.add('is-in'); }, row ? 0.1 : 0.2);
        });
      });
      var install = document.querySelector('#install .codeblock');
      // A fully clipped element never counts as visible, so its label above
      // starts the typing.
      if (install && install.previousElementSibling) {
        install.classList.replace('reveal', 'typed');
        once(install.previousElementSibling, function () { install.classList.add('is-in'); }, 0.5);
      }
    
      document.querySelectorAll('.badge b').forEach(function (b) {
        var to = parseInt(b.textContent, 10), width = b.textContent.length;
        if (!(to > 0)) return;
        b.textContent = '0'.padStart(width, '0');
        setTimeout(function () { count(b, 0, to, 900, function (n) { return String(Math.round(n)).padStart(width, '0'); }); }, 500);
      });
    
      var caught = document.querySelector('.evidence-strip strong');
      if (caught && /^24 caught/.test(caught.textContent)) {
        caught.innerHTML = '<span class="odo">0</span> caught. 1 missed.';
        once(caught, function () { count(caught.firstChild, 0, 24, 900, grouped); });
      }
    
      document.querySelectorAll('.odo[data-from]').forEach(function (el) {
        var to = parseInt(el.textContent.replace(/,/g, ''), 10), from = +el.getAttribute('data-from');
        var meter = el.closest('.hero-proof').querySelector('.proof-meter span');
        el.textContent = grouped(from);
        once(el, function () { count(el, from, to, 1800, grouped); if (meter) meter.classList.add('go'); }, 0.5);
      });
    }
  });
})();
