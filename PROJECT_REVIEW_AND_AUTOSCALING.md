# Project Review and Autoscaling Roadmap

Review date: 2026-10-04  
Reviewed revision: `75ee067` (`main`)  
Scope: repository onboarding, selected implementation paths, test/CI configuration,
and a proposed autoscaling design.

## Status and confidence

This document records a source-based engineering review, not a completed runtime
audit. No application fixes or autoscaling features were implemented during the
review. Recheck the referenced behavior against the current revision before
starting work; line numbers below refer to the reviewed revision.

- **High confidence:** directly observed code, documentation, and CI discrepancies.
- **Medium confidence:** proposed architecture and failure scenarios inferred from
  traced code but not exercised end-to-end.
- **Unknown:** full-suite pass status, measured coverage, production reliability,
  and the proportion of human versus AI authorship.

## 1. Project overview

Still is an API-first deployment platform for Linux servers, using Caddy for
routing and systemd for application processes rather than containers.

Supported application types:

| Type | Deployment input | Runtime |
| --- | --- | --- |
| `static_site` | Tarball of website files | Caddy file serving with SPA fallback |
| `elixir_release` | Packaged Elixir release | systemd-managed release process |
| `process` | Packaged application and start command | systemd-managed process |

Operating modes:

- **Standalone:** controller, SQLite database, dashboard/API, and workloads on one host.
- **Controller:** database, dashboard/API, and fleet deployment coordination.
- **Agent:** workload execution on a remote host.

The controller communicates with agents over Erlang distribution. Artifacts are
staged on the controller and fetched by agents over internal HTTP. Each workload
host uses blue/green slots; fleet deployment proceeds one server at a time.

Existing features include a LiveView dashboard, JSON API, API keys, role-based
permissions, deployment hooks, restart/rollback, maintenance pages, audit events,
deployment logs, metrics, Caddy inspection, optional tracing, and remote IEx consoles.

Typical use: install on Linux, bootstrap an administrator, register an application,
assign a server, and submit a version and artifact URL. Build artifacts outside
Still. Start evaluation with a disposable Linux VM and a static site.

Important boundaries:

- The README labels the project beta and says the advertised installer URL is not
  live; use the checkout-based instructions until that changes.
- The normal deployment path runs application code and consoles as root. This is
  a trusted-operator platform, not tenant-isolated hosting.
- Running applications surviving a controller restart is not equivalent to a
  highly available deployment control plane.

Sources: `README.md:3–31`, `README.md:344–365`, `lib/still/application.ex:36–129`,
`lib/still/agent/deployment_manager.ex:259–290`.

## 2. Findings and remediation backlog

Priorities below are recommendations, not formal vulnerability scores. Source
evidence establishes the code paths; full runtime reproductions remain follow-up work.

### F1 — High: deployment versions are unsafe filesystem inputs

**Evidence:** the deployment changeset validates version presence and length but
not path safety. The version becomes part of artifact and release paths. Unpacking
recursively removes the release directory before extraction.

**Impact:** a version containing traversal components can escape the intended
release directory and target unrelated files. Deployment permission is required;
this is not an unauthenticated exploit finding.

**Recommended fix:** accept only safe single-component identifiers, independently
enforce filesystem containment, and preferably store releases under internal,
immutable identifiers rather than user-supplied version strings.

**Acceptance:** unsafe versions are rejected before filesystem/network activity;
traversal and containment regression tests pass; unrelated directories remain intact.

Sources: `lib/still/deployments/deployment.ex:69–77`,
`lib/still/artifact_store.ex:66–68`,
`lib/still/agent/deployment_manager.ex:391–393,581–589`.

### F2 — High: deployment requests omit maintenance state

**Evidence:** `DeployRequest` and the orchestrator's request builder omit
`maintenance` and `maintenance_message`. The agent route builder treats missing
maintenance state as false.

**Impact:** deploy/restart/rollback can replace an agent's maintenance route with a
normal serving route. Standalone has no separate controller ingress layer to retain
the maintenance response.

**Recommended fix:** carry the application routing configuration consistently
through all operations, with an explicit policy for concurrent configuration changes.

**Acceptance:** enable maintenance, perform each supported operation, and verify
that HTTP remains 503 with the intended message in standalone and fleet scenarios.

Sources: `lib/still/protocol/deploy_request.ex:17–35`,
`lib/still/orchestrator.ex:545–561`,
`lib/still/agent/deployment_manager.ex:669–674`.

### F3 — High: same-version deployment can modify live release files

**Evidence:** release directories are keyed by version and removed before unpacking.
The inspected creation path does not reject an already-running version. Controller
artifact staging reuses an existing version's file without comparing a new URL.

