# Test Fixtures

`test_key` and `test_key.pub` are a passwordless ed25519 keypair committed
intentionally for the Docker SSH integration test.

This keypair is test-only. Do not add it to any real `authorized_keys` file, and
do not use it for access to any system outside the local test container.

`manifest_with_severities.json` is a mixed-severity finding array consumed by the
result-pointer fixtures harness (`tests/result_pointer_test_lib.sh`). It mixes
canonical, uppercase, bracketed-display, invalid (`info`), and severity-less
entries so `severity_normalize` is exercised: the expected normalized counts are
`critical:1, high:2, medium:1, low:1` (the `info` and severity-less entries are
dropped).
