# Still Reliability and Scaling Implementation Plan

**Status:** Proposed

**Baseline:** Still `75ee067`; NervesHub reference `3f491b15`

**Related document:** [PROJECT_REVIEW_AND_AUTOSCALING.md](PROJECT_REVIEW_AND_AUTOSCALING.md)

### Phase 2 implementation notes

The durable-operation protocol, synced private agent journals, per-application
workers, controller restart recovery, conservative agent recovery, Caddy write
serialization, explicit hook scopes, and public operation progress are implemented.
See [DURABLE_OPERATIONS.md](DURABLE_OPERATIONS.md) for guarantees, recovery commands,
upgrade requirements, and the new safeguards around retained history.

The full native Linux coverage gate includes unit, distributed/Caddy, and real
systemd recovery tests. Use `bash scripts/test-linux.sh coverage`; the 100% minimum
is unchanged, and no coverage exclusions were added for the new operation engine.
Unit-only coverage remains a diagnostic subset, not the full-path acceptance gate.

Validated on 2026-10-05: 1,713 tests passed in the full native Linux coverage run,
with zero failures/skips and 100% coverage in the configured scope. The nine
runner tests, strict Credo, warnings-as-errors compilation, and formatting checks
also passed. Validation includes cold peer restart, lost acceptance replies,
controller restart, interrupted hooks, real process-start/switch recovery, and
concurrent Caddy configuration updates.

Automatic cancellation, coordinated decommission, independently versioned live
routing policy, controller HA, and automatic fleet convergence are not implemented
by Phase 2. Unknown work remains locked rather than claiming those guarantees.

### Phase 1 implementation notes

Phase 1 code now includes release/revision schemas, content-addressed verified
staging, immutable agent directories, exact rollback references, private process
snapshots, and conservative artifact retention. It also includes the path-safety
and maintenance-payload fixes needed by those paths. See the README's immutable
release section for compatibility and upgrade requirements.

This is not completion of the later coordination phases: timeouts, interrupted
switch recovery, concurrent routing mutations, and fleet-wide convergence still
require Phases 2–3. Real Linux/Caddy/systemd qualification remains a release gate;
passing unit tests alone does not establish that gate.

### Local Linux validation environment

The repeatable lab is available via `bash scripts/test-linux.sh all`; see
[infra/test/README.md](infra/test/README.md). It builds the current worktree in
isolation and exercises real Caddy, systemd, release binaries, and distributed
agent peers. Result summaries and diagnostic logs are retained under
`tmp/linux-tests/`.

On 2026-10-04, native Linux ARM64 validation passed 1,622 unit tests, 29 non-root
integration tests, and 20 root/systemd tests, with zero failures or skips in each
selected suite. Nine runner tests and ShellCheck also passed. Native release
fixtures were built from verified upstream source using the pinned image
toolchain; this is not qualification of the upstream prebuilt AMD64 artifacts.

The lab is not a substitute for future separate-host failure and capacity tests.
Its independent agent BEAMs currently share one container's kernel/network
namespace; autoscaling and network-partition guarantees remain unimplemented.

## 1. Objective

Strengthen Still's deployment coordination and recovery using the most applicable
NervesHub patterns, while retaining Still's Caddy/systemd execution model.

Deliver improvements in this order:

1. Safe, immutable release identity.
2. Durable, asynchronous deployment operations.
3. Reconciliation and controlled rollouts.
4. Safe manual replica scaling.
5. Opt-in autoscaling.
6. Tests and release gates that verify those guarantees.

Testing is part of every phase, not a final cleanup task.

### Initial constraints

- Retain SQLite and a single active controller.
- Retain Erlang distribution for agent communication initially.
- Support one serving replica per application per host.
- Preserve blue/green deployment slots.
- Introduce changes incrementally, with explicit agent capability checks.
- Defer cloud provisioning, multi-controller HA, and transport replacement.

NervesHub provides architectural guidance, not a drop-in implementation.

## 2. Required invariants

These are the acceptance rules for the new design.