**Impact:** redeploying the active version can replace files used by the live slot,
breaking blue/green isolation. A changed artifact URL can also silently reuse old bytes.

**Recommended fix:** define version/artifact immutability and use separate immutable
release directories. Reject conflicting version reuse or make exact retries safe.

**Acceptance:** redeploying an active version never removes its files; conflicting
artifact reuse fails clearly; exact retry behavior is deterministic.

Sources: `lib/still/agent/deployment_manager.ex:391,581–589`,
`lib/still/artifact_store.ex:28–48`.

### F4 — High: partial fleet failure is not fleet-wide rollback

**Evidence:** the rolling coordinator halts on failure without reverting successful
servers. Controller rollback targets come from completed deployment history; agents
replace the requested version with their own local previous version.

**Impact:** a failed operation can leave a mixed-version fleet. Subsequent rollback
can differ from the controller's recorded target. Do not interpret “automatic
rollbacks” as an atomic fleet-wide guarantee.

**Recommended fix:** define partial-deployment recovery, authoritative per-replica
version state, and explicit rollback targets. Document whether recovery converges
forward, rolls back, or requires an operator decision.

**Acceptance:** upgrade server A, fail server B, then exercise recovery. Actual
versions, desired versions, operation history, and routing must agree.

Sources: `lib/still/orchestrator.ex:383–414,509–525`,
`lib/still/deployments.ex:460–474`,
`lib/still/agent/deployment_manager.ex:419–427`.

### F5 — High: controller timeout and agent completion can diverge

**Evidence:** controller deploy/rollback/restart calls have fixed 120-second
timeouts. The agent executes operations synchronously in a single GenServer.

**Impact:** a controller can record failure while the agent continues changing the
host. Operations for different applications queue on the same agent and consume
caller timeout budgets while waiting.

**Recommended fix:** durable operation IDs, asynchronous progress/completion,
queryable status, repeatable commands, and explicit timeout/recovery semantics.
Simply increasing the timeout does not establish cancellation or completion.

**Acceptance:** slow and queued operations, lost replies, duplicate commands, and
controller restarts cannot produce contradictory terminal state or overlapping
unsafe operations.

Sources: `lib/still/orchestrator.ex:595–616`,
`lib/still/agent/deployment_manager.ex:134–195`.

### F6 — Security/documentation mismatch: console permits deployers

**Evidence:** the README describes an admin-only console. The route requires deploy
permission, and a test explicitly allows deployer users through the gate.

**Impact:** the documented access boundary is inaccurate. Deploy privileges are
already highly powerful, but administrators must know who can open an interactive console.

**Recommended fix:** decide the intended permission and align enforcement, UI,
documentation, and tests.

**Acceptance:** test admin, deployer, viewer, and unauthenticated behavior against
the agreed policy.

Sources: `README.md:355–360`, `lib/still_web/router.ex:148–154`,
`lib/still_web/user_auth.ex:190–200`,
`test/still_web/live/console_live_test.exs:21–37`.

### F7 — Functional limitation: reconciliation only reports drift

The reconciliation loop compares desired and observed versions and logs mismatches;
it does not automatically restore desired state. Interrupted deployments are marked
failed on controller restart rather than resumed.

Sources: `lib/still/reconciliation_loop.ex:1–8,108–114`,
`lib/still/orchestrator.ex:145–155`.

### F8 — Functional limitation: runtime controls are not wired end-to-end

The protocol and agent contain support for service user, drain delay, and stop
timeout, but the application schema and orchestrator do not expose/populate these
settings. The drain step defaults to no delay.

Sources: `lib/still/protocol/deploy_request.ex:29–31`,
`lib/still/applications/application.ex:21–36`,
`lib/still/orchestrator.ex:545–561`,
`lib/still/agent/deployment_manager.ex:906–908,964–985`.

### F9 — Functional limitation: narrow artifact-source support

The provider registry contains unauthenticated URL and local-file providers. There
is an extension point but no native authenticated object-storage provider in that registry.

Source: `lib/still/artifact/provider.ex:37–40`.

### F10 — CI gap: existing shell suites are not all invoked

`tracing_test.bats` and `release_smoke_test.bats` exist, but the checked-in CI
workflow invokes only `install_test.bats`. The release workflow publishes its
tarball without invoking the release smoke suite.

**Acceptance:** run tracing tests in CI and smoke-test the built release before
publication. Ensure missing prerequisites cannot silently skip required release checks.

Sources: `.github/workflows/continuous-integration.yml:145–158`,
`.github/workflows/release.yml:29–49`, `test/scripts/`.

## 3. Code quality and testing assessment

### Strengths

