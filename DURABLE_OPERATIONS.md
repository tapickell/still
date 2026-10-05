# Durable deployment operations (Phase 2)

Still now separates accepting a deployment command from waiting for its result.
The public deploy/restart/rollback endpoints remain asynchronous JSON APIs. Normal
controller execution uses the versioned `durable_operations_v1` agent capability;
it no longer holds a 120-second deployment RPC open.

## Persistence and ordering

- The controller stages the release/revision, then commits **all** per-host
  commands and their rollout order before dispatching the first command.
- Each command has a stable operation ID and a monotonically increasing
  application/server generation. Its complete request is retained privately in
  SQLite. Restarting the controller reuses these records, not a newly generated
  command or a changed assignment list.
- The agent syncs a checksummed journal before acceptance and before each step's
  side effects. It records completed phases, the original slot context, and the
  outcome. Journals live under `<applications_dir>/.operations/<id>.etf`, with
  directory mode 0700 and file mode 0600. They contain environment values and
  commands: protect them and their backups as secrets.
- Repeating an ID with identical parameters returns its existing state. Reusing
  an ID with different parameters, or submitting an older generation, is rejected.
- Reports carry a generation and sequence. Old, wrong-server, or wrong-generation
  reports cannot advance an operation. A settled terminal result cannot regress.
- Legacy deployment calls are refused once an application has durable history,
  including during manager restart gaps. Route-only changes remain a separate,
  best-effort API and cannot run concurrently with that application's operation.

The controller uses short status RPCs and approximately one-second polling, with
progress also pushed by connected agents. A transport timeout means **unknown**,
not “failed” or “cancelled.” The application remains locked until the same
operation has a known outcome. Missing journals after observed acceptance are not
treated as permission to execute the command again.

## Recovery behavior

Controller restart preserves pending/in-progress durable deployments and resumes
their stored rollout. Completed host steps are not dispatched again. Legacy
in-progress deployments without durable intent retain the old fail-on-restart
behavior; this migration does not fabricate historical operations.

Agent restart re-observes incomplete work:

- Interrupted downloads, immutable extraction, and standby symlink preparation
  can be retried from the saved context.
- A lost traffic-switch acknowledgement is checked against the release marker,
  symlink, Caddy route, and—for processes—systemd state and HTTP readiness.
- An interrupted state-file commit is repeated from the **saved pre-operation
  context**, so the old slot/version is not accidentally recalculated.
- A changed route, missing release, stopped target, or failed readiness check
  leaves the operation unknown instead of blindly moving traffic or stopping a slot.
- An interrupted configured hook or process start is ambiguous. The engine does
  not automatically repeat migrations or assume a start's external effects completed.

Worker exits trigger a bounded re-observation attempt. Persistently ambiguous work
stays paused. Corrupt or conflicting journals block admission. Cancellation,
automatic fleet rollback, controller HA, resource autoscaling, and full drift
remediation are **not** added by this phase.

## Inspecting an operation

`GET /api/deployments/:id` includes an `operations` array containing:

```json
{
  "id": "operation-uuid",
  "server_id": "server-uuid",
  "generation": 3,
  "status": "unknown",
  "sequence": 12,
  "phase": "starting",
  "error": "{:ambiguous_side_effect, :starting}"
}
```

Statuses are `pending`, `accepted`, `running`, `unknown`, `succeeded`, and `failed`.
The parent deployment remains `in_progress` while an operation is unknown. Request
payloads and saved execution contexts are not exposed in this response.

For an operator with root-level access to **Still's own** IEx console:

```elixir
Still.Operations.list(deployment_id) # controller only; public progress fields

# From the controller's console, use the actual connected agent node name.
:erpc.call(agent_node, Still.Agent.OperationManager, :status, [operation_id])
:erpc.call(agent_node, Still.Agent.OperationManager, :recover, [operation_id])
```

`recover/1` re-observes the same paused operation after host repair. It does not
re-run an ambiguous hook. Both recovery calls are privileged internal APIs, not
new public HTTP endpoints.

