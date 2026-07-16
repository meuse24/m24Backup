# M24 Backup - Help and Information

Version: {{VERSION}}
Version date: {{BUILD_DATE}}

## User guide

This help covers backup, restore, and the most important technical details of
M24 Backup.

## Purpose

M24 Backup copies personal Windows folders to a USB flash drive, external
disk, or another selected drive. It is a continuously updated safety copy, not
a versioned archive with historical snapshots.

Supported standard folders:

- Desktop
- Documents
- Downloads
- Pictures
- Music
- Videos
- Favorites
- Saved Games
- Contacts

AppData, temporary files, and cache folders are intentionally excluded.

## Starting the application

Normally, start the app with `Bibliothekssicherung starten.vbs`. Use
`Bibliothekssicherung starten.bat` for diagnostics when a visible console
window is useful.

## Creating a backup

1. Select **Back up** at the top.
2. Connect a USB drive or external disk.
3. Wait until the drive appears in the list, or click **Refresh**.
4. Select the destination drive.
5. Select the folders to include.
6. Optionally add more folders.
7. Optionally adjust dry-run, safe eject, or checksum settings.
8. Click **Start backup**.
9. Wait for the completion message.

The backup folder and existing technical logs can be opened directly after
selecting a drive. The summary can be copied from its context menu. The drive
list updates automatically; a drive with an existing backup for this profile is
preferred. `F5` forces an immediate refresh. `F1` opens Help, `Ctrl+L` opens the
log, and `Ctrl+O` opens the backup folder. Never remove the destination drive
while an operation is running.

A star (`★`) marks the drive used for the last successful backup. The app
recognizes it by its volume identifier. Before backing up to a different drive,
the app asks for confirmation; the new drive is remembered only after a
successful run.

The app remembers selected standard and custom folders for the next start.
**History** lists the ten most recent logs. **Verify backup** reads every data
file completely and compares its SHA-256 checksum with `_Pruefsummen.tsv` to
detect unreadable, missing, or modified files. When the window is in the
background, Windows also displays a notification for completion, failure, or
cancellation.

The worker updates one checksum per file after a successful copy and before it
marks the backup successful. Entries are reused using relative path, size, and
the exact timestamp from the backup destination; new or changed files are read
again. Old entries remain in the manifest to match the no-delete strategy. For
an older backup without a manifest, **Verify backup** offers to record the
current contents as an initial baseline. This initial recording cannot detect
damage that already existed beforehand. Excluded temporary files are neither
backed up nor included in the manifest.

The **Checksums** option is enabled by default. If it is turned off, the backup
runs faster, but the manifest remains at its previous state. **Verify backup**
may then report missing or outdated checksum entries until another backup
finishes with checksums enabled.

The first backup run after the manifest is introduced reads the complete
existing destination data once more. Later runs only rehash files whose size or
exact destination timestamp changed. **Verify backup** still reads every file
completely because a reliable comparison requires the current contents. Use
**Cancel verification** to stop a running check. Cancelling an initial baseline
does not save an incomplete manifest.

Checksums detect accidental corruption and unexpected modifications. They are
not cryptographically signed, so an attacker with write access could alter both
the backup and its manifest consistently.

<a id="dry-run"></a>
## Simulate only: dry run

The **Simulate only (dry run)** option runs Robocopy with `/L`. The app creates
a normal log of planned copy operations, but does not copy user data and does
not update successful-backup metadata.

Use dry-run mode when you want to review what would be copied or overwritten
before taking any risk.

<a id="custom-folders"></a>
## Add custom folders

Use **Add folder** to include work folders outside the Windows standard
folders. The app rejects overlapping folders and reserved internal names.

Additional folders are stored under unique names in the backup destination.
The `_Ordner.json` file records their original paths so they can be offered
again during a later restore.

<a id="safe-eject"></a>
## Safely eject the drive

When **Safely eject drive after success** is enabled, the app attempts a
Windows eject after a successful real backup to a removable drive. The eject is
delayed briefly and retried if necessary so Windows can close remaining file
and process handles.

If automatic eject fails, the backup still remains successful. Remove the
drive manually through Windows.

<a id="backup-health"></a>
## Backup health indicator

The indicator next to the destination drive summarizes the latest successful
backup for the current computer and user:

- Green: current backup, at most 7 days old.
- Yellow: backup due soon, 8 to 14 days old.
- Red: no backup, failed backup, cancelled backup, or outdated backup.

Details include date, folder count, and duration when the metadata provides
enough information.

## Backup behavior

- New and changed files are copied.
- For source paths that still exist, the backed-up file version matches the
  current source state after a successful run: changed source files replace
  their existing copy in the backup even when their timestamp is older. Files
  deleted from the source remain in the backup.
- Files are never automatically deleted from the backup.
- Robocopy `/MIR` and `/PURGE` are not used.
- Open or locked files may be skipped.
- Notes and errors are written to the log.

## Disk space and FAT32

Before copying, the app estimates required disk space. If free space is not
enough, the operation is not started.

FAT32 cannot store a single file of 4 GB or larger. NTFS or exFAT is
recommended for backup drives. Formatting a drive deletes its existing data.

<a id="restore"></a>
## Restoring files

1. Connect the drive containing the backup.
2. Select **Restore**.
3. Select the backup drive.
4. Select the backup folders to restore.
5. Click **Review restore**.
6. Read the conflict preview.
7. Confirm only if the displayed changes are correct.

