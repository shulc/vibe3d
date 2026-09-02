#!/usr/bin/env bash
set -euo pipefail

readonly expected='localhost,127.0.0.1,::1'
readonly workflow='.github/workflows/ci.yaml'

if [[ ${no_proxy-} != "$expected" ]]; then
    echo "ci_proxy_bypass: FAIL — job environment no_proxy is '${no_proxy-<unset>}', expected '$expected'" >&2
    exit 1
fi

# Six spaces place these keys under jobs.build.env. This source assertion is
# deliberately independent of the runner service environment: removing the
# repository belt must fail even when the host already supplies the same value.
if ! grep -Fqx "      no_proxy: \"$expected\"" "$workflow"; then
    echo "ci_proxy_bypass: FAIL — $workflow does not declare build-job env.no_proxy as \"$expected\"" >&2
    exit 1
fi

if ! grep -Fqx "      NO_PROXY: \"$expected\"" "$workflow"; then
    echo "ci_proxy_bypass: FAIL — $workflow does not declare build-job env.NO_PROXY as \"$expected\"" >&2
    exit 1
fi

echo "ci_proxy_bypass: PASS — build-job loopback traffic bypasses proxies"