| Invariant | Required behavior |
| --- | --- |
| Artifact immutability | Deploying new work never overwrites an active release directory. |
| Exact identity | Deployment and rollback reference specific artifacts, not ambiguous version labels. |
| Durable intent | Controller restart does not erase what an operation was trying to accomplish. |
| Observable completion | A timeout or lost connection is not treated as proof that remote work stopped. |
| Repeatable commands | Retrying an accepted command does not duplicate unsafe side effects. |
| Ordered intent | Stale commands and observations cannot supersede newer desired state. |
| Readiness-gated routing | A new replica receives traffic only after readiness checks pass. |
| Confirmed removal | Capacity is not released until workload shutdown is confirmed. |
| Availability protection | Planned removals respect a ready-replica floor using fresh observations. |
| Maintenance preservation | Deploy, restart, rollback, and scaling preserve the latest maintenance policy. |
| Honest uncertainty | Disconnected or incompletely observed workloads remain explicitly unknown. |

The ready-replica floor constrains Still's actions. It cannot guarantee availability
through simultaneous external failures or network partitions.

## 3. Proposed domain model

The following are proposed concepts and fields, not existing APIs.

### Release

An immutable deployable artifact.

Suggested fields:

- Internal ID.
- Application ID.
- Human-readable version.
- Content digest and size.
- Storage reference.
- Artifact format and compatibility metadata.
- Verification status.
- Creation timestamp.

**Rules:**

- Runtime paths use internal identifiers.
- An existing release cannot acquire different bytes.
- Fetch URLs are provenance or transport information, not artifact identity.
- A computed digest detects changes; it does not establish publisher authenticity.
  Trusted expected digests or signatures are a separate verification policy.

### Application revision

A release plus an immutable snapshot of process configuration:

- Release ID.
- Start/stop commands.
- Health-check configuration.
- Environment configuration.
- Hook definitions and execution scope.

Environment snapshots must receive the same access protection as current
application secrets and must be redacted from API responses, logs, and audit diffs.

Keep live routing policy—particularly maintenance—separately versioned. Rolling
back code must not inadvertently roll back a current maintenance decision.

### Replica

One serving application instance assigned to a host.

Extend `application_servers` initially rather than introducing a competing
assignment table.

Add:

- Desired revision.
- Observed revision.
- Lifecycle phase.
- Active slot.
- Readiness and observation timestamp.
- Current operation ID.
- Desired generation.
- Removal intent and resource reservation.

Blue and green remain slots belonging to the replica, not separate steady-state
replicas.

### Operation

A durable attempt to change one replica.

Suggested fields:

- Operation ID and kind.
- Replica and rollout references.
- Target revision and generation.
- Status and current phase.
- Attempt number.
- Structured failure information.
- Acceptance, progress, and completion timestamps.
- Last accepted observation sequence.

Separate status from phase:

```text
Status: pending, accepted, running, succeeded, failed, cancelled, unknown

Phase: fetch, verify, unpack, start, check_readiness,
       switch_route, drain, stop_old, finalize
```

Cancellation becomes terminal only after the agent confirms it or observation
establishes the resulting state.

### Rollout

An application-wide transition involving multiple replica operations.

Use the existing deployment record as the rollout foundation, preserving history
and API identity where practical.

Add:

- Target revision.
- Selection/cohort snapshot.
- Concurrency limit.
- Ready-replica floor.
- Retry policy.
- Pause reason.
- Explicit partial-completion state.

**Initial failure policy:** pause the rollout after a terminal replica failure and
preserve healthy serving instances. Recovery is an explicit resume, retry, or
rollback action.

Do not promise atomic fleet-wide rollback.

## 4. Phase 0 — Baseline and immediate safety fixes

### Work

1. Establish a reproducible Linux validation environment using `.mise.toml`.
2. Capture baseline test, lint, formatting, and coverage results.
3. Add failing regressions for:
   - Unsafe version/path inputs.
   - Redeploying an active version.
   - Maintenance lost during deployment operations.
4. Fix these issues before enabling the new scheduler.
5. Record current API and state-file behavior for migration tests.

Resolve the console permission/documentation discrepancy alongside this work, but
keep it separate from the coordination redesign.

### Primary files

- `lib/still/deployments/deployment.ex`
- `lib/still/artifact_store.ex`
- `lib/still/protocol/deploy_request.ex`
- `lib/still/orchestrator.ex`
- `lib/still/agent/deployment_manager.ex`

### Exit gate

The known destructive-path, active-release overwrite, and maintenance regressions
are covered and fixed.

## 5. Phase 1 — Immutable artifacts and revisions

### Work

