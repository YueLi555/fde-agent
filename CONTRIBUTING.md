# Contributing

Thank you for helping improve FDE Agent. Keep contributions within the published release boundary: read-only assessment, evidence quality, Safe Sandbox safety, documentation, and deterministic verification.

## Before contributing

FDE Agent is licensed under the Mozilla Public License 2.0 (`MPL-2.0`). By submitting a source contribution, you agree to license it under MPL-2.0 unless the contribution clearly identifies compatible third-party material and its governing terms. Issue reports and review feedback must use only synthetic, non-confidential examples.

## Development workflow

1. Start from a clean checkout on macOS 14 or later with Swift 6.
2. Do not use a real customer or private Legacy repository in tests or examples.
3. Keep tests deterministic and offline. Live-workspace tests must remain explicit opt-ins.
4. Use isolated SwiftPM scratch paths and do not commit generated products.
5. Run `swift build --scratch-path .build-release`.
6. Run `swift test --scratch-path .build-tests`.
7. Scan the change for secrets, personal paths, real identifiers, databases, and logs.

## Change requirements

- Preserve Legacy read-only behavior and Legacy/Agent workspace separation.
- Add evidence for public claims and state unverified dimensions explicitly.
- Treat configuration presence as static evidence, not runtime proof.
- Do not enable Phase 2D.1, mutation, command execution, Git operations, deployment, or credential/production access in a v0.1.x change.
- Add or update deterministic tests without introducing live dependencies.
- Update the changelog and relevant safety documentation.

## Reports and pull requests

Describe the observed problem, the bounded change, safety impact, verification performed, and any remaining unknowns. Use placeholders such as `<LEGACY_ROOT>`, `<SANDBOX_ID>`, and `<SNAPSHOT_ID>`. Follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) and report security issues through [SECURITY.md](SECURITY.md).
