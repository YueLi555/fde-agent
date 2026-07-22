# AI Integration Assessment

## Purpose

The assessment asks whether a specified AI Agent could be integrated with a selected Legacy system under explicit safety and operational constraints. It analyzes both sides: Legacy capabilities/blockers and AI Agent black boxes/uncertainty.

## Method

1. Parse the requested Agent type and whether it implies write access.
2. Derive required Legacy capabilities such as authentication, authorization, API boundaries, audit logging, knowledge sources, approvals, or business-action APIs.
3. Inspect only the selected scope using the read-only tool allowlist.
4. Convert direct observations into evidence-backed architecture signals and explicit absences/unknowns.
5. Classify each requirement as `SUPPORTED`, `BLOCKED`, or `UNKNOWN`.
6. Produce a grounded overall answer: `YES`, `PARTIAL`, `NO`, or `UNKNOWN` for Phase 3B.3B reports.
7. Describe Legacy blockers, model-side black boxes, an operational workflow, and a validation plan.
8. For Phase 3B.3B reports, deterministically derive a Phase 3B.4 advisory recommendation set from validated claim IDs, risk metadata, blockers, unknowns, and candidate integration seams.
9. Present the exact Phase 3B.3B report and Phase 3B.4 recommendation set for a Phase 3B.5 human disposition without turning that disposition into execution approval.

## Outcome semantics

| Requirement status | Meaning |
| --- | --- |
| `SUPPORTED` | Direct static evidence supports the required capability within the inspected scope. Runtime may still be unverified. |
| `BLOCKED` | Direct evidence shows a conflicting design or a required control is confirmed absent in the inspected scope. |
| `UNKNOWN` | Evidence is missing, indirect, contradictory, or outside the inspected scope. |

| Overall answer | Meaning |
| --- | --- |
| `YES` | Critical requirements are statically supported, subject to stated execution unknowns and validation. |
| `PARTIAL` | Some requirements are supported, but blockers or material unknowns remain. |
| `NO` | One or more critical requirements are blocked under the requested design. |
| `UNKNOWN` | No evidence-grounded feasibility conclusion is available for the required scope. |

## Phase 3B.4 recommendation semantics

Phase 3B.4 accepts only an identity-valid Phase 3B.3B report whose section entries resolve to its validated evidence appendix. It produces a stable, workspace/task/session-bound recommendation set and fails closed when report identity, scope, appendix bindings, or claim lineage do not match.

| Recommendation decision | Meaning |
| --- | --- |
| `PROCEED_TO_VALIDATION` | Static evidence supports the required scope. Only bounded, non-production validation is recommended. |
| `CONDITIONALLY_PROCEED` | Advance only the supported subset after the named blockers and material unknowns are resolved or bounded. |
| `DO_NOT_PROCEED` | Hold integration handoff until evidence-backed blockers are remediated and the assessment is recomposed. |
| `INVESTIGATE` | Evidence is insufficient for a feasibility decision; collect bounded read-only evidence and recompose the report. |

Recommendations are ordered by priority and cover the decision gate, blocker remediation, deterministic security controls, evidence investigation, integration design, and validation. Every recommendation cites validated Phase 3B.3B claim IDs. Recommendation artifacts are `ADVISORY_ONLY` and always carry `executionAuthorized = false`; they do not alter RuntimeKernel, policy admission, approval, or execution authority.

## Phase 3B.5 human-review semantics

Phase 3B.5 opens one deterministic review for an exact workspace/Mission/task/Agent-session-bound report and recommendation set. The reviewer can `ACKNOWLEDGE_FOR_PLANNING`, `REQUEST_CHANGES`, or `REJECT_RECOMMENDATIONS`. Acknowledgement means only that the assessment is accepted as advice for future planning. A change request requires instructions; every disposition is final for that immutable recommendation set, and a revised report produces a distinct review rather than mutating history.

The review record retains the exact report and recommendation-set SHA-256 digests, complete recommendation-ID and validated claim-ID scope, reviewer identity, optional note, timestamp, current authenticated/workspace/app-session binding, and a tamper-evident decision identity. Persisted review events are revalidated during projection. Missing, duplicate, stale, cross-session, or digest-invalid source or review state fails closed and cannot silently reopen as a pending action.

Human assessment review is `ADVISORY_REVIEW_ONLY`. Acknowledging an assessment does not create or satisfy an `ApprovalRequest`, approve an Execution Plan, modify the Evidence Ledger, change RuntimeKernel or Mission admission, or authorize validation, Candidate Patch creation, Legacy mutation, shell, Git, deployment, credential access, or production execution. Requesting assessment changes and rejecting an assessment likewise record feedback only. Those boundaries continue to require their existing independent policy and approval contracts.

## Required model-side uncertainty

An assessment must address hallucination, prompt injection, retrieval quality, nondeterminism, model/version drift, context truncation, tool-call correctness, data leakage, authorization confusion, and observability. Static Legacy evidence cannot prove an AI model will behave correctly.

## Operational workflow

A proposed workflow should keep the Agent behind authenticated, least-privilege service boundaries; ground responses in approved data; separate suggestions from consequential actions; require human review where appropriate; log decisions and evidence; and support rollback/disable controls. This is a proposal, not a deployed integration.

## Validation plan

Plans should identify contract tests, authorization and tenant-isolation tests, prompt-injection and exfiltration tests, offline evaluation sets, failure-mode exercises, audit verification, human-approval tests, observability thresholds, rollback drills, and staged rollout criteria. v0.1.0 generates plans only; it does not execute Legacy validation.
