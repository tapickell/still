#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: bash scripts/test-linux.sh [build|scripts|unit|integration|root|all] [mix test arguments...]' \
    '' \
    'Default: all (runner checks, unit, non-root integration, then systemd/root integration).' \
    'Each invocation builds the current worktree into an isolated Linux image.' \
    'root/all use a privileged container; use only a trusted disposable Docker daemon.' \
    'No host mounts, Docker socket, host networking, or published ports are used.' \
    '' \
    'STILL_TEST_PLATFORM             Defaults to the Docker daemon native architecture.' \
    'STILL_TEST_IMAGE=still-test:local' \
    'STILL_TEST_KEEP=1               Keep this run container for debugging.' \
    'Logs are saved under tmp/linux-tests/<unique-run>/.'
}

suite=${1:-all}
if [[ $# -gt 0 ]]; then shift; fi
case "$suite" in
  -h|--help|help) usage; exit 0 ;;
  build|scripts|unit|integration|root|all) ;;
  *) usage >&2; exit 2 ;;
esac
if [[ ( $suite == all || $suite == build || $suite == scripts ) && $# -gt 0 ]]; then
  printf 'Pass test selectors to unit, integration, or root.\n' >&2
  exit 2
fi

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
architecture=$(docker info --format '{{.Architecture}}')
case "$architecture" in
  aarch64|arm64) native_platform=linux/arm64 ;;
  x86_64|amd64) native_platform=linux/amd64 ;;
  *) printf 'Unsupported Docker architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac
platform=${STILL_TEST_PLATFORM:-$native_platform}
image=${STILL_TEST_IMAGE:-still-test:local}
if [[ $suite == root || $suite == all ]] && [[ $platform != "$native_platform" ]]; then
  printf 'root/all require native systemd; use %s on this daemon.\n' "$native_platform" >&2
  exit 2
fi
[[ $(docker info --format '{{.OSType}}') == linux ]] || { printf 'A Linux Docker daemon is required.\n' >&2; exit 1; }

mkdir -p tmp/linux-tests
results=$(mktemp -d "$root/tmp/linux-tests/run-XXXXXXXX")
name="still-test-$(basename "$results")"
run_image="still-test-run:$(basename "$results")"
container_id=
printf 'Results: %s\n' "$results"

cleanup() {
  result=$?
  trap - EXIT
  if [[ -n $container_id ]]; then
    docker logs "$container_id" >"$results/container.log" 2>&1 || true
    docker inspect "$container_id" >"$results/container.json" 2>&1 || true
    docker exec "$container_id" journalctl --no-pager >"$results/journal.log" 2>&1 || true
    docker exec "$container_id" systemctl --failed --no-pager >"$results/failed-units.log" 2>&1 || true
    for selected in unit integration root; do
      docker cp "$container_id:/workspace/.test-results/${selected}.json" "$results/${selected}.json" 2>/dev/null || true
    done
    docker cp "$container_id:/opt/still-fixtures/BUILD_INFO" "$results/fixture-build.txt" 2>/dev/null || true
    docker cp "$container_id:/opt/still-fixtures/SHA256SUMS" "$results/fixture-checksums.txt" 2>/dev/null || true
    if [[ ${STILL_TEST_KEEP:-0} == 1 ]]; then
      printf 'Kept container: %s (%s)\n' "$name" "$container_id"
      printf 'Inspect: docker exec -it %s bash\n' "$name"
      printf 'Remove when finished: docker rm -f %s\n' "$name"
    else
      docker stop --time 15 "$container_id" >/dev/null 2>&1 || true
      if ! docker rm -f "$container_id" >/dev/null 2>&1; then
        printf 'Cleanup failed; inspect container %s (%s).\n' "$name" "$container_id" >&2
        [[ $result != 0 ]] || result=1
      fi
    fi
  fi
  if [[ ${STILL_TEST_KEEP:-0} != 1 ]]; then
    # Keep the shared cache tag, but remove only our unique temporary tag.
    docker image rm "$run_image" >/dev/null 2>&1 || true
  fi
  printf 'Exit status: %s; logs: %s\n' "$result" "$results"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker build --platform "$platform" --progress plain --iidfile "$results/image-id" -f infra/test/Dockerfile -t "$image" -t "$run_image" . 2>&1 | tee "$results/build.log"
image_id=$(<"$results/image-id")
docker image inspect "$image_id" --format '{{.Id}} {{.Os}}/{{.Architecture}}' >"$results/image.txt"
git rev-parse HEAD >"$results/revision.txt"
git status --short >>"$results/revision.txt"
[[ $suite != build ]] || exit 0

if [[ $suite == root || $suite == all ]]; then
  printf 'Starting privileged systemd test container (no host mounts): %s\n' "$name"
  container_id=$(docker create --name "$name" --platform "$platform" \
    --label still.test-run=true --privileged --cgroupns=private \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp:exec,mode=1777 "$image_id")
  docker start "$container_id" >/dev/null
  ready=0
  for _ in {1..60}; do
    if docker exec "$container_id" systemctl is-active --quiet dbus.service >/dev/null 2>&1 \
      && docker exec "$container_id" systemctl is-active --quiet systemd-journald.service >/dev/null 2>&1; then
      ready=1
      break
    fi
    [[ $(docker inspect --format '{{.State.Running}}' "$container_id") == true ]] || break
    sleep 1
  done
  [[ $ready == 1 ]] || { printf 'systemd did not start; inspect the saved container logs.\n' >&2; exit 1; }
else
  container_id=$(docker create --name "$name" --platform "$platform" \
    --label still.test-run=true --init --user tester --cap-drop ALL \
    --security-opt no-new-privileges --entrypoint /usr/bin/sleep "$image_id" infinity)
  docker start "$container_id" >/dev/null
fi

run_suite() {
  local selected=$1 user=tester home=/home/tester status=0
  shift
  if [[ $selected == root ]]; then user=root; home=/root; fi
  docker exec --user "$user" --env "HOME=$home" --env "USER=$user" "$container_id" /usr/local/bin/still-test-suite "$selected" "$@" \
    2>&1 | tee "$results/$selected.log" || status=$?
  if [[ $status == 0 && $selected != scripts ]]; then
    docker cp "$container_id:/workspace/.test-results/${selected}.json" "$results/${selected}.json"
  fi
  return "$status"
}

if [[ $suite == all ]]; then
  run_suite scripts
  run_suite unit
  run_suite integration
  run_suite root
else
  run_suite "$suite" "$@"
fi
