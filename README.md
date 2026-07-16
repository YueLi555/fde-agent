FDE Agent is a local-first, evidence-driven engineering agent that analyzes Legacy systems, evaluates whether AI Agents can be integrated safely, explains Legacy and model-side risks, and creates verified disposable Sandboxes without modifying the original codebase.

# FDE Agent

**v0.1.0 release candidate — Read-only AI Integration Assessment and Safe Sandbox Foundation**

FDE Agent is not a general chat assistant and it is not an unrestricted coding Agent. General assistants can answer from conversation context without examining a selected system; unrestricted coding Agents may edit files or run commands. This release instead routes engineering requests into bounded read-only inspection, records the evidence behind each claim, preserves uncertainty, and exposes no live workspace-mutation or shell-execution capability. Its Safe Sandbox feature copies approved source into a disposable, independently stored workspace and never authorizes Phase 2D.1 mutation operations.

## What v0.1.0 includes

- Natural-language FDE conversation with deterministic engineering routing.
- Separate Legacy and Agent workspace identities.
- Read-only project discovery, file listing, static search, and bounded file reading.
- Evidence Ledger entries with source, observation status, claim level, and provenance.
- Claim Maturity and grounded YES / PARTIAL / NO AI integration assessments.
- Legacy blocker, AI Agent black-box, uncertainty, workflow, and validation-plan analysis.
- Live runtime Activity derived from real mission events.
- SHA-256 source snapshots and source-integrity monitoring.
- Safe Sandbox creation, validation, inode/filesystem isolation checks, and destruction.
- Sensitive-file exclusion and path-containment policies.
- Human-controlled safety boundaries and fail-closed behavior.

## What v0.1.0 does not include

- Candidate Patch or test-file generation.
- Mutation of a Legacy workspace or of a Safe Sandbox.
- Dependency installation or Legacy build/test execution.
- Shell, AppleScript, Git branch/worktree/commit/push/merge, or deployment as a public product capability.
- Credential, production, or autonomous external-system access.
- Production-readiness, deployment, or guaranteed model-correctness claims.

Older internal executor types remain in the source tree because the completed codebase has deterministic compatibility tests around them. The public application composition uses `PublicReleaseToolExecutor`, advertises only `ReadOnlyInspectionPolicy` tools, and denies mutation, command, and connector calls. See [Known Limitations](docs/known-limitations.md).

## Public mission surface

| Product mission | Runtime route | Public authority |
| --- | --- | --- |
| Read-only Legacy inspection | `READ_ONLY_WORKSPACE_INSPECTION` | Bounded directory listing, project inspection, file search, code search, and file reading. |
| AI Agent integration assessment | `READ_ONLY_WORKSPACE_INSPECTION` | The same read-only evidence surface, followed by grounded compatibility, blocker, uncertainty, workflow, and validation-plan analysis. |
| `SAFE_SANDBOX_ACCEPTANCE` | Dedicated Safe Sandbox route | Snapshot, independently copy, validate, monitor source integrity, and destroy the disposable Sandbox through the manifest-backed Swift runtime. |

`PublicReleaseToolExecutor` is the gate for generic model-emitted tool calls. It accepts only API calls in `ReadOnlyInspectionPolicy.allowedTools`; it does not implement or disable the dedicated Safe Sandbox lifecycle. The mission coordinator routes `SAFE_SANDBOX_ACCEPTANCE` directly to `RuntimeKernel.runSafeSandboxAcceptance`, which uses `SandboxLifecycleService` without shell execution. Candidate Patch, generated tests, Legacy or Sandbox mutation, shell, Git, deployment, credential, and production capabilities are unavailable through both paths.

## Requirements

- macOS 14 or later.
- Swift 6 toolchain (the package manifest uses Swift tools 6.0).
- No API key is required for the deterministic build, test suite, synthetic demo, or local fallback.

## Build and test

Use isolated scratch paths so generated content remains disposable and ignored:

```bash
swift build --scratch-path .build-release
swift test --scratch-path .build-tests
```

The two live-workspace acceptance tests are opt-in and skip unless their explicit environment flags and fixture paths are provided. Public CI does not set those flags and never accesses a real Legacy project.

## Synthetic demo

[`demo/SyntheticLegacy`](demo/SyntheticLegacy) is a fully synthetic eight-file Legacy fixture. Its companion [example report](demo/example-report.md) demonstrates:

- read-only evidence and SUPPORTED / BLOCKED / UNKNOWN outcomes;
- Legacy blockers and AI Agent black boxes;
- a proposed operational workflow and validation plan;
- source snapshot, independent Sandbox copy, integrity checks, destruction, and unchanged source.

The deterministic product-runtime test `testRealRuntimeRunsManifestBackedLifecycleAndDestroysSandbox` executes the Safe Sandbox lifecycle against this checked-in fixture. The demo contains no real user or private-project data.

## Evidence language

FDE Agent distinguishes these states rather than treating file discovery as proof:

| State | Meaning |
| --- | --- |
| Discovered | A path or symbol was enumerated; its contents may not have been read. |
| Directly read | The relevant bounded content was read and recorded as evidence. |
| Configuration present | Configuration text was read; runtime behavior is still unverified. |
| Build not executed | No Legacy build result exists. |
| Test not executed | No Legacy test result exists. |
| Runtime not verified | Static evidence does not prove runtime behavior. |
| Deployment not verified | No deployment or production environment was inspected. |

## Verification record

The Phase 2D.0 completion record carried into this release states:

- 450 tests executed, 0 failures.
- 2 explicit live-environment opt-in tests skipped by default.
- Equivalent native FDE UI Safe Sandbox acceptance completed successfully.
- Isolated Swift build passed.
- The real acceptance included 84 files and excluded 0 because the selected clean fixture had no excluded entries.
- Sensitive exclusion behavior is additionally verified by deterministic tests containing synthetic sensitive filenames and values.
- The named public mission-surface gate confirms read-only Legacy inspection, read-only AI Agent integration assessment, the dedicated Safe Sandbox route, and an unavailable Phase 2D.1 surface.

These statements describe completed verification, not production readiness. The current release-candidate verification is recorded in [CHANGELOG.md](CHANGELOG.md) and [the release audit](docs/release-audit.md).

## Documentation

- [Architecture](docs/architecture.md)
- [Safety model](docs/safety-model.md)
- [Evidence model](docs/evidence-model.md)
- [Claim maturity](docs/claim-maturity.md)
- [AI integration assessment](docs/ai-integration-assessment.md)
- [Safe Sandbox contract](docs/sandbox-contract.md)
- [Threat model](docs/threat-model.md)
- [Known limitations](docs/known-limitations.md)
- [Dependencies and licenses](docs/dependencies-and-licenses.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)

## License

FDE Agent is licensed under the [Mozilla Public License 2.0](LICENSE), identified as `MPL-2.0`. The repository license is Mozilla's official, unmodified plaintext. Dependency notices are documented in [NOTICE.md](NOTICE.md).
