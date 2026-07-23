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

Only one instance of the app runs per Windows user session. A second
start shows a notice and exits without changing anything.

## Creating a backup

1. Select **Back up** at the top.
2. Connect a USB drive or external disk.
3. Wait until the drive appears in the list, or click **Refresh**.
4. Select the destination drive.
5. Select the folders to include.
6. Optionally add more folders.
7. Optionally adjust **Dry run**, safe eject, checksums, **Fast mode (no
   preflight checks)**, or the **Remind me at Windows sign-in when a backup is
   due** setting.
8. Click **Start backup**.
9. Wait for the completion message.

After a short background scan, the folder list shows each folder's file count
and occupied space. It displays **calculating …** while measuring and **empty**
for empty folders. The summary totals only selected folders and displays
**calculating total size …** until every required result is available. Backup
mode measures the source; restore mode measures the corresponding backup
folder. Results remain cached for the session. Child junctions are skipped like
Robocopy `/XJ`, directory symlinks are followed, and inaccessible subfolders
are ignored, so the figures are estimates.

Every measurement ends with a result or an **unavailable** marker. An
unexpectedly interrupted job is retried once and cannot leave the total stuck
at **calculating total size …** indefinitely. If individual values remain
unavailable, the summary displays a clearly marked partial total. Technical
details are written to the local GUI diagnostic log.

The backup folder and existing technical logs can be opened directly after
selecting a drive. The summary can be copied from its context menu. The drive
list updates automatically; a drive with an existing backup for this profile is
preferred. `F5` forces an immediate refresh. `F1` opens Help, `Ctrl+L` opens the
log, and `Ctrl+O` opens the backup folder. Never remove the destination drive
while an operation is running.

A star (`★`) marks the drive used for the last successful backup. The app
recognizes it using a layered fingerprint of volume and disk identifiers, size,
and file system. Ambiguous matches are never accepted automatically. Before backing up to a different drive,
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
does not save an incomplete manifest. Every initialization or verification also
writes a persistent log, including integrity-error, cancellation, and
unexpected-failure outcomes. **Log** opens the newest run, while **History**
labels these entries as **Verification**.

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

<a id="super-fast"></a>
## Fast mode: maximum speed without checks

The **Fast mode (no preflight checks)** option — called **Super fast** in
earlier versions — copies as fast as possible by skipping every time-consuming
check:

- no file preflight, and therefore no file-based disk-space estimate and no
  advance check for files of 4 GB or larger on FAT32,
- no update of the SHA-256 checksum manifest,
- no BitLocker status query,
- no Robocopy copy retries (`/R:0`) and 32 parallel copy threads by default.

Robocopy alone decides which files need to be copied. The protective limits of
the backup remain unchanged: nothing is deleted from the destination, and the
drive and path validation, lock file, metadata, and log stay active.

The price of speed: a full destination drive or an oversized file on FAT32 only
surfaces while copying, and locked files are skipped immediately instead of
being retried. The checksum manifest remains at its previous state; **Verify
backup** may then report missing or outdated entries until another backup
finishes with checksums enabled.

The option applies to backups only, cannot be combined with **Simulate only
(dry run)**, and is deliberately turned off again every time the app starts. On
very slow USB 2 flash drives, many parallel threads can be counterproductive;
the count can be adjusted with `-Threads` on the command line.

<a id="custom-folders"></a>
## Add custom folders

Use **Add folder** to include work folders outside the Windows standard
folders. The app rejects overlapping folders and reserved internal names.

Before a backup starts, the app also compares all currently selected standard
and custom source folders. Identical paths or a folder nested inside another
selected folder are rejected to prevent duplicate backups. Clear either entry
shown in the conflict message. This source-overlap check applies to backup only
and does not block restore.

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

## Backup reminder at Windows startup

The **Remind me at Windows sign-in when a backup is due** setting is enabled by
default and displays a notification at
sign-in when the last successful backup made through the app is at least 14 days
old, or when no backup has been made yet. It stays silent
while the backup is current; clicking the notification opens Library Backup.

No background service or administrator rights are required. Windows only starts
a short hidden check for the current user account. Clear the checkbox at any
time to disable the feature, or disable **M24Backup** under **Startup apps** in
Task Manager. Focus Assist or disabled Windows notifications may suppress it.

<a id="delete-backup"></a>
## Deleting a backup

Use **Delete backup** to completely remove the current computer and user's
backup from the selected drive. This action does not delete the drive or
backups belonging to other computers or users.

Before deletion, the app displays the full path, computer, user, latest backup
result, included folders, latest checksum verification, file and folder count,
and occupied space. Two confirmations are then required:

1. Explicitly confirm the displayed backup information.
2. Enter the displayed backup name `<Computer>_<User>` exactly.

Only then are this profile backup's user data, metadata, checksums, and logs
deleted permanently. This action cannot be undone. The feature is disabled
while a backup, restore, or verification is running. Missing metadata or
metadata that does not match the current profile also prevents deletion.

Older backups may contain files or folders with reserved Windows device names
such as `NUL`. The app traverses and removes them through extended Windows
paths. If Windows still cannot delete such an artifact, all other backup
contents continue to be removed and the remaining artifact is reported
explicitly.

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
4. Under **Backup**, select the desired discovered backup.
5. Select **Restore to my user profile** or **Copy to another folder**. For
   the second option, choose a destination folder.
6. Select the backup folders to restore.
7. Click **Review restore** and confirm the preview.

A complete backup from another computer or user can be restored directly to
the current user profile. Known Windows folders are automatically mapped to
the current library paths. Additional folders from a foreign backup are
collected below `Documents\Restored folders\<backup name>`. For the current
profile's own backup, the stored original paths of additional folders continue
to be used.

Incomplete backups or backups with unreadable metadata can only be copied to a
separate folder. **Open backup folder** remains available for these backups.

The preview shows missing local files, possible overwrites, protected newer
local files, data volume, and example paths. It also shows the backup's
integrity status. If a manifest exists but has not been fully verified since the
latest backup, the GUI verifies it automatically before the first copy. A failed
or cancelled verification blocks restore. If no manifest exists, no later scan
can prove the original contents; the GUI therefore requires a second explicit
risk confirmation. No files are restored without explicit confirmation.

## Restore protection

- Newer local files remain protected by Robocopy `/XO`.
- Local files are never deleted.
- `/MIR` and `/PURGE` are not used.
- The backup source must be a safely validated direct child of the backup
  inventory root. A different computer or user identity is shown clearly when
  restoring into the current profile.
- Free space is checked separately for every affected local drive.

## Cancelling an operation

Use **Cancel backup** or **Cancel restore**. The running copy operation is
stopped immediately; the file being transferred at that moment may remain
incomplete at the destination. Files already copied completely remain in
place. After a cancellation, run the backup again or use **Verify backup**;
a cancelled run does not count as a successful backup.

If the application window ends unexpectedly during a running operation
(for example through sign-out or a crash), the background worker stops
itself safely — using the same controlled path as a button cancellation.
Such a run also does not count as a successful backup.

## Backup location

Backups use this structure:

`<Drive>:\Bibliothekssicherung\<Computer>_<User>\`

The folder contains:

- `_Sicherungsinfo.txt`: identity and backup metadata.
- `_Ordner.json`: original paths for additional folders.
- `_Pruefsummen.tsv`: SHA-256 checksums for backed-up files.
- `_logs\`: technical backup, restore, and verification logs.

## Logs

Backup logs use `robocopy_YYYYMMDD_HHMMSS.log`.
Restore logs use `restore_YYYYMMDD_HHMMSS.log`.
Verification logs use `verify_YYYYMMDD_HHMMSS_PID_ID.log`. They record the
backup path, verification type, SHA-256 algorithm, start and finish time,
duration, checked files and bytes, outcome, and available error details.
Cancelled and failed verifications are logged as well.

Robocopy exit codes 0 to 7 mean success or success with notes. Codes 8 and
above indicate copy errors.

### Local GUI diagnostic log

Failures of the graphical interface itself (for example a worker process
that could not be started) are additionally recorded locally at:

`%LOCALAPPDATA%\M24Backup\Logs\gui.log`

This diagnostic log is separate from the backup and restore logs in the
`_logs\` folder on the backup drive and remains available even when no
drive is connected. It rotates automatically (`gui.1.log` through
`gui.4.log`) and uses about 10 MB in total; individual unusually large
entries may slightly exceed this approximate target. Entries may contain
local file paths and technical error details; they exist solely for
troubleshooting in support cases.

## Common issues

| Problem | Recommendation |
| --- | --- |
| No drive visible | Connect the drive, wait briefly, or click **Refresh**. |
| Not enough space | Remove data from the destination or use a larger drive. |
| FAT32 warning | Use NTFS or exFAT for the backup drive. |
| File cannot be read | Check whether it is open in another program. |
| Folder missing in restore mode | Check whether the folder exists in the selected backup. Additional folders without readable metadata can be copied to a separate folder. |

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

<a id="command-line"></a>
## Running directly without the GUI

For scripting, diagnostics, and manually controlled runs, start the
`Bibliothekssicherung.ps1` worker directly in Windows PowerShell 5.1. Without
`-Silent`, it writes status information to the console and asks for required
confirmations.

Examples:

- Normal backup to `G:`: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Bibliothekssicherung.ps1" -Mode Backup -UsbDrive G:`
- Fast-mode backup: `.\Bibliothekssicherung.ps1 -Mode Backup -UsbDrive G: -SuperFast`
- Fast mode with 16 threads: `.\Bibliothekssicherung.ps1 -Mode Backup -UsbDrive G: -SuperFast -Threads 16`
- Simulation only: `.\Bibliothekssicherung.ps1 -Mode Backup -UsbDrive G: -DryRun`
- Without updating the manifest: `.\Bibliothekssicherung.ps1 -Mode Backup -UsbDrive G: -SkipChecksums`
- Selected folders only: `.\Bibliothekssicherung.ps1 -Mode Backup -UsbDrive G: -SelectedFolders "Desktop|Dokumente|Bilder"`
- Restore: `.\Bibliothekssicherung.ps1 -Mode Restore -UsbDrive G:`

