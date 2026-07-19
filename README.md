# M24 Backup

**English** | [Deutsch](README.de.md)

<p align="center">
  <img src="logo.jpg" alt="M24 Backup logo" width="220">
</p>

A compact Windows application for safely backing up and restoring the personal
folders of the current user. The interface is displayed in German on German
Windows systems and in English on all other systems.

## Features

- Enables a per-user Windows startup reminder by default when the last
  successful GUI backup is at least 14 days old, without installing a service or
  requiring administrator rights.
- Backs up Desktop, Documents, Downloads, Pictures, Music, Videos, Favorites,
  Saved Games, and other detected user folders.
- Uses Robocopy and never deletes files from the backup destination.
- Checks the destination, available disk space, and FAT32 limitations before
  starting.
- Can simulate a backup with a dry run and show the planned changes in the log
  without copying user data.
- Offers a fast mode (formerly "super fast") that skips preflight, checksum updates, and copy
  retries when maximum speed matters more than advance checks.
- Can include additional user-selected folders and restore them later through
  stored folder metadata.
- Can safely eject a successfully used USB backup drive after completion.
- Shows progress and a clear result directly in the application window.
- Opens existing logs and backup folders immediately after drive selection and
  can copy the result summary.
- Remembers folder selections, shows recent operations, and verifies complete
  file contents against per-file SHA-256 checksums.
- Can completely delete the current computer and user's backup from the
  selected drive after showing its details and requiring two safety
  confirmations.
- Shows a Windows notification after operations while the app is in the
  background.
- Shows a traffic-light health indicator with the age, duration, and folder
  count of the latest backup on the selected drive.
- Recognizes the last successfully used backup drive by its volume identifier,
  even when Windows changes its drive letter.
- Writes a readable log and `_Sicherungsinfo.txt` metadata to the destination.
- Supports cooperative cancellation between folders.
- Provides defensive restore with metadata validation, conflict preview, and
  explicit user confirmation.
- Runs without administrator privileges or additional runtime installation.

> [!IMPORTANT]
> A backup is only trustworthy after a sample restore has been tested. Newer
> local files are protected during restore, but the preview should still be
> reviewed carefully.

## Important limitations

- **Backup data is stored unencrypted** on the destination drive. Keep the
  drive in a safe place or protect it, for example with BitLocker To Go.
- **Open or locked files may be missing.** No Volume Shadow Copy Service
  (VSS) is used; such files are skipped and noted in the log.
- **No versioning:** the backup is a rolling safety copy with exactly one
  current restore state, not an archive with historical file versions.

See the "Safety boundaries" section of the [help](docs/help.en.md) for
details.

## Installation

The recommended option is the setup file from
[GitHub Releases](https://github.com/meuse24/m24Backup/releases). The installer
runs without administrator privileges, installs the application per user in
`%LocalAppData%\Programs\Bibliothekssicherung`, creates a Start menu shortcut,
and can optionally create a desktop shortcut.

Alternatively, extract the portable ZIP completely and run
`Bibliothekssicherung starten.vbs`. The portable edition can also be kept
directly on a backup drive.

## Quick start

1. Connect the backup drive and start the application.
2. Select **Backup** mode and choose the destination drive.
3. Select the folders to include, optionally use **Add folder...**, or enable
   **Simulate only (dry run)**.
4. Optionally enable **Eject after success** or
   **Fast mode (no preflight checks)** for maximum speed without advance
   checks.
5. Click **Start backup**, check the final status, and open the log if
   necessary.

To restore files, select **Restore** mode. The application only accepts a
backup whose computer and user metadata match the current profile. A conflict
preview is shown before any changes are made.

Detailed instructions are included in the repository and every distribution:

- [`docs/help.en.md`](docs/help.en.md) – English source for the local HTML help
- [`docs/help.de.md`](docs/help.de.md) – German source for the local HTML help

## System requirements

- Windows 10 version 1809 or later, or Windows 11
- Windows PowerShell 5.1
- .NET Framework with Windows Forms
- Robocopy

These components are already included with supported Windows versions.

## Privacy and safety model

The application operates locally. It does not upload files, telemetry, or usage
data. Backups are separated by computer and user. During restore, backup
metadata is validated before local files are changed. Robocopy return codes are
evaluated so that actual copy failures cannot be reported as success.

The scripts are launched with `ExecutionPolicy Bypass` in a separate PowerShell
process to avoid unnecessary failures caused by local execution policies. This
does not modify the system-wide execution policy. Only obtain releases from a
trusted source and verify them against `SHA256SUMS.txt`.

## Development

M24 Backup is built with Windows PowerShell 5.1, Windows Forms, and Robocopy.
The interface and backup worker run in separate processes and communicate
through atomically written status files and structured JSON results. Shared
validation helpers live in `M24Backup.Shared.ps1` and are loaded by both the
GUI and worker.

Run from source:

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass `
  -File ".\Bibliothekssicherung-GUI.ps1"
```

Relative launchers are also included:

- `Bibliothekssicherung starten.vbs` – normal launch without a console window
- `Bibliothekssicherung starten.bat` – launch for diagnostic purposes

### Building a release

[Inno Setup 6](https://jrsoftware.org/isinfo.php) is required to build the
installer:

```powershell
winget install --id JRSoftware.InnoSetup -e --scope user
```

The release script derives the next semantic version, builds the artifacts
locally as a verification step, and creates and pushes the Git tag. The tag
push triggers the release-build workflow, which builds the published
artifacts from source, signs them when the SignPath integration is
configured, and publishes the GitHub release. Locally built artifacts are
never published:

```powershell
.\release.ps1
```

Patch is the default (`1.0.0` → `1.0.1`). Select the release type explicitly
for new features or breaking changes:

```powershell
.\release.ps1 -Bump Minor  # 1.0.0 -> 1.1.0
.\release.ps1 -Bump Major  # 1.1.0 -> 2.0.0
```

Preview the complete plan without building or changing GitHub:

```powershell
.\release.ps1 -Bump Minor -WhatIf
```

Build locally without creating a tag, pushing, or publishing a release:

```powershell
.\release.ps1 -Bump Minor -LocalOnly
```

An explicit version can be supplied with `-Version 1.2.3`. The script refuses
dirty working trees, duplicate tags, detached commits, and releases from a
branch behind its GitHub counterpart. Finished artifacts are written to
`dist\`. `build.ps1` remains available for lower-level or portable-only builds.

## Release notes

Code signing via SignPath Foundation is being set up. Until the first signed
release is published, Windows SmartScreen may show a warning for files
downloaded from the internet. Verify downloads against `SHA256SUMS.txt`.

## Code signing policy

Free code signing provided by [SignPath.io](https://signpath.io), certificate
by [SignPath Foundation](https://signpath.org).

Team roles:

- Committers and reviewers: [Günther Meusburger (meuse24)](https://github.com/meuse24)
- Approvers: [Günther Meusburger (meuse24)](https://github.com/meuse24)

Release binaries are built from source by the
[release-build workflow](.github/workflows/release-build.yml) and signed only
from that pipeline.

This program will not transfer any information to other networked systems
unless specifically requested by the user or the person installing or
operating it. See the [privacy section](#privacy-and-safety-model) above.

## License

M24 Backup is open source and released under the [MIT License](LICENSE).
You may use, modify, and redistribute the software; the copyright and
license notice must be preserved.