1. Add release and application-revision schemas.
2. Stage downloads into temporary locations.
3. Verify size, digest, and archive safety before publication.
4. Publish a complete artifact atomically under an internal identifier.
5. Extract into a new immutable release directory.
6. Reject archive traversal and escaping link behavior.
7. Keep active, previous, and in-flight releases protected from garbage collection.
8. Resolve deployment and rollback targets to exact release/revision IDs.

### Compatibility behavior

Continue accepting the existing version/artifact URL deployment request initially.
Internally, resolve it to a release record.

Define version reuse:

- Same version and verified same content: resolve to the existing release.
- Same version and different content: reject clearly.
- Insufficient evidence: do not silently reuse a cached file.

Existing version-based runtime directories remain intact until safely migrated.
Database migration must not delete or repoint active slots.

### Exit gate

A same-version retry, conflicting artifact, interrupted download, or malformed
archive cannot alter the active release.

## 6. Phase 2 — Durable asynchronous agent operations

### Work

Replace the long-running deployment RPC contract with:

```text
Submit operation → receive acceptance
Observe progress → receive phase reports
Query operation → recover after missed messages
```

Use the existing transport initially.

Persist controller intent before dispatch. Add an agent-side operation journal
that survives process and machine restart.

The journal must retain:

- Operation ID and generation.
- Target revision.
- Completed phases.
- Current/previous slot identity.
- Last known outcome.

### Retry and recovery rules

- Repeated submission of the same operation returns its existing state/result.
- Reusing an operation ID with different parameters is rejected.
- Stale generations are rejected.
- Agent reports carry enough ordering information to ignore stale updates.
- Transport timeout changes the controller's observation state to unknown; it
  does not fabricate failure or cancellation.
- Reconnect reports active operations and observed workload state.
- Recovery inspects systemd, Caddy, release files, and the journal before choosing
  the next action.

### Concurrency

Allow independent application operations to run under supervised workers, but
serialize mutations for the same application/host.

Shared host resources require separate coordination:

- Caddy configuration writes.
- Port allocation.
- Capacity reservations.
- Shared systemd operations where necessary.

**Important:** `CaddyManager` currently exposes stateless read/full-config-write
operations. Parallel deployment workers must not perform competing
read-modify-write cycles that lose another application's route changes. Introduce
one coordinated writer per managed Caddy instance.

### Hooks

Distinguish:

- Once-per-rollout hooks.
- Per-replica startup hooks.

Do not silently change existing hook semantics. Require explicit migration of hook
scope before enabling scaling.

A crash after a hook's external side effect but before recording completion is
ambiguous. Do not claim exactly-once execution. Require idempotent hooks or pause
for operator resolution.

### Exit gate

Controller/agent restart, duplicate commands, lost replies, and late completion
cannot cause conflicting operations or misleading terminal state.

## 7. Phase 3 — Reconciliation and controlled rollouts

### Work

Evolve `ReconciliationLoop` from drift reporting into reconciliation of durable
intent.

Trigger reconciliation on:

- Agent connection/reconnection.
- Progress and completion reports.
- Readiness transitions.
- Configuration changes.
- Periodic fallback ticks.

Use bounded retries with backoff and jitter. Persist blocked state and explain why
progress stopped.

### Rollout controls

Implement:

- Explicit server/cohort selection.
- Concurrency limits.
- Ready-replica floor.
- Retry budget per replica/revision.
- Pause/resume.
- Exact-target rollback.
- Per-replica progress and aggregate partial status.

Initially serialize deployment, restart, rollback, and scaling intent changes for
an application. Maintenance changes remain independently applicable and must
supersede stale routing writes.

### Routing

Generate ingress membership from observed lifecycle/readiness, not assignment alone.

Differentiate:

- Assigned.
- Starting.
- Ready.
- Serving.
- Draining.
- Disconnected/unknown.

Coordinate agent slot switching and controller ingress updates with operation
progress. If a route update is uncertain, re-observe before finalizing.

### Exit gate

A mixed-version fleet remains accurately represented and can converge through a
documented recovery action. A failed host does not cause repeated uncontrolled retries.

## 8. Phase 4 — Safe manual replica scaling

### Scope

- Opt-in horizontally scalable HTTP applications.
- Existing eligible agents.
- One replica per application per host.
- No scale-to-zero initially.
- No automatic machine provisioning or deletion.

