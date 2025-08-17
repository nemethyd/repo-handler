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

## Prioritized Backlog

Ordered by: (1) Safety/Correctness, (2) Functional integrity, (3) Performance, (4) Testability, (5) UX/Outputs, (6) Developer ergonomics, (7) Deferred refactors / cosmetic cleanup.

| Priority | ID | Area | Description | Status | Rationale |
|----------|----|------|-------------|--------|-----------|
| 1 | 7  | Performance | Index repo packages for O(1) lookups (map/set) | TODO | Cuts repeated grep scans in determine_repo_source |
| 2 | 14 | Version Compare | Add bats tests for `version_is_newer` edge cases | TODO | Locks correctness before further logic changes |
| 3 | 9  | Testing | `--self-test` mode (tool presence, perms) returning JSON/exit codes | TODO | Fast environment validation & CI hook |
| 4 | 15 | Hook Names | Namespace test hooks (`MYREPO_TEST_*`) centrally | TODO | Prevents collisions; improves clarity for tests |
| 5 | 12 | Output | `--json-summary` machine-readable results alongside table | TODO | Enables integration / automation |
| 6 | 18 | Output | No-emoji / plain mode (map emojis to INFO/WARN/ERR/OK) | TODO | Terminal compatibility / log parsers |
| 7 | 11 | Docs | Tunables reference + initial CHANGELOG.md | TODO | Documentation debt reduction; supports users |
| 8 | 13 | Refactor | Split into modular libs (`lib_*`) once stable | LATER | Defer until feature churn settles |
| 9 | 16 | Cleanup | Remove legacy historical comments | LATER | Cosmetic; safe last |
| 3 | 7  | Performance | Index repo packages for O(1) lookups (map/set) | TODO | Cuts repeated grep scans in determine_repo_source |
| 4 | 14 | Version Compare | Add bats tests for `version_is_newer` edge cases | TODO | Locks correctness before further logic changes |
| 5 | 9  | Testing | `--self-test` mode (tool presence, perms) returning JSON/exit codes | TODO | Fast environment validation & CI hook |
| 6 | 15 | Hook Names | Namespace test hooks (`MYREPO_TEST_*`) centrally | TODO | Prevents collisions; improves clarity for tests |
| 7 | 12 | Output | `--json-summary` machine-readable results alongside table | TODO | Enables integration / automation |
| 8 | 18 | Output | No-emoji / plain mode (map emojis to INFO/WARN/ERR/OK) | TODO | Terminal compatibility / log parsers |
| 9 | 11 | Docs | Tunables reference + initial CHANGELOG.md | TODO | Documentation debt reduction; supports users |
|10 | 13 | Refactor | Split into modular libs (`lib_*`) once stable | LATER | Defer until feature churn settles |
|11 | 16 | Cleanup | Remove legacy historical comments | LATER | Cosmetic; safe last |

## Notes on Backlog Ordering

1. With safety (Point 10) and manual metadata dedupe (Point 8) completed, performance indexing (Point 7) now leads.
2. Version comparison tests (Point 14) next to harden correctness before adding new behaviors.
3. Self-test mode (Point 9) improves diagnosability before expanding outputs.
4. Output enhancements (Points 12, 18) follow a stable core for predictable schemas.
5. Documentation (Point 11) after feature shape solidifies.
6. Refactor and cosmetic cleanup (Points 13, 16) deferred until churn subsides.

## Conventions

* Function Ordering: Prefer logical lifecycle grouping (config → environment checks → helpers → processing → metadata → sync/reporting → validation → main) over strict alphabetical.
* Logging: Standardized emoji usage (enforced in log()): `📘` info, `⚠️` warning, `❌` error, `⏳` progress, `✅` success (with planned plain mode fallback).
* Test Hooks: All future hooks prefixed with `MYREPO_TEST_`.

---
Generated and maintained by development workflow. Update this file when actions are completed.
