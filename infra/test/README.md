# Local Linux validation

Run Still's real deployment tests from macOS or Linux without installing Caddy,
Elixir, or systemd on the host. A Linux Docker daemon and Git are required.

```sh
# Build and run runner checks, unit, non-root integration, then root integration.
bash scripts/test-linux.sh all

# Individual suites or a focused regression.
bash scripts/test-linux.sh scripts
bash scripts/test-linux.sh unit
bash scripts/test-linux.sh integration
bash scripts/test-linux.sh root
bash scripts/test-linux.sh integration test/integration/immutable_release_test.exs
bash scripts/test-linux.sh root test/integration/elixir_release_restart_test.exs

# Build only; useful for warming the dependency/fixture layers.
bash scripts/test-linux.sh build
```

Each invocation builds a snapshot of the **current worktree**, including uncommitted
code, then runs a new container. A unique temporary image tag protects each run
from concurrent builds replacing the shared tag. Docker caches the toolchain, dependencies, and
fixture build layers. No test database, native dependency, or generated state is
shared with the host. The `.dockerignore` is an allowlist; Git metadata, environment
files, local databases, host `_build`/`deps`, and fixture caches are not sent.

## What is exercised

- Unit tests run as an unprivileged `tester` user.
- Runner scripts are linted with ShellCheck and tested with Bats/Docker stubs.
- Non-root integration tests run actual Caddy servers and real downloads,
  extraction, symlink changes, routing, and distributed BEAM peers.
- Root integration tests run actual systemd units, application releases, health
  checks, restart/rollback, journal collection, and remote consoles.
- Existing multi-agent tests create independent BEAM peers with separate Caddy
  instances and application directories inside the test container.

This is an automated regression lab, **not** an always-on controller dashboard
and not a multi-machine network simulation. The peers share the container's kernel
and network namespace. Future scale-up/down tests can reuse the deployment harness;
network partitions, independent host reboots, resource isolation, and placement
across hosts will need separate agent containers or VMs. No autoscaler is implemented
by this environment.

## Safety boundary

**`root` and `all` start a privileged container to run systemd.** Use only trusted
repository code, fixture sources, and a disposable development Docker daemon.
Privileged containers are not a security sandbox against hostile code. On Docker
Desktop the daemon runs in its Linux VM; on a Linux host the privilege risk applies
directly to that host. Do not point this runner at a production or shared daemon.

The runner does not mount the source tree, home directory, host cgroups, or Docker
socket. It does not use host networking/PID namespaces or publish ports. Containers
have unique names and a `still.test-run=true` label. Cleanup uses only the ID returned
by this invocation, plus its own temporary image tag; it never prunes Docker or
touches unrelated containers/volumes. The shared image/cache is retained.

Individual `unit` and `integration` runs do not use privileged mode. They drop Linux
capabilities and enable `no-new-privileges`. In `all`, those suites still run as
`tester`, but share the privileged systemd container used for the root suite.

## Architecture and version pins

- Ubuntu Noble base image pinned by tag **and digest**.
- Elixir 1.20.4 / OTP 29.0.6, matching `.mise.toml`; the runner rejects pin drift.
- Caddy 2.11.2, matching CI, verified against the published SHA-512 checksum.
- Fixture source: `typicalpixel/elixir_release` tag `v0.0.2`, verified commit
  `2ab9600a53e4ac3fba0b0981e65ce2df73859bc5`.

By default, the image uses the Docker daemon's native architecture (ARM64 on Apple
Silicon, AMD64 on x86 Linux). Both fixture variants are built from that pinned source
with the image's toolchain. `STILL_RELEASE_FIXTURES_DIR` points the test harness to
these native artifacts; without it, the existing GitHub-download path is unchanged.
Native artifacts are checksum-checked before root tests. Their build identity and
checksums are saved with the run logs. This qualifies the pinned fixture **source**
and current toolchain, not the upstream prebuilt OTP-28 binary artifacts.

The root suite requires native systemd. AMD64 emulation on Apple Silicon was observed
to boot systemd but fail to execute its services. `STILL_TEST_PLATFORM` can select a
different architecture for unit/non-root integration runs only. The test BEAM uses limited
scheduler counts and `+JMsingle true` for emulated JIT compatibility.

System packages and Hex/Rebar bootstrap tools are obtained during image builds;
this is a repeatable test recipe, not a claim of bit-for-bit reproducible images.
Project and fixture dependencies use their checked-in lockfiles. Building requires
network access to the registries, Ubuntu package mirrors, Hex, and GitHub. Static
fixtures are downloaded during integration tests.

## Results and debugging

Every invocation prints its unique result directory under `tmp/linux-tests/`
(already gitignored). It contains:

- `build.log` and per-suite logs.
- Per-suite JSON summaries, when the suite completed.
- Image ID/platform and source revision/working-tree status.
- Fixture source/toolchain identity and checksums.
- Container configuration, boot log, journal, and failed-unit listing.

The script preserves failures through pipelines and exits nonzero for failed
tests, skipped tests, empty test selections, or missing reports. Integration
prerequisites are strict inside the image. Root preflight checks PID 1, the systemd
bus, and the ability to run a real transient unit. A `systemctl` executable alone
does not count as a working systemd environment.

Containers are stopped and removed on completion or failure. To retain one:

```sh
STILL_TEST_KEEP=1 bash scripts/test-linux.sh root
# The runner prints the unique container name and inspect/removal commands.
```

`STILL_TEST_IMAGE` overrides the local image tag (default `still-test:local`).
Result directories and Docker build-cache/image layers persist intentionally.
SIGKILL, daemon failure, or a host crash can prevent cleanup; use the printed ID or
the `still.test-run=true` label to identify an abandoned lab container, and remove
only that container after inspecting it.

## Extending the lab

Add application scenarios to `test/integration/` using `Still.IntegrationCase`.
Use `root: true` when the test creates systemd services. Reuse
`start_isolated_agent_peer!/1` for distributed orchestration tests; use unique
application/unit names and register cleanup before exercising failure cases.

Keep new lifecycle tests independent of timing guesses: assert HTTP responses,
reported release IDs, process state, and completion messages. Future manual-scaling
tests should prove readiness before ingress admission, drain before shutdown, and
reservation release only after confirmed removal. The lab must not claim those
guarantees until the corresponding features and tests exist.
