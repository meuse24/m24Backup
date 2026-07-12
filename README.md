# M24 Backup

**English** | [Deutsch](README.de.md)

A compact Windows application for safely backing up and restoring the personal
folders of the current user. The interface is displayed in German on German
Windows systems and in English on all other systems.

## Features

- Backs up Desktop, Documents, Downloads, Pictures, Music, Videos, Favorites,
  Saved Games, and other detected user folders.
- Uses Robocopy and never deletes files from the backup destination.
- Checks the destination, available disk space, and FAT32 limitations before
  starting.
- Shows progress and a clear result directly in the application window.
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
3. Select the folders to include and click **Start backup**.
4. Check the final status and open the log if necessary.

To restore files, select **Restore** mode. The application only accepts a
backup whose computer and user metadata match the current profile. A conflict
preview is shown before any changes are made.

Detailed instructions are included in the repository and every distribution:

- [`Help-and-Info.txt`](Help-and-Info.txt) – English
- [`Hilfe-und-Info.txt`](Hilfe-und-Info.txt) – Deutsch

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
through atomically written status files and structured JSON results.

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

After creating a version tag, the build script produces the installer, portable
ZIP, and SHA-256 checksums:

```powershell
git tag -a v1.0.0 -m "M24 Backup 1.0.0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\build.ps1" -RequireInstaller
```

The version is derived from `git describe --tags --always --dirty`. A build
from a modified working tree therefore intentionally receives the `-dirty`
suffix. Finished artifacts are written to `dist\`.

Build only the portable package:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\build.ps1" -SkipInstaller
```

## Release notes

Generated packages are not digitally signed yet. Windows SmartScreen may
therefore show a warning for files downloaded from the internet. For wider
public distribution, the setup file and scripts should be signed with a trusted
code-signing certificate.

This repository currently has no open-source license. Publicly readable source
code does not automatically grant permission to use, modify, or redistribute
it.
