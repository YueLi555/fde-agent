# v0.1.0 Release Audit

This audit records release-preparation findings and remediation. It is not an independent penetration test.

## Copy hygiene

| Finding | Remediation |
| --- | --- |
| The development directory contained `.build`, multiple named build scratch trees, `.tmp`, a local `.home`, and an object file. | The independent candidate copied only releasable content; all generated/scratch/object content was excluded and matching patterns were added to `.gitignore`. |
| Runtime databases, logs, Sandboxes, caches, IDE user state, environment files, credentials, keys, and certificates could be created locally. | None were copied; strict ignore patterns cover them while allowing value-free `.env.example` templates. |

## Privacy and identifiers

| Finding | Remediation |
| --- | --- |
| Two opt-in test files named a private example project and contained maintainer-specific home-directory paths. | Names, paths, test names, output prefixes, and environment variables were generalized to synthetic/live-fixture placeholders. |
| A presentation test used a sample `<HOME_DIRECTORY>/example` path. | It now derives a private path from the test runner's home directory without embedding an absolute user path. |
| Runtime types generate UUIDs and Sandbox IDs. Three source literals are deterministic namespace/timeline constants, not real sessions. | Constants were retained because they are synthetic implementation values; public example reports use `<SANDBOX_ID>` and `<SNAPSHOT_ID>`. |

## Secrets, endpoints, and data

| Finding | Remediation |
| --- | --- |
| No API key, access token, password, private key, certificate, personal email, database content, runtime log, crash output, or embedded environment value was discovered. | No secret-value remediation required; scanning remains part of release verification. |
| Tests contain explicit dummy secret strings to verify presentation redaction and sensitive-file handling. | Retained as clearly synthetic test data; no real value is present. |
| Source contains public OpenAI and Anthropic API endpoint URLs and environment-variable names for optional user-supplied keys. | Retained as optional provider boundaries, documented in security/privacy limitations, and excluded from deterministic CI. These are vendor endpoints, not private production URLs. |

## Capability scope

| Finding | Remediation |
| --- | --- |
| The inherited live application composed older workspace mutation, shell, and connector executors even though the Phase 2D.0 Sandbox mutation allowlist was empty. | The public live composition now uses `PublicReleaseToolExecutor`, which permits only `ReadOnlyInspectionPolicy` commands. Prompt/context discovery advertises the same bounded list. Existing test coverage was extended without increasing the 450-test count. |
| Older mutation/command/connector implementation types remain in the completed source tree. | Kept to avoid silently deleting compatibility behavior; documented as dormant technical debt and excluded from the public live capability surface. |
| Phase 2D.1 operation names exist in policy models but the allowlist is empty. | Retained as fail-closed modeling; tests verify every writable operation is denied and reports state Phase 2D.1 was not started. |

## License

The maintainer selected the Mozilla Public License 2.0 for the final release gate. The repository-root `LICENSE` contains Mozilla's official, unmodified MPL 2.0 text; `Package.swift`, `README.md`, `NOTICE.md`, `CONTRIBUTING.md`, and the dependency inventory identify `MPL-2.0` consistently.

## Release-candidate verification — 2026-07-16

- Every candidate file was read successfully for SHA-256 hashing; no dataless file or read failure was found.
- Full deterministic suite: 450 tests executed, 0 failures, 2 explicit live-workspace tests skipped.
- Separate isolated Swift build: passed with Swift 6.2.4 using an external scratch directory.
- Synthetic demo runtime: 8 included files, 0 excluded files, hash and inode isolation passed, source unchanged, Sandbox destroyed, Phase 2D.1 not started.
- Named public mission-surface test: passed for read-only Legacy inspection, AI Agent integration assessment, the dedicated `SAFE_SANDBOX_ACCEPTANCE` route, the five-command read-only tool allowlist, and the empty Phase 2D.0 writable-operation allowlist.
- Secret/high-entropy key, personal email, personal path, private-project name, database/log, generated-artifact, and excluded-file scans: no releasable finding remained.
- Broader credential-assignment scanning found only explicit deterministic test fixtures (`test-key` and `test-anthropic`); no real credential-shaped value or sensitive file was present.
- URL review: only public OpenAI/Anthropic vendor endpoints and synthetic `.example`/`example.com` test URLs remained.
- UUID review: three deterministic namespace/timeline constants remained; no real task, session, snapshot, or Sandbox identifier was present.
- License integrity: the repository `LICENSE` byte-matched a fresh download of Mozilla's official MPL 2.0 plaintext; both files had SHA-256 `3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04`.
- Security reporting: `SECURITY.md` designates GitHub Private Vulnerability Reporting and prohibits public issues. The GitHub setting must be enabled when the repository exists and before release announcement.
- `.gitignore` behavior: 11 representative generated/sensitive paths ignored; `.env.example` and `README.md` remained visible.
- No Git add, commit, tag, remote creation, or push was performed.
