<#
.SYNOPSIS
Builds and optionally publishes a complete M24 Backup release.

.DESCRIPTION
Derives the next semantic version from Git tags, builds the installer and
portable ZIP, creates and pushes an annotated tag, and publishes the artifacts
as a GitHub release. Potentially destructive or remote actions are shown before
execution and require confirmation unless -Yes is specified.

.EXAMPLE
  .\release.ps1
  Creates the next patch release, for example 1.0.0 -> 1.0.1.

.EXAMPLE
  .\release.ps1 -Bump Minor
  Creates the next feature release, for example 1.0.0 -> 1.1.0.

.EXAMPLE
  .\release.ps1 -Bump Minor -LocalOnly
  Builds version 1.1.0 locally without creating a tag or changing GitHub.

.EXAMPLE
  .\release.ps1 -Bump Minor -WhatIf
  Displays the complete plan without building or changing anything.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Patch', 'Minor', 'Major')]
    [string]$Bump = 'Patch',

    [ValidatePattern('^v?\d+\.\d+\.\d+$')]
    [string]$Version,

    [switch]$LocalOnly,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$buildScript = Join-Path $root 'build.ps1'
$distDirectory = Join-Path $root 'dist'

function Get-Executable {
    param([string]$Name, [string[]]$Candidates)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}

$git = Get-Executable -Name 'git.exe' -Candidates @(
    'C:\Program Files\Git\cmd\git.exe',
    'C:\Program Files\Git\bin\git.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
)
if (-not $git) { throw 'Git wurde nicht gefunden.' }
if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) { throw "Build-Skript fehlt: $buildScript" }

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $output = & $git -C $root @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Git-Befehl fehlgeschlagen: git $($Arguments -join ' ')" }
    return $output
}

function Get-SemanticTags {
    $items = foreach ($tag in @(Invoke-Git tag --list)) {
        if ($tag -match '^v(\d+)\.(\d+)\.(\d+)$') {
            [pscustomobject]@{
                Tag = $tag
                Version = [version]("{0}.{1}.{2}" -f $matches[1], $matches[2], $matches[3])
            }
        }
    }
    return @($items | Sort-Object Version -Descending)
}

function Get-NextVersion {
    param([System.Version]$Previous, [string]$Part)
    switch ($Part) {
        'Major' { return [version]("{0}.0.0" -f ($Previous.Major + 1)) }
        'Minor' { return [version]("{0}.{1}.0" -f $Previous.Major, ($Previous.Minor + 1)) }
        default { return [version]("{0}.{1}.{2}" -f $Previous.Major, $Previous.Minor, ($Previous.Build + 1)) }
    }
}

function Get-GitHubCli {
    return Get-Executable -Name 'gh.exe' -Candidates @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\gh.exe'),
        (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe')
    )
}

function Enable-TemporaryGitHubAuthentication {
    if ($env:GH_TOKEN -or $env:GITHUB_TOKEN) { return $false }
    $credentialOutput = "protocol=https`nhost=github.com`n`n" | & $git credential fill
    if ($LASTEXITCODE -ne 0) { throw 'GitHub-Anmeldung konnte nicht aus dem Windows-Anmeldeinformationsmanager gelesen werden.' }
    $passwordLine = $credentialOutput | Where-Object { $_ -like 'password=*' } | Select-Object -First 1
    if (-not $passwordLine) { throw 'Keine GitHub-Anmeldung gefunden. Bitte zuerst einmal erfolgreich zu GitHub pushen.' }
    $env:GH_TOKEN = $passwordLine.Substring('password='.Length)
    return $true
}

if (-not (Test-Path -LiteralPath (Join-Path $root '.git') -PathType Container)) {
    throw "Kein Git-Repository: $root"
}

$status = @(Invoke-Git status --porcelain)
if ($status.Count -gt 0) {
    throw "Der Git-Arbeitsbaum ist nicht sauber. Bitte Änderungen zuerst committen:`r`n$($status -join [Environment]::NewLine)"
}

$branch = (Invoke-Git branch --show-current | Select-Object -First 1).Trim()
if (-not $branch) { throw 'Releases aus einem detached HEAD sind nicht erlaubt.' }
$head = (Invoke-Git rev-parse HEAD | Select-Object -First 1).Trim()

$gh = $null
if (-not $LocalOnly) {
    $remotes = @(Invoke-Git remote)
    if ($remotes -notcontains 'origin') { throw "Git-Remote 'origin' fehlt." }
    $gh = Get-GitHubCli
    if (-not $gh) { throw 'GitHub CLI fehlt. Installation: winget install --id GitHub.cli -e --scope user' }

    if (-not $WhatIfPreference) {
        Invoke-Git fetch origin --tags | Out-Null
        $remoteBranch = @(Invoke-Git branch --remotes --list "origin/$branch")
        if ($remoteBranch.Count -gt 0) {
            $counts = ((Invoke-Git rev-list --left-right --count "$branch...origin/$branch") | Select-Object -First 1) -split '\s+'
            $behind = [int]$counts[1]
            if ($behind -gt 0) { throw "Der lokale Branch liegt $behind Commit(s) hinter origin/$branch. Bitte zuerst aktualisieren." }
        }
    }
}

$semanticTags = @(Get-SemanticTags)
$latest = $semanticTags | Select-Object -First 1
$tagsAtHead = @(Invoke-Git tag --points-at HEAD)
$semanticTagAtHead = $semanticTags | Where-Object { $tagsAtHead -contains $_.Tag } | Select-Object -First 1

