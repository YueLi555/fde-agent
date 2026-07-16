# Safety Model

## Safety objective

FDE Agent should produce useful engineering evidence without converting an inspection request into authority to change the inspected system. Safety is enforced by routing, workspace identity, tool allowlists, path containment, cryptographic provenance, and explicit uncertainty—not by prompt wording alone.

## Invariants

1. Legacy inspection tools are read-only and bounded to the selected workspace.
2. Legacy and Agent workspaces have distinct identities; the Agent root cannot be used as a Legacy Sandbox source.
3. Safe Sandbox storage is outside the Legacy tree and a Sandbox is an independent copy, not a hard link or alias.
4. Sensitive, generated, dependency, version-control, cache, database, and temporary content is excluded according to policy.
5. SHA-256 snapshots cover included files; excluded entries are represented by safe metadata rather than secret contents.
6. Source integrity is checked before and after the lifecycle.
7. Destruction targets only a validated Sandbox directory with a validated identifier.
8. The Phase 2D.0 writable-operation allowlist is empty.
9. Public claims retain build, test, runtime, and deployment unknowns.
10. Human approval cannot enable an operation that is unavailable in the release policy.

## Layers of enforcement

| Layer | Control |
| --- | --- |
| Mission routing | Exposes read-only Legacy inspection, AI Agent integration assessment over read-only evidence, and a dedicated `SAFE_SANDBOX_ACCEPTANCE` route while separating unsupported modification intents. |
| Tool surface | `PublicReleaseToolExecutor` gates generic model-emitted calls and prompt discovery to bounded read operations only. It is not the Sandbox lifecycle executor. |
| Sandbox runtime | The dedicated route calls the manifest-backed `SandboxLifecycleService` directly; the Phase 2D.0 writable-operation allowlist is empty. |
| Read policy | Rejects unapproved commands, sensitive paths, traversal, and paths outside the chosen root. |
| Sandbox policy | Rejects Agent sources, nested storage, absolute/traversal targets, symlink escapes, and unavailable writable operations. |
| Provenance | Source snapshot identifiers are derived from deterministic SHA-256 file records. |
| Isolation | File device/inode identities demonstrate that copies are independently stored. |
| Monitoring | Source additions, removals, modifications, moves, and exclusion-metadata changes mark the Sandbox stale. |
| Reporting | Activity and reports use aggregate/sanitized metadata and distinguish evidence maturity. |

## Human control

The human selects the workspaces and initiates Sandbox creation/destruction. Approval is an additional restriction, not a substitute for capability policy. v0.1.0 has no approval path that can turn on Candidate Patch, generated-test, product mutation, shell, Git, deployment, credential, or production operations.

## Failure behavior

Ambiguous roots, missing or dataless source content, containment failures, mismatched copies, changed source, insufficient storage, and unsafe destruction fail closed. Failures are reported using sanitized categories; raw sensitive contents should not enter activity or public reports.
