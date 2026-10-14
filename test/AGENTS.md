# Tests in this application

## Baseline

`mix test test/alplus_web` is **999/999 passing** (2026-08-28, after the V3
dashboard content rework). Capture the baseline before you start, and compare
against it rather than assuming a failure is yours.

`ErrorIngestControllerTest`'s "fans out a quota alert after an over-ceiling
envelope is committed" **flakes intermittently** and passes on rerun and in
isolation.

## When tests contradict each other

Two files can encode opposite designs, and the suite then cannot be green. Do
not choose by taste, and do not "fix" the implementation to satisfy whichever
file you opened first.

Run `git log --format='%ad %h %s' --date=format:'%m-%d %H:%M' -- <file>` on both
files. The later deliberate commit is the decision; the other file is stale.
Update the stale one.

This happened with `PageControllerTest` and `HomeLiveTest` over the homepage
switches: `aec64640 fix(homepage): keep live controls off the URL` settled it,
`PageControllerTest` was never updated, and ten tests sat red on `master` while
the product was correct.

## Changing a test

Say plainly whether a change is a **contract update** (the design moved, the
test describes the old one) or a **papered-over regression** (the test was
right). Never delete an assertion to get to green.

Test behaviour through the interface a caller uses. Never assert on prose: a
test that greps a Markdown file or a comment fails when someone improves the
wording and passes while the behaviour is broken.

## HEEx escaping

`{"Couldn't load"}` renders `Couldn&#39;t load`, so a literal assertion fails.
Keep literal copy as a text node and interpolate only dynamic values.

## Selection semantics

A control that redraws in place is a button carrying `aria-pressed`. A control
that navigates is a link carrying `aria-current`. Query for the right one; the
homepage uses `aria-pressed` deliberately.
