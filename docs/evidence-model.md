# Evidence Model

FDE Agent treats evidence as a structured input to claims, not as decorative citations.

## Evidence record

An assessment evidence reference records:

- source type, such as inspected file, static search, extracted configuration, ledger, or user intent;
- workspace-relative path or a non-file request identifier;
- the observed fact and a safe summary;
- observation status;
- claim level;
- source component and optional line range;
- optional file hash, workspace snapshot identifier, and related runtime event identifier.

## Observation statuses

| Status | Interpretation |
| --- | --- |
| `DISCOVERED` | The path or symbol was enumerated. Contents are not implied. |
| `REFERENCED` | Another artifact named the item, but FDE did not directly inspect it. |
| `DIRECTLY_READ` | Relevant bounded content was read from the selected workspace. |
| `USER_PROVIDED` | The statement came from the request and is intent, not system proof. |

## Verification dimensions

Every public claim must preserve independent verification dimensions. `CONFIGURATION_CONFIRMED` means configuration text is present; it does not mean runtime behavior was exercised. Static inspection normally carries `BUILD_NOT_EXECUTED`, `TEST_NOT_EXECUTED`, and `RUNTIME_NOT_VERIFIED`. Deployment remains `DEPLOYMENT_NOT_VERIFIED` unless a separately authorized future process proves otherwise; v0.1.0 has no such process.

## Provenance and privacy

Evidence paths are workspace-relative in presentation. Source snapshots use SHA-256 identifiers. Runtime events use internal identifiers, but sanitized public reports replace them with `<SNAPSHOT_ID>`, `<SANDBOX_ID>`, and similar placeholders. Sensitive-file contents are never needed to prove that the exclusion policy recognized them.

## Claim rule

A claim is publishable only when its statement, supporting evidence, confidence, unknowns, and verification status agree. Missing evidence lowers maturity; it must not be compensated for with confident language.
