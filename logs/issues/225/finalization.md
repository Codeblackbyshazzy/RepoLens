# Issue #225 — Finalization

## Result

Amended the existing issue commit (`0509104`) using the canonical message
file `logs/issues/225/commit-message.txt`. Force-added this finalization
summary so the per-issue artifact lives alongside the code change in the
commit, matching the pattern used by prior finalizer runs (the
`logs/issues/<id>/finalization.md` files for issues 181, 186, 213, 214,
216, 218, 220, 221, 222, 223 were all tracked via `git add -f` despite
the top-level `logs/` gitignore rule).

Not pushed (per finalizer constraints). Issue not closed (the commit
already carries `Closes #225`, GitHub will close on push).

## Scope

The HEAD commit already contained the full issue-#225 implementation:

- `lib/rounds.sh` — wave-width helper (`_rounds_wave_width`), seed
  sanitizer (`_rounds_sanitize_seed`), and `_rounds_select_wave_1` which
  synthesizes `round-0/dispatch.md` with one
  `GENERIC: role=broader focus="<seed>"` per investigation seed. Wired
  into `run_rounds` for `MODE=bugreport` + `STRATEGY=waves`.
- `lib/triage.sh` — `_triage_extract_investigation_seeds` (dedup, marker
  stripping, hostile-character sanitization) and extraction wired into
  `run_triage` against the **raw** agent output before the 2 KB pack
  truncation. Resume branch backfills `investigation-seeds.txt` from an
  existing `context-pack.md` for older runs.
- `prompts/_base/triage.md` — added step **7. Investigation seeds** and
  the corresponding output-schema section.
- `tests/test_bugreport_wave1_seeds.sh` — 31-assertion suite covering
  the schema, extractor, `run_triage` integration via `_TRIAGE_AGENT_CALLBACK`
  (no real model invoked), and wave-1 dispatch synthesis including
  hostile-seed handling.

The amend reuses `logs/issues/225/commit-message.txt` verbatim
(`feat: bugreport wave-1: select n broader investigators from triage
investigation seeds` + `Closes #225`) and adds this finalization file.

## Out of Scope (left untouched)

The working tree on entry showed deletions of unrelated
`logs/issues/<id>/finalization.md` files for 181, 186, 213, 214, 216,
218, 220, 221, 222, 223. These were produced by a separate pipeline pass
and have no relationship to issue #225, so per scope-containment they
were left unstaged.

## Commands Run

```
git status
git log -1 --stat HEAD
git diff --stat HEAD
git check-ignore -v logs/issues/225/finalization.md
git add -f logs/issues/225/finalization.md
git commit --amend -F logs/issues/225/commit-message.txt
git status
git log -1 --stat HEAD
```

## Notes

- `logs/` is gitignored, so `git add -f` is required to track per-issue
  finalization summaries. This matches the pattern used by every prior
  finalizer commit on the branch.
- No source files (`lib/`, `prompts/`, `tests/`) were modified during
  finalization — only the per-issue finalization summary was added.
