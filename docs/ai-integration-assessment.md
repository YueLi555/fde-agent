# AI Integration Assessment

## Purpose

The assessment asks whether a specified AI Agent could be integrated with a selected Legacy system under explicit safety and operational constraints. It analyzes both sides: Legacy capabilities/blockers and AI Agent black boxes/uncertainty.

## Method

1. Parse the requested Agent type and whether it implies write access.
2. Derive required Legacy capabilities such as authentication, authorization, API boundaries, audit logging, knowledge sources, approvals, or business-action APIs.
3. Inspect only the selected scope using the read-only tool allowlist.
4. Convert direct observations into evidence-backed architecture signals and explicit absences/unknowns.
5. Classify each requirement as `SUPPORTED`, `BLOCKED`, or `UNKNOWN`.
6. Produce a grounded overall answer: `YES`, `PARTIAL`, or `NO`.
7. Describe Legacy blockers, model-side black boxes, an operational workflow, and a validation plan.

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

## Required model-side uncertainty

An assessment must address hallucination, prompt injection, retrieval quality, nondeterminism, model/version drift, context truncation, tool-call correctness, data leakage, authorization confusion, and observability. Static Legacy evidence cannot prove an AI model will behave correctly.

## Operational workflow

A proposed workflow should keep the Agent behind authenticated, least-privilege service boundaries; ground responses in approved data; separate suggestions from consequential actions; require human review where appropriate; log decisions and evidence; and support rollback/disable controls. This is a proposal, not a deployed integration.

## Validation plan

Plans should identify contract tests, authorization and tenant-isolation tests, prompt-injection and exfiltration tests, offline evaluation sets, failure-mode exercises, audit verification, human-approval tests, observability thresholds, rollback drills, and staged rollout criteria. v0.1.0 generates plans only; it does not execute Legacy validation.
