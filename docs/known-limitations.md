# Known Limitations

- This is a macOS 14+ SwiftUI application; other platforms are not supported.
- No independent security audit, binary signing, notarization, reproducible-build guarantee, or production deployment verification is claimed.
- The Legacy assessment is static. It does not install dependencies, build, run tests, execute the Legacy application, inspect deployment, or access production.
- A directly read route or configuration may be incomplete, dead code, or ineffective at runtime.
- Model output remains nondeterministic when an external provider is selected and can be wrong despite evidence controls.
- Optional model providers may transmit selected context to vendor endpoints. The deterministic local fallback requires no key or network.
- The exclusion policy cannot detect every secret embedded under an ordinary filename; users must review the selected source scope.
- Source-integrity checks are snapshot based and do not lock the Legacy filesystem against concurrent external writers.
- Inode/device checks and dataless-file detection are verified on supported macOS filesystems, not every filesystem implementation.
- Local SQLite runtime data is not encrypted by this package; OS account and filesystem protections remain important.
- Earlier internal workspace mutation, shell, AppleScript, connector, and cloud-execution types remain in the completed source tree for compatibility tests. The v0.1.0 live composition does not use or advertise them, but this dormant surface increases review burden and should be isolated or removed in a future cleanup.
- The source includes optional public OpenAI and Anthropic endpoint integrations. No keys are shipped, CI does not use them, and their presence is not evidence of production access.
- The two live-workspace acceptance tests are skipped by default and must never be pointed at a private project for public release verification.
- The recorded native UI acceptance and 84-file real acceptance are prior completion evidence; they do not make the synthetic demo or future environments equivalent.
- Phase 2D.1, Candidate Patch generation, generated tests, Sandbox mutation, Git workflows, deployment, and production/credential access are unavailable.
