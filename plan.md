# Implementation Plan: Edge-Case Hardening

## Objective

Harden three uncommon but credible failure paths without changing normal backup behavior or the existing GUI architecture:

1. Remove stale application-owned temporary files even when they are marked read-only.
2. Prevent an externally started backup worker from surviving an exception in the final GUI launch sequence.
3. Bound the synchronous CIM drive query and avoid rapid repeated retries after drive-discovery failures.

The changes must remain compatible with Windows PowerShell 5.1 and PowerShell 7.

## Scope and Priority

Implementation priority:

1. Worker-process cleanup after a partial GUI launch failure — correctness and process-lifecycle protection.
2. CIM operation timeout and retry backoff — bounded GUI blocking during drive discovery.
3. Read-only stale-temp cleanup — maintenance hardening.

This work will not:

- Move all drive discovery into a background runspace.
- Add a general process-tree manager.
- Change the worker communication protocol.
- Change the seven-day stale-file threshold or filename authorization rules.
- Remove read-only attributes from fresh, malformed, unrelated, or reparse-point files.
- Suppress user-visible drive-discovery errors that are currently shown in the GUI.

## 1. Remove Read-Only Stale Temporary Artifacts

### Current behavior

`Remove-M24StaleTempArtifacts` authorizes deletion only after exact filename validation, metadata refresh, reparse-point rejection, and the seven-day age check. It then calls `[System.IO.File]::Delete()` directly.

On Windows, deletion can fail when an otherwise eligible file has the `ReadOnly` attribute. The per-file catch safely contains the error, but the artifact remains and is retried on every future GUI startup.

### Implementation

Inside `Remove-M24StaleTempArtifacts`, retain the current order of safety checks:

1. Exact anchored filename validation.
2. `FileInfo.Refresh()`.
3. Existence check.
4. Reparse-point rejection using the refreshed attributes.
5. Seven-day age eligibility.

Only after all five checks pass:

1. Read the current attributes into a local value.
2. If `ReadOnly` is present, clear only that bit.
3. Preserve all other attribute bits.
4. Delete the file with `[System.IO.File]::Delete()`.
5. Keep attribute and deletion failures inside the existing per-file catch.

Recommended form:

```powershell
if ($candidate.LastWriteTimeUtc -le $cutoffUtc) {
    $attributes = $candidate.Attributes
    if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
        [System.IO.File]::SetAttributes(
            $candidate.FullName,
            ($attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly))
        )
    }
    [System.IO.File]::Delete($candidate.FullName)
}
```

Do not clear `Hidden`, `System`, or any other attribute. Do not reuse `Remove-M24FileEntry` directly because stale-temp cleanup has its own ownership, age, and reparse-point authorization boundary and should keep the final mutation visibly inside that boundary.

### Tests

Add Pester coverage proving that:

1. An old, valid, read-only communication file is deleted.
2. An old, valid, read-only atomic remnant is deleted.
3. A fresh, valid, read-only file is preserved and remains read-only.
4. An old read-only file with a malformed or unrelated name is preserved and remains read-only.
5. Existing reparse-point protection remains before any attribute mutation.

All files must be created below `$TestDrive`. Tests must restore attributes in `finally` blocks when necessary so Pester can clean up reliably after a failed assertion.

## 2. Prevent a Worker Leak After Partial Launch Failure

### Current behavior

The GUI creates a `System.Diagnostics.Process`, calls `Start()`, and then starts the WinForms polling timer. If process creation succeeds but `$timer.Start()` throws, the catch disposes the .NET `Process` object without terminating the external `powershell.exe` worker.

`Dispose()` releases local handles only. It does not terminate the process. Because the GUI remains alive after recovering from the catch, the worker's parent-process check does not resolve this failure.

The current exposure window is small: after `Process.Start()` succeeds, the only remaining statement in the launch try block is `$timer.Start()`. The impact is nevertheless significant because an unmanaged backup or restore worker could continue without GUI monitoring.

### Implementation

Use two complementary protections.

#### 2.1 Start the polling timer before launching the external process

Start the WinForms timer immediately before `Process.Start()`.

This is safe because a WinForms timer tick cannot run until the click handler returns control to the message loop. By that time either:

- the worker has started successfully; or
- the catch has stopped the timer and cleared the failed launch state.

Required sequence:

