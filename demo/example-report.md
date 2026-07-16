# Synthetic AI Integration Assessment

## Scope

- Legacy root: `<LEGACY_ROOT>`
- Requested Agent: sales-assistance Agent that can read order context and proposes outreach
- Inspection: static, bounded, read-only
- Source snapshot: `<SNAPSHOT_ID>`
- Build: not executed
- Tests: not executed
- Runtime: not verified
- Deployment: not verified

## Overall answer: PARTIAL

The directly read fixture supports a bounded, read-only order-context lookup behind an authentication/role check. The requested outreach capability is blocked because no outbound-action API or human approval mechanism is present. Production identity, tenant isolation, data quality, and model behavior remain unknown.

## Capability matrix

| Status | Capability | Evidence and maturity |
| --- | --- | --- |
| SUPPORTED | Read order context | `src/orders.ts` was directly read and declares a customer-scoped lookup guarded by the `support` role. Source behavior confirmed; runtime not verified. |
| SUPPORTED | Authentication boundary | `src/auth.ts` was directly read and rejects missing example tokens before constructing a principal. Source behavior confirmed; security strength not verified. |
| SUPPORTED | Audit event shape | `src/audit.ts` was directly read and defines a bounded audit record helper. Presence does not prove every route calls it. |
| BLOCKED | Outbound communication or CRM mutation | No business-action endpoint was discovered in the complete eight-file fixture. The requested write path is absent in the inspected scope. |
| BLOCKED | Human approval before outreach | No approval model, queue, or API was discovered in the complete fixture. |
| UNKNOWN | Production identity and tenant isolation | Example source and configuration do not prove production identity-provider integration or tenant enforcement. Deployment was not inspected. |
| UNKNOWN | Model answer quality and prompt-injection resistance | No model was executed and no evaluation dataset is present. |

## Legacy blockers

- No bounded business-action API for outreach or CRM writes.
- No human approval mechanism for consequential actions.
- No evidence that the audit helper is enforced across all future actions.
- Configuration is explicitly an example and does not establish a deployed environment.

## AI Agent black boxes

- Hallucinated order facts or unsupported recommendations.
- Prompt injection embedded in customer-controlled content.
- Incorrect tool arguments or customer identifiers.
- Context truncation, nondeterminism, model/version drift, and retrieval gaps.
- Sensitive-data leakage through prompts, logs, or provider retention.

## Proposed operational workflow

1. Authenticate the human and Agent service identity.
2. Authorize a customer-scoped, read-only order lookup.
3. Retrieve minimal approved fields through a stable API boundary.
4. Generate a suggestion with citations to the retrieved records.
5. Present the suggestion to a human; do not send or mutate anything.
6. Record evidence, decision, model/version metadata, and human disposition.
7. Add a separately reviewed action API and approval control before considering any write capability.

## Validation plan

- Contract-test the order lookup and authorization failures.
- Test cross-customer and cross-tenant access denial.
- Evaluate prompt injection, data exfiltration, hallucination, and abstention on a synthetic dataset.
- Verify audit completeness and redaction.
- Exercise provider outage, timeout, malformed output, and rollback/disable paths.
- Require security review and staged human-only trials before any action API is designed.

## Safe Sandbox acceptance

- Included files: 8
- Excluded files: 0 (the clean synthetic fixture contains no excluded entry)
- Sensitive exclusion behavior: verified separately by deterministic tests
- SHA-256 copy validation: passed
- Inode/filesystem isolation: passed
- Source integrity before/after: unchanged / unchanged
- Sandbox destruction: passed
- Sandbox ID: `<SANDBOX_ID>`
- Phase 2D.1 started: no

This report is a sanitized example. It is not proof of production readiness, deployment, autonomous integration, or guaranteed AI correctness.
