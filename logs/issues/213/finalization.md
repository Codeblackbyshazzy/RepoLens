# Finalization Summary

Issue: #213

## Changes Reviewed

- `lib/streak.sh`: adds `classify_agent_iteration` to distinguish persistent auth, model availability, and budget failures from rate limits and unknown failures.
- `repolens.sh`: aborts the run immediately for persistent agent failures, records the precise stopped reason, avoids marking the failed lens completed, exits non-zero for the new abort sentinel, and clears stale systemic abort state on resume.
- `lib/parallel.sh`: includes the systemic failure sentinel in parallel abort detection.
- `lib/rounds.sh`: maps the systemic failure sentinel back to a precise skipped-lens stop reason when possible.
- `tests/test_agent_failure_classification.sh`: covers classifier behavior for auth, model, budget, rate-limit, unknown, and successful outputs.
- `tests/test_persistent_agent_failure_abort.sh`: covers one-iteration global abort behavior, skipped lens recording, completion marker handling, and resume cleanup.
- `tests/fixtures/agent-persistent-failures/`: adds representative auth, model, and budget failure outputs.

## Commands Run

- `git status --short`
- `git diff --stat -- ./repolens.sh ./lib/parallel.sh ./lib/rounds.sh ./lib/streak.sh ./tests/test_agent_failure_classification.sh ./tests/test_persistent_agent_failure_abort.sh ./tests/fixtures/agent-persistent-failures`
- `git diff -- ./repolens.sh ./lib/parallel.sh ./lib/rounds.sh ./lib/streak.sh ./tests/test_agent_failure_classification.sh ./tests/test_persistent_agent_failure_abort.sh`
- `find ./tests/fixtures/agent-persistent-failures -maxdepth 3 -type f -print`
- `sed -n '1,220p' logs/issues/213/commit-message.txt`
- `sed -n '1,240p' ./tests/test_agent_failure_classification.sh`
- `sed -n '1,260p' ./tests/test_persistent_agent_failure_abort.sh`
- `find ./tests/fixtures/agent-persistent-failures -maxdepth 1 -type f -print -exec sed -n '1,80p' {} \;`
- `git diff --check -- ./repolens.sh ./lib/parallel.sh ./lib/rounds.sh ./lib/streak.sh ./tests/test_agent_failure_classification.sh ./tests/test_persistent_agent_failure_abort.sh ./tests/fixtures/agent-persistent-failures`
- `sed -n '261,520p' ./tests/test_persistent_agent_failure_abort.sh`
- `bash ./tests/test_agent_failure_classification.sh`
- `bash ./tests/test_persistent_agent_failure_abort.sh`
- `ls -la ./logs/issues/213`

## Verification

- `git diff --check` passed with no whitespace errors.
- `bash ./tests/test_agent_failure_classification.sh` passed: 6 passed, 0 failed.
- `bash ./tests/test_persistent_agent_failure_abort.sh` passed: 48 passed, 0 failed.

## Final Git Status

The final commit is expected to leave the working tree clean except for any files outside the issue scope that may be changed concurrently by another process. A post-commit `git status --short` check will be run after committing and reported by the finalizer.
