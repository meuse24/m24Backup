# Vertragstests fuer den Sicherungs-Worker. Der Worker beendet sich selbst
# mit exit-Codes und wird deshalb fuer Invarianten-Tests in einem separaten
# Windows-PowerShell-Prozess gestartet. Die reine Parameter-/Robocopy-Policy
# ist in Get-M24BackupRunPolicy ausgelagert und wird direkt getestet.
BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repoRoot 'M24Backup.Shared.ps1')
    $script:workerScript = Join-Path $repoRoot 'Bibliothekssicherung.ps1'
    $script:windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    function Invoke-WorkerProcess {
        param([string[]]$WorkerArguments)
        $output = & $script:windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $script:workerScript @WorkerArguments 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
}

Describe 'Get-M24BackupRunPolicy' {
    It 'keeps the conservative defaults for a normal backup' {
        $policy = Get-M24BackupRunPolicy -Mode Backup
        $policy.SuperFast | Should -Be $false
        $policy.Threads | Should -Be 8
        $policy.RetryCount | Should -Be 1
        $policy.RetryWaitSeconds | Should -Be 3
        $policy.SkipPreflight | Should -Be $false
        $policy.SkipChecksums | Should -Be $false
        $policy.SkipBitLockerStatus | Should -Be $false
    }

    It 'keeps the conservative defaults for a restore' {
        $policy = Get-M24BackupRunPolicy -Mode Restore
        $policy.Threads | Should -Be 8
        $policy.RetryCount | Should -Be 1
        $policy.RetryWaitSeconds | Should -Be 3
        $policy.SkipPreflight | Should -Be $false
    }

    It 'uses aggressive copy parameters and skips every check in super fast mode' {
        $policy = Get-M24BackupRunPolicy -Mode Backup -SuperFast
        $policy.SuperFast | Should -Be $true
        $policy.Threads | Should -Be 32
        $policy.RetryCount | Should -Be 0
        $policy.RetryWaitSeconds | Should -Be 1
        $policy.SkipPreflight | Should -Be $true
        $policy.SkipChecksums | Should -Be $true
        $policy.SkipBitLockerStatus | Should -Be $true
    }

    It 'lets an explicit thread count win over the super fast default' {
        (Get-M24BackupRunPolicy -Mode Backup -SuperFast -ExplicitThreads 5).Threads | Should -Be 5
        (Get-M24BackupRunPolicy -Mode Backup -ExplicitThreads 5).Threads | Should -Be 5
    }

    It 'honors an explicit checksum skip without super fast mode' {
        (Get-M24BackupRunPolicy -Mode Backup -SkipChecksums).SkipChecksums | Should -Be $true
        (Get-M24BackupRunPolicy -Mode Backup -SkipChecksums).SkipPreflight | Should -Be $false
    }

    It 'rejects super fast mode for restore' {
        { Get-M24BackupRunPolicy -Mode Restore -SuperFast } | Should -Throw '*Super*'
    }

    It 'rejects super fast mode combined with dry run' {
        { Get-M24BackupRunPolicy -Mode Backup -SuperFast -DryRun } | Should -Throw '*Super*'
    }

    It 'rejects thread counts outside 1 to 128' {
        { Get-M24BackupRunPolicy -Mode Backup -ExplicitThreads 0 } | Should -Throw '*Threads*'
        { Get-M24BackupRunPolicy -Mode Backup -ExplicitThreads 129 } | Should -Throw '*Threads*'
        { Get-M24BackupRunPolicy -Mode Backup -SuperFast -ExplicitThreads 129 } | Should -Throw '*Threads*'
    }
}

Describe 'Worker parameter invariants' {
    It 'declares the SuperFast switch parameter' {
        $command = Get-Command $script:workerScript
        $command.Parameters.ContainsKey('SuperFast') | Should -Be $true
        $command.Parameters['SuperFast'].ParameterType | Should -Be ([switch])
    }

    It 'declares exact parent identity and restore integrity policy parameters' {
        $command = Get-Command $script:workerScript
        $command.Parameters['ParentProcessStartTimeUtcTicks'].ParameterType | Should -Be ([int64])
        $command.Parameters['RestoreIntegrityPolicy'].ParameterType | Should -Be ([string])
        @($command.Parameters['RestoreIntegrityPolicy'].Attributes.ValidValues) | Should -Be @('Verify', 'RequireVerified', 'Warn')
    }

    It 'rejects -SuperFast for restore before resolving any drive' {
        $result = Invoke-WorkerProcess @('-Mode', 'Restore', '-SuperFast', '-Silent')
        $result.ExitCode | Should -Be 10
        $result.Output | Should -Match 'Superschnell|Super fast'
    }

    It 'rejects -SuperFast combined with -DryRun before resolving any drive' {
        $result = Invoke-WorkerProcess @('-Mode', 'Backup', '-SuperFast', '-DryRun', '-Silent')
        $result.ExitCode | Should -Be 10
        $result.Output | Should -Match 'Superschnell|Super fast'
    }

    It 'still rejects an explicitly invalid thread count' {
        $result = Invoke-WorkerProcess @('-Mode', 'Backup', '-SuperFast', '-Threads', '500', '-Silent')
        $result.ExitCode | Should -Be 10
        $result.Output | Should -Match 'Threads'
    }
}

Describe 'Worker result contract' {
    It 'writes the unified result contract even for a failure before any drive resolution' {
        $resultFile = Join-Path $TestDrive 'trap-result.json'
        $result = Invoke-WorkerProcess @('-Mode', 'Backup', '-SuperFast', '-DryRun', '-Silent', '-ResultFile', $resultFile)
        $result.ExitCode | Should -Be 10
        Test-Path $resultFile | Should -Be $true
        $record = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        $record.Success | Should -Be $false
        $record.Cancelled | Should -Be $false
        $record.SuperFast | Should -Be $true
        $record.DryRun | Should -Be $true
        foreach ($property in @('PreflightSkipped', 'ChecksumSkipped', 'ScannedFiles', 'PlannedFiles', 'PlannedBytes', 'CancellationReason', 'IntegrityPolicy', 'IntegrityVerified', 'IntegrityOverride', 'IntegrityVerificationPerformed', 'Message', 'FinishedAt')) {
            $record.PSObject.Properties[$property] | Should -Not -BeNullOrEmpty -Because "result contract requires '$property'"
        }
        # Zahlen sind hier "nicht ermittelt" und muessen null sein, nicht 0.
        $record.ScannedFiles | Should -BeNullOrEmpty
        $record.PlannedFiles | Should -BeNullOrEmpty
        $record.PlannedBytes | Should -BeNullOrEmpty
    }

    It 'routes every result-file write through the shared record builder' {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:workerScript, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $resultWrites = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Write-AtomicJsonFile' -and
                $node.Extent.Text -match '\$ResultFile'
        }, $true))
        # Cancellation exits are intentionally centralized in
        # Stop-M24CancelledOperation; all remaining writes still use the
        # common record builder.
        $resultWrites.Count | Should -BeGreaterOrEqual 4
        foreach ($write in $resultWrites) {
            $pipeline = $write.Parent
            $pipeline | Should -BeOfType [System.Management.Automation.Language.PipelineAst]
            $firstElement = $pipeline.PipelineElements[0]
            $firstElement.GetCommandName() | Should -Be 'New-BackupResultRecord' -Because "every result write must use the shared contract (line $($write.Extent.StartLineNumber))"
        }
    }
}
