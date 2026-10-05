#!/usr/bin/env bash
set -euo pipefail

# Same fixture source/tag as test/support/integration_fixtures.ex, built for the
# image's native architecture and pinned BEAM toolchain rather than assuming x86.
source_commit=2ab9600a53e4ac3fba0b0981e65ce2df73859bc5
git clone --quiet --depth 1 --branch v0.0.2 https://github.com/typicalpixel/elixir_release.git /tmp/still-release-source
cd /tmp/still-release-source
[[ $(git rev-parse HEAD) == "$source_commit" ]] || { printf 'Fixture source tag changed!\n' >&2; exit 1; }
export MIX_ENV=prod
mix deps.get
for variant in A B; do
  mix clean
  FIXTURE_VARIANT=$variant mix release --overwrite
  cp _build/prod/elixir_release-0.0.2.tar.gz "/opt/still-fixtures/elixir_release-v${variant}-v0.0.2.tar.gz"
done
{
  printf 'Fixture source: %s\n' "$source_commit"
  uname -m
  mix --version
} > /opt/still-fixtures/BUILD_INFO
cd /opt/still-fixtures
sha256sum ./*.tar.gz > SHA256SUMS