### Placement

Introduce application resource reservations and host eligibility rules.

Use reservations for admission; host utilization is supplementary evidence. Account
for blue/green overlap, concurrently starting replicas, disk requirements, and port
availability.

Reserve resources transactionally before dispatch.

Port ownership must be unique across both blue and green roles. The current
separate blue/green indexes are not a sufficient model for general cross-slot
reservation.

### Scale up

1. Select an eligible host.
2. Reserve capacity and ports.
3. Create a pending replica pinned to a revision.
4. Run the durable start operation.
5. Require sustained readiness.
6. Add it to managed ingress.
7. Confirm routing and complete the operation.

Adding one replica must not redeploy existing replicas or rerun release-wide migrations.

### Scale down

1. Select a removable replica.
2. Check fresh readiness of remaining replicas.
3. Remove it from new-request routing.
4. Confirm the routing change.
5. Drain existing traffic under an explicit deadline.
6. Stop the workload and confirm shutdown.
7. Release reservations and finalize removal.

Unknown/disconnected hosts retain unresolved work and reservations until reconciled.

Define long-lived connection handling explicitly. Scaling guarantees apply to
traffic through Still's managed ingress; direct access to agents must not bypass
the intended drain boundary.

Application deletion and server unassignment must use this teardown lifecycle
rather than deleting records first.

### Exit gate

Manual scale-up/down is safe under failed starts, failed routing updates, lost
connectivity, and controller restart.

## 9. Phase 5 — Autoscaling policy

Only start this phase after manual scaling passes its acceptance gate.

### Work

Add a policy that changes desired replica count. It must use the same placement
and operation machinery as manual scaling.

Initial policy configuration:

- Enabled/paused.
- Minimum/maximum replicas.
- One application-level signal and target.
- Observation window.
- Scale-up/down stabilization.
- Cooldown.
- Maximum change per evaluation.

### Rules

- Run in shadow mode first.
- Use a load-tested signal such as requests per ready replica, concurrency, or
  verified per-service CPU.
- Do not use whole-host CPU to identify demand for one application on a shared host.
- Treat missing/stale measurements as insufficient evidence, not zero demand.
- Account for pending replicas.
- Hold on conflicting application operations.
- Persist decision reasons and resulting intent.
- Provide a visible manual override.
- Explain "insufficient capacity" rather than repeatedly retrying placement.

### Exit gate

Controlled load tests demonstrate useful scaling without repeated oscillation,
duplicate launches, or unsafe scale-down.

## 10. Testing strategy

### Layer A — Pure transition and policy tests

Test:

- Valid/invalid lifecycle transitions.
- Generation and sequence ordering.
- Retry-budget and backoff calculations.
- Cohort selection.
- Placement and reservation decisions.
- Ready-replica-floor calculations.
- Autoscaling decisions using timestamped metric samples.

Use controlled clocks and deterministic inputs. Avoid sleeps and tests that merely
restate implementation branches.

### Layer B — Persistence and coordination tests

Exercise the actual database and supervised processes:

- Intent committed before dispatch.
- Repeated operation submission.
- Restart reconstruction.
- Conflicting intent.
- Stale reports.
- Concurrent reservation attempts.
- Cross-blue/green port collisions.
- Partial rollout failure.
- Expiration without falsely declaring remote work stopped.
- Ambiguous hook outcome.
- Concurrent routing requests without lost updates.

NH's concurrency and completion-triggered scheduling tests are useful references,
but Still's availability constraints require stronger assertions.

### Layer C — Real Linux integration tests

Extend existing Caddy, systemd, and distributed-peer fixtures.

| Scenario | Required assertion |
| --- | --- |
| Redeploy same version | Active release files remain intact |
| Maintenance plus deploy/restart/rollback | Public response remains the intended maintenance response |
| Failed standby readiness | Existing serving instance remains available |
| Lost completion reply | Reconciliation discovers actual outcome |
| Controller restart during deployment | Persisted intent resumes safely |
| Agent restart after route switch | Route and state converge without stopping the wrong slot |
| Partial fleet failure | Per-host versions and rollout status remain accurate |
| Failed ingress update | Replica is not falsely marked serving/removed |
| Scale-down under load | No new requests reach the drained replica after confirmed removal |
| Long-lived connection | Configured drain/termination behavior is observable |
| Concurrent application updates | Neither application's route disappears |
| Partition and reconnect | Stale workload intent cannot restore obsolete routing |

