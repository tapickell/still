#!/usr/bin/env bash
set -euo pipefail

suite=${1:?Specify scripts, unit, integration, or root}
shift
cd /workspace

for executable in elixir mix caddy tar systemctl timeout curl; do
  command -v "$executable" >/dev/null || { printf 'Missing prerequisite: %s\n' "$executable" >&2; exit 1; }
done

# Fail instead of silently testing a different toolchain after .mise.toml changes.
elixir -e '
  pins = File.read!(".mise.toml")
  [_, expected_elixir] = Regex.run(~r/elixir = "([^-]+)-otp-\d+"/, pins)
  [_, expected_otp] = Regex.run(~r/erlang = "([^"]+)"/, pins)
  actual_otp = :erlang.system_info(:otp_release) |> to_string()
  actual_otp = File.read!(Path.join([:code.root_dir() |> to_string(), "releases", actual_otp, "OTP_VERSION"])) |> String.trim()
  unless System.version() == expected_elixir and actual_otp == expected_otp,
    do: raise("Test image toolchain differs from .mise.toml; update infra/test/Dockerfile")
  IO.puts("Elixir #{System.version()}, OTP #{actual_otp}")
'
caddy version

case "$suite" in
  scripts)
    shellcheck scripts/test-linux.sh infra/test/*.sh
    exec bats test/scripts/test_linux_test.bats
    ;;
  unit)
    selection=()
    ;;
  integration)
    if [[ $(id -u) == 0 ]]; then
      printf 'Non-root integration suite must run as tester.\n' >&2
      exit 1
    fi
    selection=(--only integration)
    ;;
  root)
    [[ $(id -u) == 0 ]] || { printf 'Root suite requires root inside the container.\n' >&2; exit 1; }
    [[ $(cat /proc/1/comm) == systemd ]] || { printf 'systemd must be PID 1.\n' >&2; exit 1; }
    systemctl show --property=Version --value >/dev/null
    # Prove that PID 1 can start a real unit, not merely answer on its bus.
    systemd-run --quiet --wait --collect --unit=still-test-preflight /bin/true
    (cd "$STILL_RELEASE_FIXTURES_DIR" && sha256sum --check SHA256SUMS && cat BUILD_INFO)
    selection=(--only integration_root)
    ;;
  *) printf 'Unknown suite: %s\n' "$suite" >&2; exit 2 ;;
esac

mkdir -p /workspace/.test-results
export STILL_TEST_REPORT="/workspace/.test-results/${suite}.json"
mix test "${selection[@]}" "$@"
# A missing report, skipped prerequisite, or selector matching nothing must not
# turn an untested environment green. Exclusions from --only are intentional.
elixir -pa _build/test/lib/jason/ebin -e '
  stats = System.fetch_env!("STILL_TEST_REPORT") |> File.read!() |> Jason.decode!()
  executed = stats["total"] - stats["excluded"] - stats["skipped"]
  unless executed > 0 and stats["skipped"] == 0 and stats["failures"] == 0,
    do: raise("Incomplete test run: #{inspect(stats)}")
  IO.puts("Validated #{executed} executed tests, zero failures and zero skips")
'
