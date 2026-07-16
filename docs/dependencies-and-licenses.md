# Dependencies and Licenses

## Swift Package graph

`Package.swift` declares one executable product, one project-owned C target (`SQLiteShim`), one Swift executable target, and one test target. It declares no remote or local package dependencies. No `Package.resolved` is needed for the current graph.

## Shipped/runtime dependencies

| Dependency | How used | Source/vendoring | License or governing terms | Release concern |
| --- | --- | --- | --- | --- |
| Swift standard library and SwiftPM | Language runtime, build, and tests | Toolchain; not vendored | Apache-2.0 with Runtime Library Exception | Preserve upstream notices when redistributing toolchain components; none are bundled here. |
| macOS SDK frameworks | Foundation, SwiftUI, AppKit, Security, CryptoKit, Combine, OSLog | Operating system/SDK; not vendored | Apple SDK/platform terms | Source release does not redistribute SDK binaries. |
| `libsqlite3` | Local persistence through `SQLiteShim` | Linked operating-system library; no SQLite source copied | SQLite public domain dedication | No attribution required; listed for transparency. |
| `actions/checkout@v6` | CI checkout | Downloaded by GitHub Actions; not vendored | MIT | Workflow supply-chain dependency; pinning by full commit SHA can be considered before publication. |

## Copied code review

No third-party source headers, copied implementation notices, vendored package directory, binary framework, generated license bundle, or required attribution block was discovered in the candidate. Project source and tests do not include a third-party copyright header.

## Project license

FDE Agent is licensed under the Mozilla Public License 2.0 (`MPL-2.0`). The repository-root `LICENSE` contains Mozilla's official, unmodified MPL 2.0 text, and `Package.swift` carries `SPDX-License-Identifier: MPL-2.0`. `NOTICE.md` records non-vendored runtime and CI dependencies; no reviewed dependency prevents distribution of the project source under MPL-2.0.
