# Threat Model

## Assets

- Legacy and Agent source confidentiality and integrity.
- Credentials and user data near a workspace.
- Evidence and assessment accuracy.
- Sandbox provenance and containment.
- Local task/event data.
- Human control over consequential operations.

## Trust boundaries

The human-selected workspace, local filesystem, optional model provider, model output, runtime policy, Sandbox storage, and public report are separate trust domains. Model output is untrusted input to deterministic validation. A filesystem path is untrusted until canonicalized and contained.

## Threats and controls

| Threat | Primary controls | Residual risk |
| --- | --- | --- |
| Legacy mutation | Public read-only executor; empty Sandbox writable allowlist; no command product surface | Older internal executor code remains in-tree and requires continued composition tests. |
| Path traversal or symlink escape | Canonicalization, workspace-relative schemas, containment checks, no source symlink following | Filesystem race conditions remain a subject for independent review. |
| Secret copying | Name/extension/directory exclusions and safe metadata-only tracking | Novel secret filenames or secrets embedded in ordinary source may still be included. |
| Dataless cloud file | Availability checks fail closed before snapshot/copy | Provider-specific filesystem behavior may vary. |
| Hard-link/alias source coupling | Device/inode isolation validation and copied hash comparison | Filesystem implementations can differ; tests cover supported macOS behavior. |
| Source changes during lifecycle | Before/after snapshots and integrity monitoring | A narrow race may exist without filesystem-level locking. |
| Unsafe destruction | Validated Sandbox ID, canonical storage root, target containment | Bugs in platform filesystem APIs remain possible. |
| Hallucinated assessment | Evidence Ledger, claim maturity, direct-read status, unknowns, deterministic finalization | Model summaries can still misstate evidence; human review is required. |
| Prompt injection in Legacy files | Tool allowlist, no mutation/command authority, bounded reading | Injection may still bias language output or cause denial of service. |
| Data sent to external model | Local deterministic fallback; explicit provider configuration | Selecting an external provider can transmit scoped context under that provider's policy. |
| Log/database leakage | Sanitized Activity, ignored runtime state, no shipped database/log | Local runtime artifacts still need OS/user access controls. |
| CI secret or real-workspace access | No secret requirement, local provider, synthetic tests, live tests opt-in | Action supply-chain and hosted-runner risks remain. |

## Out of scope

Production deployment, multi-user service isolation, hostile local administrators, compromised operating systems, guaranteed AI correctness, and Phase 2D.1 mutation are not security claims of v0.1.0.
