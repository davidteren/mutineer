"""Check local files, fragments, and unique anchors in the built HTML site."""

from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import re
import sys

# Pages serves the site here, so an absolute link under it is a local link.
SITE_HOST = "davidteren.github.io"
SITE_PATH = "/mutineer/"
# Links to README sections on GitHub, checked against the README's headings.
README_URL = "https://github.com/davidteren/mutineer"
README = Path(__file__).resolve().parent.parent / "README.md"


def github_slug(heading):
    """GitHub's anchor for a Markdown heading: lower case, punctuation dropped, spaces to hyphens."""
    return re.sub(r"[^\w\- ]", "", heading.strip().lower()).replace(" ", "-")


README_ANCHORS = {github_slug(line.lstrip("#")) for line in README.read_text().splitlines() if re.match(r"#+ ", line)}


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
        if url.startswith(README_URL + "#"):
            if unquote(parts.fragment) not in README_ANCHORS:
                errors.append(f"{path.relative_to(root)}:{line}: missing README section {url!r}")
            continue
        if parts.scheme == "https" and parts.netloc == SITE_HOST and (parts.path + "/").startswith(SITE_PATH):
            target = root / unquote(parts.path[len(SITE_PATH):])
        elif parts.scheme or parts.netloc:
            continue
        elif parts.path.startswith("/"):
            errors.append(f"{path.relative_to(root)}:{line}: root-absolute URL {url!r}; use a relative URL under /mutineer/")
            continue
        else:
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
print(f"Checked local and same-site links and anchors in {len(pages)} HTML pages.")
