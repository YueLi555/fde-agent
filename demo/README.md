# Synthetic Demo

`SyntheticLegacy` is a deliberately small, fictional order-support service. It contains no real repository history, customer data, credentials, identifiers, deployment configuration, or external dependency.

The fixture supports a public walkthrough of:

1. Selecting `demo/SyntheticLegacy` as `<LEGACY_ROOT>`.
2. Performing read-only discovery and directly reading only relevant files.
3. Producing the sanitized [example assessment](example-report.md).
4. Calculating `<SNAPSHOT_ID>` for the eight included fixture files.
5. Creating `<SANDBOX_ROOT>/<SANDBOX_ID>` outside the fixture.
6. Verifying SHA-256 equality, independent inode/device identity, containment, sensitive exclusions, and unchanged source.
7. Destroying only the Sandbox and confirming the original fixture remains byte-for-byte unchanged.

The deterministic test `SafeSandboxProductRuntimeIntegrationTests.testRealRuntimeRunsManifestBackedLifecycleAndDestroysSandbox` performs steps 4–7 using the production runtime and this checked-in fixture. It also asserts 8 included files, 0 excluded files, no active Sandbox after completion, and Phase 2D.1 not started.

The fixture intentionally contains no excluded entry. Sensitive-file exclusion is verified elsewhere by deterministic tests that create disposable `.env`, key, certificate, version-control, dependency, and build-artifact examples.

`TestableLegacy` is a separate sanitized TypeScript/Vitest fixture with a confirmed test dependency, script, configuration, test location, and representative test convention. Phase 2D.2B may generate virtual review artifacts from its evidence but never materializes generated files into the fixture or Sandbox. `SyntheticLegacy` remains the negative fixture for missing framework and test-location evidence.
