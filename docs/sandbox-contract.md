# Safe Sandbox Contract

## Inputs

- A selected canonical Legacy root.
- The same root as the explicitly approved Legacy root.
- A Sandbox storage root outside the Legacy and Agent roots.
- An optional expected source snapshot identifier.

`SAFE_SANDBOX_ACCEPTANCE` reaches this contract through its dedicated product-runtime route. The coordinator invokes `RuntimeKernel.runSafeSandboxAcceptance`, which uses the manifest-backed `SandboxLifecycleService` directly. It does not use the generic `PublicReleaseToolExecutor` or a shell.

## Creation contract

1. Canonicalize and validate roots.
2. Reject an Agent workspace, a source under Sandbox storage, or storage inside the source.
3. Enumerate source without following symlinks.
4. Classify exclusions without reading sensitive values.
5. Build a deterministic SHA-256 source snapshot.
6. Check local availability; dataless or unreadable source fails closed.
7. Copy included files into `<SANDBOX_ROOT>/<SANDBOX_ID>/workspace`.
8. Verify copied hashes and independently stored file identities.
9. Persist a manifest and mark the Sandbox ready only after all checks pass.

Safe `.env.example` files are includable; `.env`, secret-bearing variants, credentials, keys, certificates, local databases, dependencies, version-control metadata, build products, caches, logs, and temporary files are excluded.

## Runtime states

`creating → validating → ready → stale/invalid` and `ready → destroying → destroyed`.

The runtime emits aggregate Activity for selection, source availability, snapshot calculation, creation, copying, sensitive exclusion, SHA-256 verification, containment, source isolation, readiness, and destruction. Public reports sanitize roots and identifiers.

## Integrity contract

- The copied workspace hash set equals the included source hash set.
- Every copied file has a different inode or device/inode tuple from its source.
- No sensitive item is present in the copied workspace.
- Source integrity is unchanged before and after the lifecycle.
- Added, removed, changed, moved, or exclusion-metadata changes mark the Sandbox stale.

## Destruction contract

Destruction accepts a validated `SandboxID`, resolves it under the configured Sandbox storage root, rejects path traversal or unrelated targets, removes only that Sandbox, and records `destroyed`. It never deletes the Legacy root.

## Writable capability

`SandboxRuntimePolicy.phase2D0Allowlist` is empty. Candidate Patch, generated tests, and product-file mutation are modeled only as unavailable future operation names; no request or human approval can authorize them in v0.1.0. Phase 2D.1 is not started.
