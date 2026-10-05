#!/usr/bin/env bats

# Driver-only tests. Docker and Git are stubs; the real suites are validated by
# running scripts/test-linux.sh against Docker, not by these argument assertions.
setup() {
  export TEST_ROOT
  TEST_ROOT=$(mktemp -d)
  export MOCK_LOG="$TEST_ROOT/docker.log"
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/scripts"
  cp "$BATS_TEST_DIRNAME/../../scripts/test-linux.sh" "$TEST_ROOT/scripts/test-linux.sh"
  export PATH="$TEST_ROOT/bin:$PATH"

  cat > "$TEST_ROOT/bin/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *--show-toplevel*) printf '%s\n' "$TEST_ROOT" ;;
  *'rev-parse HEAD'*) printf 'test-revision\n' ;;
esac
STUB

  cat > "$TEST_ROOT/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$1" in
  info)
    case "$*" in *Architecture*) printf 'aarch64\n' ;; *) printf 'linux\n' ;; esac
    ;;
  build)
    while [[ $# -gt 0 ]]; do
      if [[ $1 == --iidfile ]]; then printf 'sha256:own-image\n' > "$2"; break; fi
      shift
    done
    exit "${MOCK_BUILD_EXIT:-0}"
    ;;
  image) printf 'sha256:test linux/arm64\n' ;;
  create) printf 'owned-test-container-id\n' ;;
  start) exit "${MOCK_START_EXIT:-0}" ;;
  rm) exit "${MOCK_REMOVE_EXIT:-0}" ;;
  inspect) printf 'true\n' ;;
  exec)
    case "$*" in
      *"still-test-suite ${MOCK_FAIL_SUITE:-never}"*) exit 17 ;;
      *) printf 'mock command succeeded\n' ;;
    esac
    ;;
esac
STUB
  chmod +x "$TEST_ROOT/bin/git" "$TEST_ROOT/bin/docker"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "help and invalid suites do not invoke Docker" {
  run bash "$TEST_ROOT/scripts/test-linux.sh" --help
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG" ]
  run bash "$TEST_ROOT/scripts/test-linux.sh" unknown
  [ "$status" -eq 2 ]
  [ ! -e "$MOCK_LOG" ]
}

@test "integration runs non-root without privileged mode or host mounts" {
  run bash "$TEST_ROOT/scripts/test-linux.sh" integration test/integration/immutable_release_test.exs
  [ "$status" -eq 0 ]
  grep -q -- '--user tester --cap-drop ALL --security-opt no-new-privileges' "$MOCK_LOG"
  grep -q -- 'still-test-suite integration test/integration/immutable_release_test.exs' "$MOCK_LOG"
  ! grep -Eq -- '--privileged|--mount|--volume|--network host|--pid host|--publish' "$MOCK_LOG"
  grep -q '^rm -f owned-test-container-id$' "$MOCK_LOG"
}

@test "all uses native private-cgroup systemd and runs every suite" {
  run bash "$TEST_ROOT/scripts/test-linux.sh" all
  [ "$status" -eq 0 ]
  grep -q -- '--privileged --cgroupns=private' "$MOCK_LOG"
  grep -q -- '--platform linux/arm64' "$MOCK_LOG"
  for suite in unit integration root; do
    grep -q -- "still-test-suite $suite" "$MOCK_LOG"
  done
  grep -q -- 'exec --user root --env HOME=/root --env USER=root' "$MOCK_LOG"
}

@test "a suite failure survives tee and cleans only this run container" {
  export MOCK_FAIL_SUITE=integration
  run bash "$TEST_ROOT/scripts/test-linux.sh" all
  [ "$status" -eq 17 ]
  grep -q '^rm -f owned-test-container-id$' "$MOCK_LOG"
  ! grep -q 'still-test-suite root' "$MOCK_LOG"
  ! grep -Eq 'prune|volume rm|network rm' "$MOCK_LOG"
}

@test "failed builds never start a container" {
  export MOCK_BUILD_EXIT=42
  run bash "$TEST_ROOT/scripts/test-linux.sh" all
  [ "$status" -eq 42 ]
  ! grep -q '^create ' "$MOCK_LOG"
  ! grep -q '^rm ' "$MOCK_LOG"
}

@test "keep mode retains only the current test container" {
  export STILL_TEST_KEEP=1
  run bash "$TEST_ROOT/scripts/test-linux.sh" integration
  [ "$status" -eq 0 ]
  [[ "$output" == *"Kept container:"* ]]
  ! grep -Eq '^(stop|rm) ' "$MOCK_LOG"
}

@test "root tests reject emulated systemd instead of claiming coverage" {
  export STILL_TEST_PLATFORM=linux/amd64
  run bash "$TEST_ROOT/scripts/test-linux.sh" root
  [ "$status" -eq 2 ]
  [[ "$output" == *"require native systemd"* ]]
  ! grep -q '^create ' "$MOCK_LOG"
}

@test "failed starts clean up the already-created container" {
  export MOCK_START_EXIT=125
  run bash "$TEST_ROOT/scripts/test-linux.sh" integration
  [ "$status" -eq 125 ]
  grep -q '^rm -f owned-test-container-id$' "$MOCK_LOG"
  grep -q 'sha256:own-image infinity$' "$MOCK_LOG"
}

@test "cleanup failure makes an otherwise successful run fail" {
  export MOCK_REMOVE_EXIT=1
  run bash "$TEST_ROOT/scripts/test-linux.sh" integration
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cleanup failed"* ]]
}
