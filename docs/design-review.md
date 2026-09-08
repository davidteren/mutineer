# GitHub Pages design review

The site now puts a specific mutation beside the main message. Four pages share a
new light and dark theme. The redesign uses large type, flat surfaces, and ruled
sections to make the product evidence easier to find.

## Context

Mutineer is a Ruby mutation-testing tool. Its website serves developers who need
to understand a result, install the tool, or connect it to a build pipeline.
These readers need evidence and clear instructions. They do not need a sales funnel.

## First impression

The previous homepage used a charcoal canvas, red gradient headline, pill label,
three adjacent action buttons, five badges, and a mock terminal. These choices
made it look like a general developer-product template. The terminal appeared
below the first viewport at 1280 × 627. The actual code change deserved more space.
This is an assessment of this page, not a claim that all recent sites use this design.

## Visual design

- The same rounded surface appeared in the steps, features, and use cases. This
  gave different kinds of information the same weight. Ruled steps, two-column
  feature lists, and horizontal use cases now give each section a distinct structure.
- The red brand accent also represented surviving mutants. The new brand palette
  separates navigation and actions from result status colours.
- Faint labels were hard to read. Text colours now use stronger contrast in both themes.
- The terminal window controls added decoration without function. The new operator
  specimen uses the actual `>=` to `>` change as its main graphic.

## Interface design

- Three hero buttons competed for attention. Install is now the main action;
  the secondary link explains the workflow.
- The mutation example lacked an immediate explanation of a useful test. A native
  disclosure now shows the assertion for the boundary at 10. It is explicitly an
  illustration, not a live Ruby runner.
- The example score was wrong: 24 killed and 1 survived give 96%, not 92.3%.
  The new result strip states the correct denominator and excludes uncovered mutants.
- Copy failure had no feedback. The button now says “Select text” when clipboard
  access fails, then resets. A saved theme now applies before the first paint.

## Consistency and conventions

The homepage, agent guide, JSON reference, and sample report share the same
navigation. Mobile navigation wraps; it does not hide documentation links.
Tables can scroll horizontally and receive keyboard focus. Theme controls state
the current mode, retain the user's choice, and follow system changes until the
user makes a choice. Reduced-motion settings disable entrance motion.

The sample report uses the website theme. Its note explains that the CLI report
has its own presentation. The report generator and output contract are unchanged.

## User context

A survivor asks the developer to inspect a test. It does not prove that the whole
test is useless. The homepage now makes room for equivalent mutations and states
what the developer can do next. The guide and schema retain their detailed content.

## References and design choices

Interface Craft's Design Critique supplied the review sequence: context, first
impression, visual design, interface design, conventions, and user needs.
Refero supplied the reference-lock method. Live Refero tools and its referenced
craft files were unavailable in this session; public pages supplied the references.

| Choice | Source | Scope and reason |
| --- | --- | --- |
| Code beside the introduction | [Ruby homepage](https://www.ruby-lang.org/en/) | Its visible source examples informed the product-evidence role, not its loading animation. |
| Direct access to technical material | [SQLite homepage](https://www.sqlite.org/index.html) | Its common-links index informed navigation and the documentation index. |
| A distinct operator specimen | Mutineer's existing comparison example | The product's actual operation provides the graphic; no stock illustration is needed. |
| Flat plum and orchid surfaces | User-requested random strings | Colour exploration starts outside the standard red/charcoal Ruby palette. |
| Brief, named entrance timing | Interface Craft | The heading enters at 0 ms and evidence at 90 ms, over 420 ms. No loop or scroll gate hides content. |

The primary direction is a test inspection sheet: oversized sans-serif headlines,
monospaced annotations, an exposed code change, square edges, and ruled sections.
The secondary references contribute only code placement and navigation structure.
Reject gradients, floating card grids, fake window controls, and decorative hero art.
The operator graphic is native text and remains sharp at every viewport size.

## Random colour seeds

Python's `secrets.token_urlsafe(9)` generated three strings. For each string,
`int(sha256(seed).hexdigest()[:8], 16) % 360` produced a candidate hue.

| String | Hue | Decision |
| --- | --- | --- |
| `YpUmNUmK6m8u` | 301° | Selected: plum ink and orchid surfaces. |
| `o4XpYy_CLMBV` | 11° | Rejected: too close to the previous red/orange identity. |
| `HDRHyfcYXJu8` | 322° | Rejected: too close to the selected hue to offer a useful alternative. |

The hue is an inspiration, not an unchecked random CSS colour. Saturation and
lightness were adjusted for readable text. The dark action colour uses a 120°
offset from the seed hue. Colour is fixed at build time; page loads do not randomise it.

| Role | Dark | Light |
| --- | --- | --- |
| Canvas | `#211922` | `#f4eef4` |
| Main text | `#f5edf4` | `#302133` |
| Action | `#e7ed94` | `#67286a` |
| Code specimen | `#e9b4e6` | `#e6b1e3` |

## Highest-impact changes

1. Show the changed code where the reader first encounters the product.
2. Give installation one clear primary action.
3. Keep all documentation routes available on small screens.
4. Preserve the meaning of scores and give copy failures visible feedback.
5. Use one visual system across the four website pages.

## Validation

- `bundle exec rake test`: 451 tests and 1,355 assertions passed; no failures, errors, or skips.
- Ruby load smoke check passed. `bundle exec rake yard:strict` passed with 100% documentation; it printed existing link/option warnings.
- `node --test test/site_test.js` passed. It checks saved, invalid, and blocked-storage themes; system changes; explicit choices; and copy success/failure feedback.
- Local link and fragment checks passed for all four pages, with no duplicate IDs.
- Browser measurements found no page-wide overflow at 390 px on all four pages, or at 320 px on the homepage. JSON tables scroll within their containers.
- Desktop screenshots covered both homepage themes and the dark guide. Mobile screenshots covered all four pages in light mode.
- Native disclosure opened through both click and Enter. Keyboard focus had a visible outline. Copy showed “Copied ✓”. A light theme choice survived reload while the emulated system remained dark.
- Lighthouse snapshot scores were 100 for accessibility, best practices, and SEO on the redesigned homepage, guide, JSON reference, and sample report in the tested states. The original dark homepage scored 92 for accessibility.
- An initial local desktop audit reported an `llms.txt` failure; subsequent audits returned 100 for agentic browsing. The existing `llms.txt` was not changed. Snapshot audits do not measure loading performance or prove full accessibility compliance.

Chrome DevTools supplied layout measurements, screenshots, and Lighthouse audits.
Computer Use supplied inspection of the original site and public references.
No UI framework, animation package, font download, or image-generation dependency
was needed. The code change itself supplies the visual identity.

This review covers the website redesign. Deployment to the public site is a separate step.
