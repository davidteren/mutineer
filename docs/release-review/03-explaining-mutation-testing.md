# Explaining mutation testing to newcomers

Most Ruby developers have not used mutation testing. Many have not heard of it.
The docs were written for people who already know the idea: they are precise,
and they assume the vocabulary. This file looks at what a newcomer meets on
each surface, then lists what changed here and what to do on the site.

## What a newcomer needs, in order

1. **The idea in one breath.** Tests pass; would they fail if the code were
   wrong? Mutineer breaks the code on purpose to find out.
2. **One concrete example.** A line, a change, a test that misses it, and the
   test that catches it.
3. **The words.** Mutant, killed, survived, mutation score, equivalent mutant.
   Then the other report rows, at least by name.
4. **What to do next.** What a survivor asks of you. When to suppress one.
5. **What it costs and where to start.** It is slower than one test run. Start
   with one file.
6. **Why not coverage?** The question every newcomer asks.

## What each surface did before this change

| Surface | 1 Idea | 2 Example | 3 Words | 4 Next step | 5 Cost, start | 6 Coverage |
| --- | --- | --- | --- | --- | --- | --- |
| README | One sentence | None | Not defined. "killed" first appears about 400 lines in, in "Timeouts and the score" | Suppression only | None | None |
| Landing page | Strong ("A passing test is a claim") | Strong (the `qty >= 10` specimen and its killing test) | Killed and survived in one line; score in the evidence strip | One sentence ("Inspect it, strengthen the test") | None | One paragraph, aimed at AI agents |
| Explainer video | Yes | Yes (100% coverage misses a changed comparison) | Not checked frame by frame | | | Yes |
| `docs/index.md` (Markdown twin, also read by agents) | One sentence | None | None | None | None | None |
| `docs/agentic-coding.*` | Yes, for agents | Prompt template | Assumed | Yes, for agents | `--since` keeps loops fast | Yes |
| `llms.txt` | Yes | None | None | | | Yes |
| `skills/mutineer/SKILL.md` | One sentence | None | Assumed | Yes | | Yes |

The landing page is the best teacher in the project. Its specimen and video do
steps 1, 2, and 6 well. The README, which is what RubyGems and GitHub show
first, had one sentence of the idea and none of the other five steps. It is
also the file most people read.

## What this change did

The README now has a section, **What is mutation testing?**, between the
production-ready section and Install. The intro links to it for newcomers and
gives a two-line "try it". It covers all six steps:

- The idea, in four plain sentences.
- A worked example: `Discount#rate` with `qty >= 10`. Two passing tests give
  100% line coverage and a 50% mutation score. The quoted report is from a
  real run. One added test for `rate(10)` kills the survivor.
- Coverage compared with mutation testing, in one paragraph.
- A table of the report rows a user sees (Killed, Survived, No coverage,
  Timeout, Errored, Ignored, Skipped), what each means, and whether it is in
  the score. The three rare rows are named and linked.
- What to do with a survivor, including what an equivalent mutant is, with an
  example (`x * 1` and `x / 1`).
- Where to start: one file, `--dry-run`, then a folder, then `--since`, and the
  Rails guide.

The agent skill card now also says what to do with a survivor that cannot be
killed: stop, report it, and suppress it with a reason through `mutineer triage`.

### Why the section is not at the top

`test_readme_support_matrix_names_each_database` requires the first `##`
heading to be "Is it production-ready?". That is a deliberate choice: the
section is for people deciding whether to gate an app. So the primer sits
second, and the intro links to it. If David would rather newcomers meet the
primer first, move it above the production-ready section and change that test
to look for the section by name instead of position. The site splice finds the
section by its heading, so the home page is not affected.

## Recommendations for the site

These are for David. No site page was edited.

### A. Add a "Mutation testing, explained" page (P1)

A short page linked from the nav ("Learn" or "What is it?") and from the hero
("New to mutation testing?"). Most of the text can come from the README primer.
The site's design adds what the README cannot: the specimen style for the
worked example, and the result table as visual pills. Add it to `llms.txt` and
the sitemap like the other pages. A draft outline:

1. A passing test is a claim (the hero idea, kept).
2. One change at a time: what a mutant is, with the specimen.
3. Killed, survived, and the score, with the evidence strip.
4. The other results, as a table.
5. What to do with a survivor; equivalent mutants and how to suppress one.
6. Coverage and mutation testing (the 100%-coverage, 50%-score example).
7. FAQ:
   - *Is this fuzzing?* No. Fuzzing changes the inputs. Mutation testing
     changes the code and keeps the tests.
   - *Does 100% mean my code has no bugs?* No. It means every change Mutineer
     made was caught. The operators make small, common changes; they do not
     cover every bug.
   - *What score should I aim for?* Start by reading survivors, not by setting
     a number. Gate new code with `--since` and `--baseline` first. Use
     `--threshold` on folders whose score is stable. Mutineer gates its own CI
     at 85%.
   - *How long does it take?* Each mutant re-runs only the tests that cover its
     line, and stops at the first failure. In 1.4, a full run of rack's
     `lib/rack/utils.rb` took 35 to 41 seconds (README, Kill matrix). A first
     run over a whole app takes much longer, so start small.
   - *Do I need to change my tests?* No. Mutineer runs your Minitest or RSpec
     suite as it is.

### B. Use the words the report uses (P1)

The landing page says "caught" and "missed"; the report says "Killed" and
"Survived". Both are fine, but connect them once: "24 caught (killed). 1 missed
(survived)." A newcomer who reads the site and then runs the tool should
recognise every row.

### C. Add a "New to mutation testing?" line to the hero (P1)

Under the hero description, link to the new page or to the "How it works"
section. The hero is strong for people who know the idea; this line catches
those who do not.

### D. Give the Markdown twin a short explanation (P2)

`docs/index.md` is what agents and `llms.txt` readers get. It has one sentence
of idea and goes straight to install. Two short paragraphs from the primer
(the idea and the score) would let an agent explain the tool to its user.

### E. Caption the explainer video (P2)

The video has narration (there is a "Sound on" button) but no `<track>` for
captions. Add a WebVTT file and a short text transcript below the video. That
helps deaf and hard-of-hearing users, people with sound off, and search.