The preview shows missing local files, possible overwrites, protected newer
local files, data volume, and example paths. It also shows the backup's
integrity status: when the SHA-256 checksums were last fully verified, or
that this verification is still pending. Before an important restore, run
**Verify backup** first. No files are restored without explicit confirmation.

## Restore protection

- Newer local files remain protected by Robocopy `/XO`.
- Local files are never deleted.
- `/MIR` and `/PURGE` are not used.
- Backup metadata must match the current computer and user.
- Free space is checked separately for every affected local drive.

## Cancelling an operation

Use **Cancel backup** or **Cancel restore**. The running copy operation is
stopped immediately; the file being transferred at that moment may remain
incomplete at the destination. Files already copied completely remain in
place. After a cancellation, run the backup again or use **Verify backup**;
a cancelled run does not count as a successful backup.

## Backup location

Backups use this structure:

`<Drive>:\Bibliothekssicherung\<Computer>_<User>\`

The folder contains:

- `_Sicherungsinfo.txt`: identity and backup metadata.
- `_Ordner.json`: original paths for additional folders.
- `_logs\`: technical backup and restore logs.

## Logs

Backup logs use `robocopy_YYYYMMDD_HHMMSS.log`.
Restore logs use `restore_YYYYMMDD_HHMMSS.log`.

Robocopy exit codes 0 to 7 mean success or success with notes. Codes 8 and
above indicate copy errors.

## Common issues

| Problem | Recommendation |
| --- | --- |
| No drive visible | Connect the drive, wait briefly, or click **Refresh**. |
| Not enough space | Remove data from the destination or use a larger drive. |
| FAT32 warning | Use NTFS or exFAT for the backup drive. |
| File cannot be read | Check whether it is open in another program. |
| Folder missing in restore mode | Check `_Ordner.json` and whether the backup matches this profile. |

## Recommendations

- Back up regularly.
- Safely eject the backup drive after completion.
- Do not leave the backup drive permanently connected.
- Keep another copy of irreplaceable files.
- Occasionally test restoring a non-critical file.
- Review logs that contain errors.

## Technical section

The following sections support troubleshooting and review.

## Components

- `Bibliothekssicherung-GUI.ps1`: Windows Forms UI, language, mode, drive and
  folder selection, status, previews, cancellation, and help.
- `Bibliothekssicherung.ps1`: worker for backup and restore, validation,
  preflight checks, and Robocopy execution.
- `M24Backup.Shared.ps1`: shared helpers for reserved names and nested paths.

## Tech stack

- Windows PowerShell 5.1
- .NET Framework with `System.Windows.Forms` and `System.Drawing`
- Robocopy
- CIM/WMI `Win32_LogicalDisk`
- `Shell.Application` COM and `Win32_Volume` for optional eject
- JSON for structured selection, preview, and result data

## Process architecture

The GUI starts a separate PowerShell worker. Status, previews, approvals, and
cancellation signals are exchanged through temporary files so the UI remains
responsive.

## Inter-process communication

The GUI passes selected folders in a temporary JSON file. The worker writes
status and result files atomically. The GUI polls those files at short
intervals.

## Preflight and conflict detection

Before copying, the worker checks folders, free space, FAT32 limits, and the
restore conflict preview. Warnings must be confirmed before data is written.

## Robocopy parameters

| Parameter | Meaning |
| --- | --- |
| `/E` | Copy subfolders, including empty folders. |
| `/XJ` | Do not follow junctions, preventing loops. |
| `/FFT` | Use two-second timestamp tolerance for external file systems. |
| `/XO` | Restore only: do not replace newer local files with older backup files. `/XO` is not used for backups so that changed source files with older timestamps are still backed up. |
| `/MT:<Threads>` | Use multiple copy threads. |
| `/R:1` | Retry once on errors. |
| `/W:3` | Wait three seconds between retries. |
| `/COPY:DAT` | Copy data, attributes, and timestamps, but not NTFS ACLs. |
| `/DCOPY:DAT` | Preserve directory data, attributes, and timestamps. |
| `/NP` | Do not write percentage progress to the Robocopy log. |
| `/UNILOG+` | Append Unicode output to the log file. |
| `/NFL` / `/NDL` | Reduce file and directory listings during normal backups. |
| `/XF` | Exclude internal metadata and system files. |
| `/L` | Dry-run: list only, do not copy. |

During dry-run, `/NFL` and `/NDL` are intentionally omitted so the log shows
the planned files and folders. `/MIR` and `/PURGE` are intentionally never
used.

## Limitations

- No Volume Shadow Copy is created; open or locked files may be skipped.
- This is not a complete Windows system image.
- Applications, AppData, and system settings are not fully backed up.
- Historical file versioning is not provided.
- Library folders redirected to network shares without drive letters are not
  supported.
- Hardware damage can still cause read or write errors.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Operation completed successfully. |
| `1` | Interactive operation declined before starting. |
| `8` and above | Robocopy reported at least one copy error. |
| `10` | Validation, preflight, approval, or general script error. |
| `20` | Operation was cancelled by the user or GUI. |

Because the raw Robocopy value is returned unchanged, code `10` can also come
from Robocopy. The result file and log show which phase produced the error.

## Privacy and safety

The app does not send data to external services. Settings are stored locally in
the user profile. Backup data is not encrypted by the app; protect the drive
accordingly.
