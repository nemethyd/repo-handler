### Completed
* Point 1: Batch download readability & structure (DONE)
* Point 2: Decompose process_packages into focused functions (DONE)
* Point 3: Centralized threshold-based logging (DONE)
### In Progress / Next
* Point 4: Adaptive fallback batch shrinking (DONE)
Recent: Point 4 adaptive fallback implemented (shrinks & grows batches); version bumped to v2.3.26.
# Quality & Maintenance Roadmap

This document tracks identified quality, consistency, and maintainability improvements for `myrepo.sh`.

Last Reviewed: 2025-08-16

## Action List (Roadmap)

| ID | Area | Description | Status | Notes |
|----|------|-------------|--------|-------|
| 1 | Structure | Restore readable formatting for `batch_download_packages` and decide on function ordering approach | DONE | Readability restored (no logic change) |
| 2 | Structure | Decide: full alphabetical ordering vs logical grouping; refactor oversized `process_packages` into smaller functions | DONE | Extracted: gather_installed_packages, filter_and_prepare_packages, precreate_repository_directories, classify_and_queue_packages, perform_batched_downloads, finalize_and_report; placeholders removed |
| 3 | Logging | Centralize verbosity filtering inside `log()` to reduce repeated `[[ $DEBUG_LEVEL -ge N ]]` checks | DONE | Unified log(), added level constants, removed TRACE (max=3) |
| 4 | Fallback Logic | Clarify or implement true shrinking fallback in `batch_download_packages` (`fallback_batch_size` currently never changes) | DONE | Adaptive halve-to-individual with cautious regrow implemented |
| 5 | Counters | Guard against negative decrements for stats when skipping manual repos; fix off-by-one for `MAX_PACKAGES` (use `>=`) | DONE | Added clamp helper + applied at manual repo decrements |
| 6 | Helpers | Add `is_manual_repo`, `ensure_normalized_epoch`, `ensure_repo_directory` helpers and reuse | TODO | Reduces duplication |
| 7 | Performance | Pre-index `available_repo_packages` into associative map for O(1) lookups in `determine_repo_source` | TODO | Memory trade-off acceptable |
| 8 | Metadata | Avoid double metadata updates for manual repos (skip in main loop if handled separately) | TODO | Add guard in `update_all_repository_metadata` |
| 9 | Testing | Add `--self-test` mode (checks tools: dnf, rpm, createrepo_c, permissions, bash version) | TODO | Outputs JSON/exit codes |
|10 | Safety | Add Bash version guard (>=4), path safety checks before destructive `rm -rf` | TODO | Early exit with message |
|11 | Docs | Add full list of tunables + defaults to README; start `CHANGELOG.md` | TODO | Auto-update on version bump |
|12 | Output | Optional `--json-summary` for machine parsing of results | TODO | Provide table + JSON simultaneously |
|13 | Refactor | Split monolithic script into modules once churn lowers (e.g. `lib_download.sh`, `lib_metadata.sh`) | LATER | After core refactors |
|14 | Version Compare | Add unit tests (bats) for `version_is_newer` edge cases | TODO | Include epoch handling |
|15 | Hook Names | Namespace test hooks (`MYREPO_TEST_*`) and centralize gating | TODO | Improves clarity |
|16 | Cleanup | Remove legacy comments referencing "original script" once stable | LATER | Cosmetic |
|17 | Emojis | Standardize a minimal consistent emoji set (info, warn, error, progress, success) | DONE | Implemented in log(): 📘 info, ⚠️ warn, ❌ error, ⏳ progress, ✅ success |

## Recently Completed

* Point 1: Restored readable multi-line implementation for `batch_download_packages` (previously compressed for alphabetical reorder attempt).
* Point 2: Broke down `process_packages` into six focused functions (gather + filter + precreate + classify + batched downloads + finalize). Behavioral parity maintained; eliminated obsolete placeholder comments.

## Next Recommended Steps

1. Implement helper functions (Point 6) to reduce repeated inline logic (repo dir creation, epoch normalization, manual repo checks).
2. Centralize logging severity filtering (Point 3) to simplify subsequent edits.
3. Address fallback batch size semantics (Point 4) to align behavior with comments.
4. Add defensive counter guards (Point 5) now that refactor stabilized.

## Conventions To Establish

* Function Ordering: Prefer logical lifecycle grouping (config → environment checks → helpers → processing → metadata → sync/reporting → validation → main) over strict alphabetical.
* Logging: Standardized emoji usage (enforced in log()): `📘` info, `⚠️` warning, `❌` error, `⏳` progress, `✅` success.
* Test Hooks: All future hooks prefixed with `MYREPO_TEST_`.

---
Generated and maintained by development workflow. Update this file when actions are completed.
