// Theme: respect saved choice, else system. localStorage + matchMedia, no framework.
(function () {
  var root = document.documentElement, btn = document.getElementById('theme');
  var saved = null;
  try { saved = localStorage.getItem('mutineer-theme'); } catch (e) {}
  if (saved) {
    root.setAttribute('data-theme', saved);
  } else if (window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches) {
    root.setAttribute('data-theme', 'light');
  }
  function sync() { if (btn) btn.setAttribute('aria-pressed', root.getAttribute('data-theme') === 'dark'); }
  sync();
  if (btn) {
    btn.addEventListener('click', function () {
      var next = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      try { localStorage.setItem('mutineer-theme', next); } catch (e) {}
      sync();
    });
  }

  // Copy buttons.
  document.querySelectorAll('.copy').forEach(function (b) {
    b.addEventListener('click', function () {
      var txt = b.getAttribute('data-copy') || '';
      navigator.clipboard && navigator.clipboard.writeText(txt).then(function () {
        var old = b.textContent; b.textContent = 'Copied ✓';
        setTimeout(function () { b.textContent = old; }, 1400);
      });
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
})();
