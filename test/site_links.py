"""Check local files, fragments, and unique anchors in the built HTML site."""

from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import sys


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.ids = []
        self.links = []
        self.feed(path.read_text())

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if attrs.get("id"):
            self.ids.append(attrs["id"])
        if tag == "a" and attrs.get("name") and attrs["name"] != attrs.get("id"):
            self.ids.append(attrs["name"])
        for key in ("href", "src"):
            if attrs.get(key):
                self.links.append((self.getpos()[0], attrs[key]))


root = Path(sys.argv[1]).resolve()
pages = {path.resolve(): Page(path) for path in root.rglob("*.html")}
assert pages, f"No built HTML pages found under {root}"
errors = []
for path, page in pages.items():
    for identifier, count in Counter(page.ids).items():
        if count > 1:
            errors.append(f"{path.relative_to(root)}: duplicate anchor {identifier!r}")
    for line, url in page.links:
        parts = urlsplit(url)
        if parts.scheme or parts.netloc:
            continue
        if parts.path.startswith("/"):
            errors.append(f"{path.relative_to(root)}:{line}: root-absolute URL {url!r}; use a relative URL under /mutineer/")
            continue
        target = path.parent / unquote(parts.path) if parts.path else path
        if target.is_dir():
            target /= "index.html"
        target = target.resolve()
        if root not in target.parents:
            errors.append(f"{path.relative_to(root)}:{line}: outside site {url!r}")
        elif not target.exists():
            errors.append(f"{path.relative_to(root)}:{line}: missing file {url!r}")
        elif parts.fragment and target in pages and unquote(parts.fragment) not in pages[target].ids:
            errors.append(f"{path.relative_to(root)}:{line}: missing fragment {url!r}")

if errors:
    sys.exit("\n".join(errors))
print(f"Checked local links and anchors in {len(pages)} HTML pages.")
