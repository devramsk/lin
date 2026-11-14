#!/usr/bin/env bash
set -euo pipefail
script=$(cd "$(dirname "$0")/.." && pwd)/scripts/reclaim-hosted-space.sh
if env -u GITHUB_ACTIONS -u RUNNER_ENVIRONMENT -u RUNNER_OS bash "$script" >/dev/null 2>&1; then
  echo 'Cleanup accepted a non-runner environment' >&2; exit 1
fi
if env GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted RUNNER_OS=Linux GITHUB_WORKSPACE='' RUNNER_TEMP='' bash "$script" >/dev/null 2>&1; then
  echo 'Cleanup accepted missing runner paths' >&2; exit 1
fi
echo 'Reclaim safety checks passed'