```text
create Process object
assign StartInfo
start polling timer
start external worker process
return from click handler
```

If `Process.Start()` fails or returns false, the catch must stop the timer before restoring the GUI state.

This ordering removes the ordinary post-start exception window.

#### 2.2 Terminate defensively in the catch

Retain a best-effort termination block in the catch for ambiguous or future failure paths where the process may already have started.

Required behavior:

1. Preserve and log the original `ErrorRecord` first.
2. Stop the polling timer as the first cleanup step, before any modal
   dialog: the final MessageBox pumps window messages, and a still-running
   timer could otherwise tick in the middle of the cleanup.
3. If a process object exists, determine best-effort whether it is running.
4. If it is running, request cancellation by creating the existing cancel marker when possible.
5. Wait briefly, for example up to 1,000 milliseconds, for graceful termination.
6. If it remains active, call `Kill()`.
7. Call `WaitForExit()` with a bounded timeout after `Kill()`.
8. Dispose the process object only after the stop attempt.
9. Continue with the existing temporary-file cleanup and GUI-state restoration.

All stop, wait, kill, and dispose operations must be individually protected so they cannot replace the original launch error.

Suggested maximum waits:

- Graceful cancellation: 1,000 ms.
- Post-kill confirmation: 2,000 ms.

Do not wait indefinitely on the GUI thread.

If the process object was created but never associated with an operating-system process, properties such as `HasExited` may throw. Treat that as a normal failed-launch condition and proceed to disposal.

### Process-tree limitation

Windows PowerShell 5.1 uses .NET Framework, whose `Process.Kill()` does not provide the modern `entireProcessTree` overload. The immediate launch window makes it unlikely that Robocopy has already been spawned, but this change must not claim guaranteed process-tree termination.

Do not introduce `taskkill`, WMI process-tree traversal, or cross-process job objects in this hardening task. Those would require a separate lifecycle design.

### Tests and verification

Add focused verification for:

1. The GUI contains exactly one worker polling timer start in the launch path.
2. The timer is started before the external process start.
3. The launch catch stops the timer.
4. The launch catch contains bounded graceful-wait, kill, post-kill wait, and dispose steps.
5. Existing temporary-file cleanup still runs after process cleanup.

Prefer a PowerShell AST-based contract test over raw line-number or unrestricted text matching. The test should locate the `GUI.WorkerStart` catch structurally and verify the relevant command/member invocations.

A reusable process-stop helper (`Stop-M24WorkerProcess`) is introduced in `M24Backup.Shared.ps1` so the graceful-wait/kill/dispose behavior is testable outside the GUI. Add a behavioral test using a harmless child PowerShell process that sleeps for a bounded duration. The test must use a `finally` block that force-terminates the child if the assertion or helper fails, ensuring the test suite cannot leave a process behind.

Do not add a production-only failure injection switch merely to test this edge case.

## 3. Bound CIM Drive Discovery

### Current behavior

`Update-DriveList` calls `Get-CimInstance Win32_LogicalDisk` synchronously on the GUI thread. A severely delayed CIM/WMI operation can therefore block the interface.

The existing catch restores a safe empty-drive state and displays the drive-discovery error in the GUI. It does not crash the application, but it cannot run until the synchronous CIM call returns or fails.

### Implementation

Add an explicit operation timeout and terminating error behavior:

```powershell
Get-CimInstance Win32_LogicalDisk -OperationTimeoutSec 8 -ErrorAction Stop
```

Use a value between five and ten seconds; eight seconds is the recommended default. This keeps normal local enumeration unaffected while bounding most CIM operation delays.

`-OperationTimeoutSec` is available in both Windows PowerShell 5.1 and PowerShell 7.

### Retry backoff

The drive-watch timer currently calls `Update-DriveList` every 2.5 seconds. After a timeout or other discovery failure, immediate repeated retries could cause recurring GUI pauses.

Add script state such as:

```powershell
$script:driveRetryAfterUtc = [DateTime]::MinValue
```

At the start of `Update-DriveList`:

- If the call is not forced and `UtcNow` is earlier than `driveRetryAfterUtc`, return without querying CIM.
- A manual or explicitly forced refresh may bypass the backoff.

On successful drive discovery:

- Reset `driveRetryAfterUtc` to `DateTime.MinValue` immediately after the
  CIM query succeeds — before the unchanged-snapshot early return, which
  would otherwise skip the reset.

