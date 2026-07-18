# Testable Legacy Order Support Fixture

This sanitized fixture models a deterministic, read-only customer-support order lookup.

- `src/auth.ts` establishes authentication and support-role permission boundaries.
- `src/orders.ts` exposes the existing read path. It filters by a caller-supplied customer ID but does not bind that record ID to the authenticated principal.
- The existing order response includes `customerID`, which is unnecessary at the future Agent-facing boundary.
- `src/audit.ts` establishes the non-sensitive `orders.read` audit contract.
- No write-capable order operation exists, and outbound actions remain disabled.
- `tests/` and `vitest.config.ts` establish the checked-in Vitest convention and location.

All identifiers are synthetic fixture values. The project has no network access, credentials, production configuration, or package-install step.