- Clear context/controller/agent/protocol separation.
- Transactional audit records for application mutations.
- Injectable callers and step providers for deterministic failure testing.
- Explicit handling of corrupt state, failed standby slots, and orphaned deployments.
- Custom Credo checks for controller/database separation, error rendering,
  documentation, and avoiding sleeps in tests.
- Real integration tests for multi-node routing, releases, rollback/restart,
  health failures, console lifecycle, Caddy persistence, and tracing.

### Maintainability concerns

- `deployment_manager.ex` exceeds 1,000 lines and combines lifecycle coordination,
  filesystem actions, Caddy, systemd, environment serialization, hooks, and health checks.
- Cross-layer contracts need stronger guarantees than individual module tests provide.
- Documentation includes stale behavior/arity references.
- Formal typespecs appear sparse in the inspected public interfaces.
- Two comments cite `feedback_integration_over_fakes.md`, which was not found in the checkout.

### Coverage interpretation

CI requires `mix six --minimum-coverage 100`, but `.sixignore` and inline exclusions
remove substantial host-operation code from the measured scope. Integration suites
run separately and are excluded by default in `test/test_helper.exs`.

This arrangement can be reasonable, but 100% of the measured scope is not proof
that every production path or cross-layer invariant is covered. A test can also
encode an unintended policy, as the console permission discrepancy demonstrates.

### Validation actually performed

| Check | Result |
| --- | --- |
| `mix test` | Blocked by missing dependencies; no passing test count established |
| `sh -n scripts/install.sh` | Passed syntax check only |
| `sh -n rel/overlays/bin/tracing` | Passed syntax check only |
| Small filesystem-free Elixir checks | Confirmed missing maintenance field and traversal path resolution |
| `git diff --check` during review | Passed |
| Full integration, coverage, and Credo suites | Not run |

The installed toolchain differed from `.mise.toml`. Repeat validation with the
pinned environment on a disposable Linux host. Root integration tests create real
systemd units and workload directories; do not run them casually on a primary machine.

## 4. Authorship assessment

The available history contained 24 commits attributed to one named human using two
email addresses, with iterative operational fixes and feature additions. No explicit
AI co-author attribution was found in those commit messages.

The explanatory prose and missing feedback-document reference are compatible with
AI assistance, but do not prove it. Framework-generated scaffolding is also not
evidence of AI generation.

**Tentative assessment:** human-directed, possibly AI-assisted; low confidence.
The human/AI contribution ratio is unknown. Judge readiness by behavior and evidence,
not presumed authorship.

## 5. Autoscaling recommendation

**Fix deployment-safety prerequisites first. Build safe manual scaling next. Let
autoscaling drive that same mechanism rather than introducing a separate deploy path.**

Not every cleanup blocks scaling. F1–F5, readiness/draining, reliable teardown, and
their regression tests are prerequisites. Resolve F6 alongside the work. General
refactoring, additional artifact providers, and UI polish need not delay the foundation.

### Distinguish two control loops

1. **Application scaling:** add/remove replicas on existing eligible agents.
2. **Infrastructure scaling:** provision/decommission machines when capacity changes.

Implement application scaling first. For owned bare metal, capacity may come from
spare hosts rather than newly created machines. Cloud provisioning can be added later.

### Proposed first-release scope

- Opt-in, horizontally scalable HTTP applications.
- Controller/agent mode with pre-registered agents.
- One serving replica of an application per host.
- Explicit minimum/maximum replica counts and manual override/pause.
- Conservative scale-up and slower scale-down.
- No scale-to-zero or automatic machine creation/deletion.
- Initially serialize scaling with application deployment/rollback operations.

Blue/green slots are release slots, **not two steady-state replicas**. Reserve enough
host capacity for their deployment overlap. Application eligibility must account for
sessions, local files, background work, and singleton coordination.

### Proposed architecture

```text
Metrics -> Scaling policy -> Desired replica count
                                      ^
Manual scale request -----------------|
                                      |
                         Placement / reconciliation
                                      |
                          Durable agent operations
                                      |
                         Readiness -> ingress membership
```

The policy selects a desired count; it does not deploy workloads or rewrite Caddy.
Manual scaling, automated scaling, and recovery share the same reconciler.

Extend assignments or introduce replica records with:

- Application and server identity.
- Desired release/configuration revision.
- Lifecycle phase and readiness.
- Last observation time.
- Current operation ID, generation, and failure reason.

Persist operation intent/progress. GenServer memory should not be the sole source
of truth. Suggested phases:

```text
Pending -> Starting -> Ready -> Draining -> Stopped
               |
               +-> Failed
```

Agent commands need operation IDs and generation checks. Retries must not duplicate
hooks or stop a newer instance. Controller restart should reconcile observations
with persisted intent instead of blindly replaying side effects.

