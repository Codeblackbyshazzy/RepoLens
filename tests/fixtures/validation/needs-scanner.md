# Vulnerable transitive dependency in the lockfile

## Summary

A pinned transitive dependency carries a published CVE for an unsafe
deserialization path. The finding has a concrete anchor, but confirming
exploitability requires an external advisory database, not a local check.

## Impact

Potential remote code execution if the affected deserializer is reachable from
a public route.

## Recommended Fix

Bump the dependency past the fixed version and regenerate the lockfile.

## Validation
- attacker_source — crafted payload reaching the vendored deserializer
- missing_guard — dependency pinned to a version with a known CVE, never upgraded
- sink_effect — deserialization gadget chain enabling remote code execution
- preconditions — the affected code path is reachable from a public route
- proof_anchors — package.json:12
- suggested_validation — npm audit --production