### Public worker parameters

| Parameter | Meaning |
| --- | --- |
| `-Mode <Backup or Restore>` | Select the operation; the default is `Backup`. |
| `-UsbDrive G:` | Backup destination or restore source. Values such as `G`, `G:`, and `G:\` are accepted. When omitted, the interactive worker offers suitable drives for selection. |
| `-Silent` | Suppress drive selection and normal prompts. A silent backup requires the GUI approval files if scan warnings occur; a silent restore always requires an approval channel. Do not use it for a normal direct restore. |
| `-SelectedFolders <list>` | Process only canonical folder names separated by a pipe character. Standard names are `Desktop`, `Dokumente`, `Downloads`, `Bilder`, `Musik`, `Videos`, `Favoriten`, `Gespeicherte Spiele`, and `Kontakte`. Stored canonical names remain language-independent even though the GUI translates their display labels. |
| `-SelectedFoldersFile <file>` | Use a JSON selection file, including custom folders passed by the GUI. This format is primarily intended for automation and the GUI. |
| `-BackupSource <path>` | Explicit restore source. The path must be a direct child of `<Drive>:\Bibliothekssicherung`. When omitted, the current profile's backup is used for compatibility. |
| `-RestoreTargetMode <Profile or Folder>` | `Profile` maps standard folders to the current user profile. `Folder` copies the backup structure below a separate destination folder. |
| `-RestoreTargetRoot <path>` | Selected destination for `-RestoreTargetMode Folder`. A child folder named after the backup is created below it. |
| `-DryRun` | Simulate a backup with Robocopy `/L` without writing user data or successful-backup metadata. Backup only; cannot be combined with `-SuperFast`. |
| `-SkipChecksums` | Do not update `_Pruefsummen.tsv` after a successful backup. The existing manifest may become outdated. |
| `-SuperFast` | Skip preflight, file-based disk-space/4 GB checks, checksum updates, and the BitLocker query; run Robocopy without retries and with 32 threads by default. Backup only; cannot be combined with `-DryRun`. |
| `-RestoreIntegrityPolicy <Verify, RequireVerified, or Warn>` | Restore integrity policy. `Verify` checks an existing manifest when needed, `RequireVerified` accepts only an already verified state, and `Warn` preserves interactive CLI behavior. Direct-call default: `Warn`; the GUI uses `Verify`. |
| `-Threads 1..128` | Number of parallel Robocopy threads. Default: 8; when `-SuperFast` is used without an explicit value: 32. An explicit value always wins. |

`-ParentProcessId`, `-ParentProcessStartTimeUtcTicks`, `-StatusFile`, `-ResultFile`, `-CancelFile`, `-PreviewFile`,
and `-ApprovalFile` form the internal communication channel between the GUI and
worker. They are not required for normal direct runs. Custom automation may use
`-ResultFile` for a structured JSON summary; the status, cancellation, and
approval files form a coordinated protocol and should not be improvised
individually.

Invalid combinations and failures produce a non-zero exit code. See **Exit
codes** for the complete table.

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

## Author and credits

- **Author, development, and maintenance:** Günther Meusburger (meuse24), `github.com/meuse24`
- **Source code and contributions:** `github.com/meuse24/m24Backup`
- **Technical foundations:** Windows PowerShell 5.1, Microsoft .NET Windows
  Forms, and Robocopy
- **AI CLI tools:** Claude Code, OpenAI Codex, and Google Gemini CLI for support
  with development, review, testing, and documentation
- **License:** MIT License, Copyright © 2026 Günther Meusburger (meuse24)

Windows, PowerShell, .NET, and Robocopy are Microsoft products or technologies.
Their mention does not imply Microsoft endorsement or certification of this
project.
