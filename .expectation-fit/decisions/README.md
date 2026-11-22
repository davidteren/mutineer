# Decision records

Facts and checks that code review taught us about Mutineer. Each line is one
rule that an author or a reviewer applies to a change.

## Why this folder exists

A review tool learned these rules from our feedback and kept them on its own
servers. The person or agent that writes a change could not read them, so the
same findings came back in review. Here every author and every reviewer can
read the same copy. cubic still applies the copy on its servers, so the two
can differ (see Limits).

## Who reads it

- **Authors**, human or agent: read the file for the area you change before
  you open a pull request.
- **Expectation Fit**: `.expectation-fit/ways-of-working.yaml` lists the topic
  files of this folder under `conventions.sources`, so the convention lens of
  `/fit-review` and `/fit-validate-plan` applies each line as a rule. This
  README is not a source.
- **Other reviewers**, human or bot: apply the files by hand.

## How to keep it true

- One line is one rule. Keep a new line to one check, and put it in the file
  for its topic. Some lines from cubic hold several checks on one subject.
- A line states a check. The code, its tests and the user docs remain the full
  description of the behaviour.
- When a change makes a line false, change the line in the same pull request.
- When a review teaches a new fact, add the line here first, by hand, in the
  file for its topic. This folder is the source: nothing copies rules from
  cubic into it. Then teach the review tool, if you use one.
- Before you add a line, name the function, file or doc it checks.
  Confirm that name exists in the code on `main`.
  For a change in an open pull request, add the line in that pull request.
- ``(cubic `xxxxxxxx`)`` at the end of a line is the id of the rule in cubic
  that the line came from. A line that joins two cubic rules has both ids:
  ``(cubic `aaaaaaaa`, `bbbbbbbb`)``. A line with no id was written here.
- `Not when:` starts the case where the check does not apply.

## Limits

- The lines came from cubic on 2026-11-16. Issue #483 checked them against
  the code on 2026-11-22. It deleted lines for code that was not on `main`.
  Correct a line that is wrong when you find it.
