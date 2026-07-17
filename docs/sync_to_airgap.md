# Remote Sync (Built Into myrepo.sh)

## Status

sync_to_airgap.sh has been retired.
Remote synchronization is now implemented directly in myrepo.sh via SYNC_MODE="remote".

This script mirrors selected Oracle Linux repositories from the shared staging area to the air-gapped Windows host over SSH/rsync. It replaces the older robocopy-based process that relied on manual edits to `syncrepo.ps1`.

## Summary

- Reads mapping data from `~/shared-repo/syncrepo.ps1`
- Uses rsync over SSH to push staged repositories to `mgmt1`
- Keeps partially transferred files via `--partial` so VPN drops can resume cleanly
- Handles Windows destination paths by translating them to `/cygdrive` syntax
- Offers a `--dry-run` option to verify actions without modifying the remote host
- Displays total transfer progress, throughput, and ETA via `--info=progress2`

## Prerequisites

- The staging tree is populated under `~/shared-repo/ol9_repos`
5. Run rsync with `--archive --compress --delete --partial --info=progress2 --human-readable` to mirror the staging content, retain partial transfers, and show overall progress.
- SSH key-based access to `mgmt1` as `bwk.nemethy.daniel`
- Rsync 3.x and Bash (tested on Oracle Linux 9)
- A PowerShell mapping file at `~/shared-repo/syncrepo.ps1` with entries such as:
 - `--partial` leaves any interrupted files on the remote host, allowing the next run to resume instead of restarting large payloads.
 - `--info=progress2` and `--human-readable` improve visibility compared with legacy robocopy logs, showing percentages, ETA, and scaled sizes.
  ```text
  "ol9_baseos_latest" = "baseos\\latest\\x86_64"
  "ol9_edge" = "edge\\x86_64"
  ```

## Usage

```bash
./myrepo.sh --sync-only --sync-mode remote
./myrepo.sh --sync-only --sync-mode remote --dry-run
```

### Dry run mode

When `--dry-run` is supplied the script passes the same flag to rsync. You receive the full rsync report (files that would transfer or be deleted) without touching the remote filesystem. Use this before every live push when the staging content has changed significantly.

## Process overview

1. Validate the mapping file and staging directory.
2. Parse each mapping entry (source fragment -> Windows destination fragment).
3. Build the local source path (e.g. `~/shared-repo/ol9_repos/ol9_edge/`).
4. Convert the Windows path (`C:/repo/OracleLinux/OL9/edge/x86_64`) to `/cygdrive/c/...` for rsync.
5. Run rsync with `--archive --compress --delete --partial --info=progress2 --human-readable` to mirror the staging content, resume partial transfers, and show overall progress.

## Operational notes

- The script stops on the first error (`set -e`), so a failure prevents partial updates.
- Destination logging shows both the original Windows-style path and the `/cygdrive` path passed to rsync. This helps when comparing with old robocopy logs.
- `--partial` leaves any interrupted files on the remote host, allowing the next run to resume instead of restarting large payloads.
- `--info=progress2` together with `--human-readable` surfaces running percentages, ETA, and bandwidth similar to robocopy's progress display.
- Remote deletions follow the staging tree. Removing a package or repodata locally removes it from the air-gapped host on the next run.
- If you need to push to a different host or drive, adjust `REMOTE_HOST`, `REMOTE_USER`, or `REMOTE_BASE_PATH_WIN` near the top of the script.

## Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| `rsync ... change_dir ... No such file or directory` | Destination path was not converted to `/cygdrive/...` | Ensure you are on the latest script revision or re-run after verifying `REMOTE_BASE_PATH_WIN` |
| `Permission denied` | Missing SSH key or wrong user | Confirm SSH access to `mgmt1` as `bwk.nemethy.daniel` |
| Staging directory warning | Missing source repository | Populate the repo under `~/shared-repo/ol9_repos/<name>` |

## Related files

- `myrepo.sh` – main script with built-in local/remote sync
- `shared-repo/syncrepo.ps1` – source/destination mappings used by both PowerShell and rsync workflows
