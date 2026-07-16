# Changelog

All notable changes to FDE Agent will be recorded here. Dates are assigned only when a release is actually published.

## [0.1.0] - Unreleased

Suggested title: **FDE Agent v0.1.0 — Evidence-driven Assessment and Safe Sandbox**

### Added

- Read-only Legacy inspection and deterministic engineering routing.
- Evidence Ledger, Claim Maturity, and grounded YES / PARTIAL / NO assessment.
- Legacy blockers, AI Agent black boxes, uncertainty, operational workflow, and validation planning.
- Live mission Activity backed by runtime events.
- SHA-256 source snapshots and source-integrity monitoring.
- Safe Sandbox creation, copy verification, inode/filesystem isolation, and safe destruction.
- Sensitive-file exclusions, path-containment checks, and human-controlled safety boundaries.
- Synthetic public Legacy fixture and sanitized example report.
- Public documentation, repository hygiene rules, and deterministic macOS CI.
- Mozilla Public License 2.0 project licensing and SPDX package metadata.

### Safety

- The public live application now composes `PublicReleaseToolExecutor` and advertises only the read-only inspection allowlist.
- Candidate Patch, generated-test, and product-file mutation operations remain unavailable; the Phase 2D.0 writable allowlist is empty.
- Shell, AppleScript, connector execution, Git operations, dependency installation, Legacy build/test, and deployment are outside the v0.1.0 public capability surface.

### Verification record

- 450 tests executed; 0 failures; 2 explicit live-environment opt-in tests skipped by default.
- Equivalent native FDE UI Safe Sandbox acceptance completed successfully.
- Isolated Swift build passed.
- Real acceptance: 84 included files, 0 excluded files because the selected clean fixture contained no excluded entries.
- Sensitive exclusion behavior verified separately by deterministic tests.
- Public mission-surface test passed for read-only Legacy inspection, AI Agent integration assessment, the dedicated Safe Sandbox route, and the unavailable Phase 2D.1 surface.
- Synthetic demo smoke test passed: 8 included files, 0 excluded files, source unchanged, and Sandbox destroyed.
- Secret-signature and personal absolute-path scans found no release finding; assignment scanning found only explicit deterministic `test-key`/`test-anthropic` fixtures.
- `LICENSE` byte-matched Mozilla's official MPL 2.0 plaintext.

### Publication blockers

- GitHub Private Vulnerability Reporting must be enabled when the repository is created and before release announcement.
- No Git tag or public release has been created.