$needsTag = $true
if ($semanticTagAtHead) {
    $releaseVersion = $semanticTagAtHead.Version.ToString(3)
    $releaseTag = $semanticTagAtHead.Tag
    $needsTag = $false
    if ($Version -and $Version.TrimStart('v') -ne $releaseVersion) {
        throw "Der aktuelle Commit trägt bereits $releaseTag; -Version $Version passt nicht dazu."
    }
} else {
    if ($Version) {
        $releaseVersion = $Version.TrimStart('v')
        $releaseTag = "v$releaseVersion"
    } else {
        $baseVersion = if ($latest) { $latest.Version } else { [version]'0.0.0' }
        $releaseVersion = (Get-NextVersion -Previous $baseVersion -Part $Bump).ToString(3)
        $releaseTag = "v$releaseVersion"
    }
    if ($latest -and [version]$releaseVersion -le $latest.Version) {
        throw "Die neue Version $releaseVersion muss größer als $($latest.Version.ToString(3)) sein."
    }
    if (@(Invoke-Git tag --list $releaseTag).Count -gt 0) { throw "Der Tag $releaseTag existiert bereits auf einem anderen Commit." }
}

$artifactNames = @(
    "Bibliothekssicherung-Setup-$releaseVersion.exe",
    "Bibliothekssicherung-Portable-$releaseVersion.zip",
    'SHA256SUMS.txt'
)

Write-Host ''
Write-Host 'M24 Backup Release' -ForegroundColor Cyan
Write-Host "  Branch:       $branch"
Write-Host "  Commit:       $head"
Write-Host "  Letzter Tag:  $(if ($latest) { $latest.Tag } else { '(keiner)' })"
Write-Host "  Neue Version: $releaseVersion"
Write-Host "  Neuer Tag:    $(if ($needsTag) { $releaseTag } else { "$releaseTag (bereits vorhanden)" })"
Write-Host "  Ziel:         $(if ($LocalOnly) { 'nur lokale Build-Artefakte' } else { 'Git-Tag, origin und GitHub Release' })"
Write-Host ''

if ($WhatIfPreference) {
    Write-Host 'WhatIf: Es wurden keine Dateien gebaut, Tags erstellt oder Remote-Systeme geändert.' -ForegroundColor Yellow
    return
}

if (-not $LocalOnly -and -not $Yes) {
    $answer = Read-Host "Release $releaseTag jetzt bauen und veröffentlichen? [j/N]"
    if ($answer -notmatch '^(j|ja|y|yes)$') {
        Write-Host 'Abgebrochen. Es wurden keine Änderungen vorgenommen.'
        return
    }
}

if (-not $PSCmdlet.ShouldProcess("M24 Backup $releaseVersion", 'Release bauen')) { return }

Write-Host "Baue Release $releaseVersion ..." -ForegroundColor Cyan
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $buildScript -Version $releaseVersion -RequireInstaller
if ($LASTEXITCODE -ne 0) { throw "Build fehlgeschlagen (Exit-Code $LASTEXITCODE)." }

foreach ($artifactName in $artifactNames) {
    $artifactPath = Join-Path $distDirectory $artifactName
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw "Release-Datei fehlt: $artifactPath" }
}

$postBuildStatus = @(Invoke-Git status --porcelain)
if ($postBuildStatus.Count -gt 0) {
    throw "Der Build hat versionierte Dateien verändert. Vor Tag und Push ist ein Commit erforderlich:`r`n$($postBuildStatus -join [Environment]::NewLine)"
}

if ($LocalOnly) {
    Write-Host "Lokaler Release-Build fertig: $distDirectory" -ForegroundColor Green
    return
}

if ($needsTag) {
    if (-not $PSCmdlet.ShouldProcess($releaseTag, 'Annotierten Git-Tag erstellen')) { return }
    Invoke-Git tag --annotate $releaseTag --message "M24 Backup $releaseVersion" | Out-Null
}

if (-not $PSCmdlet.ShouldProcess("origin/$branch und $releaseTag", 'Zu GitHub pushen')) { return }
Invoke-Git push origin $branch | Out-Null
Invoke-Git push origin $releaseTag | Out-Null

$temporaryToken = $false
try {
    $temporaryToken = Enable-TemporaryGitHubAuthentication
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $existingReleaseUrl = & $gh release view $releaseTag --json url --jq '.url' 2>$null
        $releaseExists = $LASTEXITCODE -eq 0 -and $existingReleaseUrl
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    $artifactPaths = @($artifactNames | ForEach-Object { Join-Path $distDirectory $_ })
    if ($releaseExists) {
        if (-not $PSCmdlet.ShouldProcess($existingReleaseUrl, 'Release-Dateien aktualisieren')) { return }
        & $gh release upload $releaseTag @artifactPaths --clobber
        if ($LASTEXITCODE -ne 0) { throw 'GitHub-Release-Dateien konnten nicht aktualisiert werden.' }
        $releaseUrl = $existingReleaseUrl
    } else {
        if (-not $PSCmdlet.ShouldProcess($releaseTag, 'GitHub Release erstellen')) { return }
        $releaseUrl = & $gh release create $releaseTag @artifactPaths --verify-tag --title "M24 Backup $releaseVersion" --generate-notes
        if ($LASTEXITCODE -ne 0) { throw 'GitHub Release konnte nicht erstellt werden.' }
    }
} finally {
    if ($temporaryToken) { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "Release $releaseVersion erfolgreich veröffentlicht." -ForegroundColor Green
Write-Host $releaseUrl
Write-Host "Lokale Artefakte: $distDirectory"