In the existing catch:

- Set `driveRetryAfterUtc` to `UtcNow.AddSeconds(30)`.
- Preserve the current UI error message and safe-state cleanup.

Do not make the failure silent. The existing drive-status error is useful feedback.

### Limitations

The CIM timeout does not protect every synchronous operation in `Update-DriveList`. Per-drive calls to `Get-Partition`, `Get-Disk`, and filesystem/metadata inspection can still be delayed.

Moving the complete discovery pipeline to a background runspace is explicitly deferred. The timeout and backoff are bounded, low-risk defense-in-depth measures rather than a complete asynchronous redesign.

### Tests

Add tests or AST-based contract checks proving that:

1. The `Win32_LogicalDisk` GUI query specifies `-OperationTimeoutSec 8`.
2. It specifies `-ErrorAction Stop`.
3. A non-forced call returns during an active retry-backoff window.
4. A forced call bypasses the retry backoff.
5. A successful query clears the backoff state.
6. The catch sets a 30-second backoff.
7. The catch retains the existing user-visible drive error state.

Where GUI-bound behavior cannot be executed safely in Pester without constructing the complete WinForms application, use precise AST assertions scoped to the `Update-DriveList` function rather than broad source-string searches.

## 4. Verification Sequence

After implementation:

1. Parse `M24Backup.Shared.ps1`, `Bibliothekssicherung.ps1`, `Bibliothekssicherung-GUI.ps1`, and the changed test files; require zero parse errors.
2. Run the complete Pester suite under PowerShell 7.
3. Run the complete Pester suite under Windows PowerShell 5.1.
4. Confirm no test left a child PowerShell process running.
5. Confirm no test accessed or modified the real user Temp directory.
6. Confirm the stale-file cleanup still runs once during GUI startup.
7. Confirm normal backup, restore, cancellation, checksum verification, and deletion behavior remains unchanged.

## 5. Manual Acceptance

### Read-only cleanup

1. In a dedicated test directory, create an exact application-owned artifact older than seven days.
2. Mark it read-only.
3. Run `Remove-M24StaleTempArtifacts` against that directory and confirm deletion.
4. Repeat with a fresh read-only artifact and confirm preservation.

### Partial worker launch

1. Confirm a normal backup starts and the polling timer updates the GUI.
2. Confirm a normal start failure restores controls and leaves no worker process.
3. During a controlled development test, force a failure immediately around the timer/process launch boundary without adding a permanent production test hook.
4. Confirm the timer is stopped, the worker exits, temporary communication files are cleaned up, and the original launch error remains visible and logged.

### CIM timeout and backoff

1. Confirm normal drive enumeration remains unchanged.
2. Confirm manual refresh bypasses an active automatic-retry backoff.
3. Simulate or mock a drive-discovery failure during development and confirm the error remains visible.
4. Confirm automatic polling does not immediately repeat the failed query for 30 seconds.

## Acceptance Criteria

- Old, exact, non-reparse application artifacts are deleted even when read-only.
- Fresh, malformed, unrelated, and reparse-point files are never modified by stale cleanup.
- Clearing read-only preserves every other file attribute.
- No successful external worker remains unmanaged after the GUI launch catch completes, within the documented limitation regarding already-spawned child processes.
- The polling timer is stopped on every launch failure.
- Process waits are bounded; the GUI never waits indefinitely during cleanup.
- The GUI CIM query uses an eight-second operation timeout.
- Automatic drive retries pause for 30 seconds after failure.
- Forced refresh bypasses the retry pause.
- Existing user-visible drive errors remain intact.
- All production scripts and tests parse without errors.
- The complete Pester suite passes under PowerShell 7 and Windows PowerShell 5.1.

## Deferred Work

- Full process-tree containment through Windows job objects or another lifecycle mechanism.
- Moving the complete drive-discovery pipeline into a background runspace.
- Timeouts for `Get-Partition`, `Get-Disk`, and filesystem metadata access.
- Any change to the worker communication-file protocol.

## Expected Change Size

The expected implementation consists of:

- A small read-only extension to `Remove-M24StaleTempArtifacts`.
- A reordered and hardened worker launch/catch sequence.
- One CIM timeout plus a small retry-backoff state.
- Focused Pester coverage and AST contract tests.
- No user-visible feature or layout changes.