A disconnected agent is **unknown**, not confirmed stopped. A replacement can
coexist with a partitioned old replica; reconcile stale assignments before restoring
traffic on reconnection.

### Scale-up lifecycle

1. Select an eligible host with reserved capacity.
2. Create a pending replica pinned to the selected release/configuration revision.
3. Install/start only that replica, not the entire fleet.
4. Require readiness over a stabilization period.
5. Add it to ingress and confirm routing configuration.
6. Complete the operation.

Separate release-wide hooks from replica startup hooks. Adding capacity must not
unexpectedly rerun migrations or other once-per-release work.

### Scale-down lifecycle

1. Select a removable replica.
2. Confirm sufficient other replicas are ready.
3. Remove it from new-request routing and confirm the change.
4. Drain in-flight traffic under an explicit deadline.
5. Stop the service and confirm shutdown.
6. Release its capacity reservation.

If shutdown cannot be confirmed, retain an unresolved operation. Define behavior
for WebSockets and other long-lived connections before promising graceful draining.

### Required routing and health changes

Current ingress is built from assigned servers; assignment is not sufficient proof
that a new replica is ready. Route membership must follow readiness and draining state.

Likewise, the existing `min_healthy` precondition counts connected agents rather
than ready application replicas. Define separate desired-count, readiness-floor,
and placement-capacity concepts.

Sources: `lib/still/ingress.ex:45–61`, `lib/still/orchestrator.ex:331–339`.

### Metrics and policy safeguards

Existing host CPU/memory/disk samples are useful for placement but do not identify
which application needs more replicas on a shared host.

Start with one reliable application-level signal, such as load-tested request rate
per ready replica, in-flight requests, or per-service CPU once reliably available.
Queue-depth scaling belongs to a later worker-specific design. Avoid latency-only
scaling: an overloaded shared dependency may not improve with more app replicas.

Required safeguards:

- Sustained measurement windows, cooldowns, and bounded changes.
- Minimum/maximum replica counts.
- Account for replicas already starting.
- Metric freshness and sufficient-sample checks.
- Manual pause/override and auditable decision reasons.
- Hold count on stale/insufficient observations; missing metrics are not zero load.
- Wait for fresh measurements after controller restart.

Derive thresholds from workload tests, not assumed universal CPU/request targets.

Source for existing host sampling: `lib/still/agent/node_metrics.ex:32–39`.

## 6. Delivery milestones and acceptance gates

### Milestone 1 — Safe manual scaling

- [ ] Fix F1–F5 and establish regression tests.
- [ ] Define the replica lifecycle and durable operation model.
- [ ] Implement readiness-gated ingress membership and confirmed teardown.
- [ ] Expose manual desired replica count with clear operation status.
- [ ] Failed scale-up leaves existing healthy traffic intact.
- [ ] Scale-down never violates the ready-replica floor.
- [ ] Duplicate commands and lost replies do not repeat unsafe side effects.
- [ ] Controller restart at every lifecycle phase recovers correctly.
- [ ] Agent reconnection cannot restore stale traffic.
- [ ] Maintenance remains effective during scaling.
- [ ] Deploy/rollback and scaling cannot conflict.
- [ ] Capacity reservations include blue/green overlap and concurrent placements.

### Milestone 2 — Shadow-mode policy

- [ ] Calculate and log proposed decisions without executing them.
- [ ] Compare decisions against real load and operator judgment.
- [ ] Test missing metrics, spikes, sustained load, pending replicas, and restart windows.

### Milestone 3 — Opt-in automatic application scaling

- [ ] Enable on a noncritical application with strict bounds.
- [ ] Show desired/starting/ready/draining counts and reasons for decisions.
- [ ] Verify pause/override, limits, failure backoff, and operational alerts.

### Milestone 4 — Infrastructure provisioning

- [ ] Add a separate provider interface and capacity reconciliation loop.
- [ ] Define provisioning idempotency, bootstrap authentication, quotas/budgets,
  ownership tracking, and orphan-machine cleanup.
- [ ] Destroy only Still-owned machines confirmed drained of all workloads.

Application autoscaling does not make controller or ingress availability redundant.
Evaluate their availability requirements separately before production commitments.

## 7. Decisions to settle before implementation

1. Does the initial target mean spare-host placement or automatic cloud provisioning?
2. Which workloads are eligible, and what state/singleton assumptions do they have?
3. What fleet size, host heterogeneity, and resource reservations must placement support?
4. Which metric is reliable enough to drive the first policy?
5. What are the readiness floor, drain deadline, and partial-failure recovery policy?
6. What control-plane/ingress availability and disaster-recovery guarantees are required?

The proposed design is a starting point, not an approved API or database schema.
Validate these decisions with runtime tests before turning the roadmap into code.
