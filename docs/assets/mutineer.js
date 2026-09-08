// Apply the theme in <head>, before the first paint. No framework required.
(function () {
  var root = document.documentElement;
  var system = window.matchMedia('(prefers-color-scheme: light)');
  var saved;
  try { saved = localStorage.getItem('mutineer-theme'); } catch (e) {}
  var explicit = saved === 'light' || saved === 'dark';
  root.setAttribute('data-theme', explicit ? saved : (system.matches ? 'light' : 'dark'));

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
      var timer;
      button.hidden = false;
      button.setAttribute('aria-live', 'polite');
      button.addEventListener('click', async function () {
        clearTimeout(timer);
        try {
          await navigator.clipboard.writeText(button.getAttribute('data-copy') || '');
          button.textContent = 'Copied ✓';
        } catch (e) {
          button.textContent = 'Select text';
        }
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
  });
})();
