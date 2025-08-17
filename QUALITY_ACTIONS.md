### Quality & Maintenance Roadmap

This document tracks identified quality, consistency, and maintainability improvements for `myrepo.sh`.

Last Reviewed: 2025-08-17

## Completed Items

| ID | Area | Summary |
|----|------|---------|
| 1 | Structure | Restored readable `batch_download_packages` formatting |
| 2 | Structure | Decomposed monolith into focused functions |
| 3 | Logging | Centralized verbosity filtering / standardized levels |
| 4 | Fallback Logic | Adaptive shrinking + regrow implemented |
| 5 | Counters | Negative counter guards + clamp logic |
| 6 | Helpers | Added helper trio (manual repo / epoch / dir ensure) |
| 8 | Metadata | Prevented double metadata updates for manual repos |
| 17 | Emojis | Standardized emoji set + conditional prefixing |
| 10 | Safety | Bash version guard + safe_rm_rf path confinement |
| 7 | Performance | Indexed repo packages for O(1) lookups |
| 14 | Version Compare | Added tests for `version_is_newer` edge cases |
| 9 | Testing | Implemented `--self-test` JSON environment diagnostics |
| 15 | Hook Names | Namespaced test hooks to `MYREPO_TEST_*` with backward compat |
| 12 | Output | Implemented `--json-summary` machine-readable run results |

## Prioritized Backlog

Ordered by: (1) Safety/Correctness, (2) Functional integrity, (3) Performance, (4) Testability, (5) UX/Outputs, (6) Developer ergonomics, (7) Deferred refactors / cosmetic cleanup.

| Priority | ID | Area | Description | Status | Rationale |
|----------|----|------|-------------|--------|-----------|
| 2 | 18 | Output | No-emoji / plain mode (map emojis to INFO/WARN/ERR/OK) | DONE | Implemented --plain / --no-emoji mode |
| 3 | 11 | Docs | Tunables reference + initial CHANGELOG.md | TODO | Documentation debt reduction; supports users |
| 4 | 13 | Refactor | Split into modular libs (`lib_*`) once stable | LATER | Defer until feature churn settles |
| 5 | 16 | Cleanup | Remove legacy historical comments | LATER | Cosmetic; safe last |

## Notes on Backlog Ordering

1. With performance indexing (Point 7) now done, version comparison tests (Point 14) lead to lock correctness.
2. Self-test mode (Point 9) improves diagnosability before expanding outputs.
3. Output enhancements (Points 12, 18) follow a stable core for predictable schemas.
4. Documentation (Point 11) after feature shape solidifies.
5. Refactor and cosmetic cleanup (Points 13, 16) deferred until churn subsides.

## Conventions

* Function Ordering: Prefer logical lifecycle grouping (config → environment checks → helpers → processing → metadata → sync/reporting → validation → main) over strict alphabetical.
* Logging: Standardized emoji usage (enforced in log()): `📘` info, `⚠️` warning, `❌` error, `⏳` progress, `✅` success (with planned plain mode fallback).
* Test Hooks: All future hooks prefixed with `MYREPO_TEST_`.

---
Generated and maintained by development workflow. Update this file when actions are completed.
