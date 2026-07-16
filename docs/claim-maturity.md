# Claim Maturity

Claim Maturity describes how far a statement has progressed from discovery to direct evidence and, separately, which execution dimensions remain unverified.

## Maturity ladder

| Level | Permitted statement | Not permitted |
| --- | --- | --- |
| Discovered | “A file or symbol named X was discovered.” | “X implements or enforces behavior.” |
| Referenced | “Configuration or documentation references X.” | “X exists at runtime.” |
| Content read | “The inspected content declares X.” | “X builds, passes tests, or runs.” |
| Configuration confirmed | “The inspected configuration contains X.” | “The configuration is deployed or effective.” |
| Source behavior confirmed | “Directly read source contains logic for X.” | “The logic was executed successfully.” |
| Execution verified | Reserved for an explicitly authorized build, test, or runtime result. | Generalization beyond the exact environment and action. |

The Legacy assessment path in v0.1.0 does not build, test, deploy, or access production. It therefore normally stops at direct static evidence and records the remaining execution dimensions as unknown.

## Confidence

Confidence (`HIGH`, `MEDIUM`, `LOW`, or `UNKNOWN`) reflects evidence quality and consistency, not model certainty alone. High-confidence static evidence can still have `RUNTIME_NOT_VERIFIED`. A contradiction or missing critical evidence must be visible in the claim's unknowns.

## Writing public findings

Prefer precise phrases:

- “The route was directly read and contains an authorization call.”
- “A database URL key is present in example configuration; connectivity was not tested.”
- “No approval mechanism was discovered in the inspected scope; absence is not proven outside that scope.”

Avoid “secure,” “works,” “production-ready,” “deployed,” or “fully integrated” unless the exact corresponding verification exists.