Use disposable Linux environments for root integration tests.

### Layer D — Migration and compatibility tests

Cover:

- Legacy `state.json` decoding.
- Legacy assignments and deployment history.
- Unknown or unavailable legacy artifact content.
- Old-agent capability rejection.
- Mixed-version fleet upgrade sequencing.
- Interrupted backfill.
- Existing secrets excluded from public/audit representations.
- Recovery from backups.

Never invent a verified digest or a completed operation during migration.

### Layer E — Load and fault-injection qualification

Before autoscaling:

- Sustained traffic and bursts.
- Slow startup.
- Failed artifacts.
- Stale metrics.
- Repeated process crashes.
- Capacity exhaustion.
- Controller restart during scale-up/down.
- Agent disconnection during routing changes.

Measure request failures, operation completion time, availability-floor decisions,
and scaling oscillation.

## 11. CI and release gates

### Required checks

Use the pinned toolchain and retain existing checks:

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix test
mix test --only integration
```

Run the root integration suite in its dedicated disposable Linux job. The full
coverage gate is `bash scripts/test-linux.sh coverage`, including both integration
categories in a privileged disposable Linux container with systemd.

Add:

- `test/scripts/tracing_test.bats` to CI.
- Built-release smoke tests before publication.
- Migration/compatibility tests.
- Explicit prerequisite checks so required integration suites cannot silently skip.
- Typespecs for new protocol/state models.

Evaluate Dialyzer incrementally; establish a reviewed baseline rather than
introducing a large unrelated cleanup requirement.

### Coverage policy

Keep coverage exclusions explicit and reviewed. Critical host-operation paths
excluded from unit coverage must have identified integration coverage.

A percentage is not the acceptance gate. The invariants and failure scenarios are.

## 12. Migration and rollout plan

1. Introduce additive schemas and readers.
2. Deploy controller support for both legacy and new protocol capability reporting.
3. Upgrade agents with new-format support without automatically enabling new operations.
4. Import legacy state without modifying active directories.
5. Verify release identity where actual bytes are available; mark unresolved identity explicitly.
6. Enable the new engine for a noncritical application.
7. Exercise deploy, restart, rollback, reconnect, and controller restart.
8. Expand to manual scaling.
9. Enable shadow-mode autoscaling.
10. Enable bounded automatic scaling after qualification.

Feature flags cannot make an old binary understand a new state format. Document
the downgrade boundary and require coordinated database/state restoration where
necessary.

Do not automatically revert to the legacy executor after a new-format operation
has begun.

## 13. Suggested pull-request sequence

1. Baseline checks and immediate safety regressions/fixes.
2. Immutable artifact staging and release identity.
3. Revision schema and legacy-state import.
4. Operation protocol, persistence, and capability negotiation.
5. Agent journal, supervised execution, and coordinated Caddy writes.
6. Reconciliation, retry budgets, and rollout controls.
7. Readiness-gated routing and confirmed teardown.
8. Manual placement/scaling and reservations.
9. Autoscaling metrics contract and shadow mode.
10. Opt-in automatic scaling and qualification report.

Every PR includes relevant tests and updated operational documentation. CI/release
improvements should land early rather than waiting for PR 10.

## 14. Decisions to approve before coding

Recommended starting defaults:

| Decision | Recommendation |
| --- | --- |
| Controller architecture | Single active controller; SQLite retained |
| Agent transport | Existing Erlang distribution |
| Partial rollout failure | Pause and preserve healthy instances |
| Rollback target | Explicit prior revision; preserve current maintenance policy |
| Initial scaling scope | Existing hosts, HTTP applications, one replica/app/host |
| Scaling minimum | At least one replica |
| Hook ambiguity | Pause unless retry safety is established |
| New dependencies | None required by the initial design; evaluate individually |
| Autoscaling metric | Select from workload measurements before policy implementation |

### Definition of done

The work is complete when Still can deploy, recover, and scale through the tested
failure scenarios **without losing operation intent, confusing desired and actual
state, or performing an unsafe planned traffic transition**.

**Confidence:** high in the source-grounded change areas; medium in the proposed
architecture until the decisions above and failure-injection results validate it.
No implementation or test execution was performed while drafting this plan.