**Only after independently confirming that an interrupted side effect completed**:

```elixir
:erpc.call(agent_node, Still.Agent.OperationManager, :confirm_phase,
  [operation_id, :release])
```

Confirmable phases are `pre_deploy`, `release`, `post_deploy`, `pre_rollback`,
`post_rollback`, and `starting`. This is an operator attestation, not a health check
or a safe “retry” button. Inspect the process tree, journal, migration state, and
external effects first; child processes can outlive a failed BEAM. Confirmation
skips that phase and resumes observation/execution of the remaining phases.
Confirming `starting` still requires the target release, process, and health probe
to agree before continuing. If the original effect did not complete, repair or
complete it deliberately before confirming. There is no claim of exactly-once
execution for arbitrary shell scripts. The agent journal records the confirmed
phase, timestamp, and caller node; this is not an authenticated human identity.

## Concurrency, hooks, and routing

Different applications can execute in independent supervised workers on the same
agent. A single application has one mutation lane. Log collectors are private to
each operation and monitor their worker; a log-capture failure must not kill the
deployment. Caddy read/modify/write operations are serialized per endpoint within
the owning Still node, including bootstrap and ingress writes. This does not
coordinate independent external Caddy administrators or multiple Still owners of
the same endpoint.

Existing hooks default to `scope: "per_replica"`. To opt in to rollout scope, set
`"scope": "per_rollout"` when creating or updating a hook through its existing API:

- `pre_deploy`, `release`, and `pre_rollback` run on the first selected host.
- `post_deploy` and `post_rollback` run on the last selected host after earlier
  hosts succeeded. They do not run if the rollout halts before reaching that host.
- Host selection and filtered hook payloads are frozen in the operation records.
- Restart continues to run no lifecycle hooks. `ExecStartPre` remains a systemd
  per-start action, not a rollout hook.

No existing hook changes scope automatically. A new deployment is a new rollout;
its rollout-scoped hook may legitimately run again. Keep scripts idempotent where
possible even with durable progress.

Agent-local routing edits made during an active operation are deferred/refused to
avoid racing its slot switch. The controller refreshes changed routing after the
rollout settles. An unknown operation can therefore delay agent-local maintenance
changes. Check live Caddy/HTTP behavior rather than assuming a saved setting has
already taken effect. Fully versioned, independently reconciled live routing
policy remains Phase 3 work.

## Upgrade and operational limits

1. Pause new deploys and let old in-flight work settle before upgrading.
2. Back up the controller database, agent state, and private operation journals
   together. Upgrade the controller and agents, then wait for capability announcements.
3. Agents without `durable_operations_v1` leave new work unknown/waiting for upgrade;
   they are not sent an unfenced legacy substitute.
4. Do not delete journals, reset generations, restore only one side's history, or
   downgrade binaries independently. Journal/storage loss is an operator incident,
   not proof that previous side effects never happened.

Operations and generations are retained. Application/server deletion and assignment
removal are blocked when durable history still refers to them; assignment changes
are also blocked during an active durable rollout. This prevents forgetting intent
or reusing ports while the agent may still own a workload. A coordinated
decommission/retention workflow is not implemented yet and belongs with the later
teardown/scaling work. Ordinary CRUD deletion is not a safe substitute.

This implementation assumes one active controller and one stable agent identity
per server. Filesystem sync/rename protects journal commits, but this is not a
transaction spanning SQLite, Caddy, systemd, external migrations, and storage
hardware. Observe or pause whenever those systems disagree.

## Validation

```sh
mix test
MIX_ENV=test mix credo --strict
bash scripts/test-linux.sh all
bash scripts/test-linux.sh coverage
```

The coverage command includes unit, Caddy/distributed, and root/systemd integration
tests, retaining the 100% threshold and existing explicit exclusions. It needs the
same privileged disposable Linux environment as the root suite. Unit-only coverage
cannot exercise real systemd recovery observations.
