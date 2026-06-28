# Path traversal in the file download endpoint

## Summary

The `name` path parameter on `GET /download` is joined onto a base directory
without normalization, so `../` sequences escape the intended folder and read
arbitrary files from disk.

## Impact

An unauthenticated caller can read any file the service account can access,
including configuration and secrets.

## Recommended Fix

Resolve the requested path and reject anything that escapes the download root,
or serve only from an allowlist of known filenames.

## Validation
- attacker_source — HTTP path parameter `name` on GET /download
- missing_guard — no normalization or allowlist before joining the user path
- sink_effect — open() reads an arbitrary file from disk and streams it back
- preconditions — endpoint is reachable unauthenticated
- proof_anchors — app/download.py:88
- suggested_validation — grep -n "open(.*request" app/download.py
