<#
.SYNOPSIS
Builds the portable ZIP and, when Inno Setup is installed, the per-user installer.

.EXAMPLE
  .\build.ps1
  .\build.ps1 -Version 1.0.0 -RequireInstaller
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$SkipInstaller,
    [switch]$RequireInstaller
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$buildDir = Join-Path $root 'build'
$distDir = Join-Path $root 'dist'
$stageDir = Join-Path $buildDir 'staging'
$portableDir = Join-Path $buildDir 'portable'
$iconPath = Join-Path $root 'app.ico'
$logoPath = Join-Path $root 'logo.jpg'
$installerScript = Join-Path $root 'installer\Bibliothekssicherung.iss'

function Remove-BuildDirectory {
    param([string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith("$root\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside the repository: $fullPath"
    }
    if (Test-Path -LiteralPath $fullPath) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

function Get-GitExecutable {
    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-BuildVersion {
    if ($Version) { return $Version.Trim().TrimStart('v') }
    $git = Get-GitExecutable
    if ($git) {
        $description = (& $git -C $root describe --tags --always --dirty 2>$null | Select-Object -First 1)
        if ($description) { return $description.Trim().TrimStart('v') }
    }
    return '0.0.0-dev'
}

function New-AppIcon {
    param([string]$SourcePath, [string]$DestinationPath)

    Add-Type -AssemblyName System.Drawing
    $sourceStream = [System.IO.File]::Open($SourcePath, 'Open', 'Read', 'ReadWrite')
    try {
        $sourceImage = [System.Drawing.Image]::FromStream($sourceStream)
        try {
            # logo.jpg contains a word mark below the symbol. Crop the shield
            # and USB symbol with a small safety margin so neither the word
            # mark nor excess whitespace reduces legibility at icon sizes.
            $cropSize = [math]::Min([int]($sourceImage.Width * 0.72), [int]($sourceImage.Height * 0.72))
            $sourceX = [int](($sourceImage.Width - $cropSize) / 2)
            $sourceRectangle = New-Object System.Drawing.Rectangle($sourceX, 0, $cropSize, $cropSize)
            $iconFrames = New-Object System.Collections.Generic.List[byte[]]

            foreach ($size in @(16, 24, 32, 48, 64, 128, 256)) {
                $bitmap = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                try {
                    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                    try {
                        $graphics.Clear([System.Drawing.Color]::Transparent)
                        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                        $graphics.DrawImage($sourceImage, (New-Object System.Drawing.Rectangle(0, 0, $size, $size)), $sourceRectangle, [System.Drawing.GraphicsUnit]::Pixel)
                    } finally { $graphics.Dispose() }

                    # JPEG has no alpha channel. Remove only light, neutral
                    # background pixels connected to the image edge. A global
                    # brightness threshold would also erase enclosed white
                    # artwork such as the folder and USB connector.
                    $visited = New-Object bool[] ($size * $size)
                    $queue = New-Object 'System.Collections.Generic.Queue[int]'
                    for ($coordinate = 0; $coordinate -lt $size; $coordinate++) {
                        $queue.Enqueue($coordinate)
                        $queue.Enqueue((($size - 1) * $size) + $coordinate)
                        $queue.Enqueue($coordinate * $size)
                        $queue.Enqueue(($coordinate * $size) + $size - 1)
                    }
                    while ($queue.Count -gt 0) {
                        $index = $queue.Dequeue()
                        if ($visited[$index]) { continue }
                        $visited[$index] = $true
                        $x = $index % $size
                        $y = [int][math]::Floor($index / $size)
                        $pixel = $bitmap.GetPixel($x, $y)
                        $minimum = [math]::Min($pixel.R, [math]::Min($pixel.G, $pixel.B))
                        $maximum = [math]::Max($pixel.R, [math]::Max($pixel.G, $pixel.B))
                        if ($minimum -lt 205 -or ($maximum - $minimum) -gt 32) { continue }

                        $bitmap.SetPixel($x, $y, [System.Drawing.Color]::Transparent)
                        if ($x -gt 0) { $queue.Enqueue($index - 1) }
                        if ($x + 1 -lt $size) { $queue.Enqueue($index + 1) }
                        if ($y -gt 0) { $queue.Enqueue($index - $size) }
                        if ($y + 1 -lt $size) { $queue.Enqueue($index + $size) }
                    }

                    # Store classic 32-bit DIB frames rather than PNG-compressed
                    # frames. Windows PowerShell 5.1/.NET Framework otherwise
                    # renders some multi-resolution ICO files as image noise.
                    $memory = New-Object System.IO.MemoryStream
                    try {
                        $frameWriter = New-Object System.IO.BinaryWriter($memory)
                        try {
                            $pixelBytes = $size * $size * 4
                            $maskRowBytes = [int]([math]::Ceiling($size / 32.0) * 4)
                            $frameWriter.Write([uint32]40)
                            $frameWriter.Write([int32]$size)
                            $frameWriter.Write([int32]($size * 2))
                            $frameWriter.Write([uint16]1)
                            $frameWriter.Write([uint16]32)
                            $frameWriter.Write([uint32]0)
                            $frameWriter.Write([uint32]$pixelBytes)
                            $frameWriter.Write([int32]0)
                            $frameWriter.Write([int32]0)
                            $frameWriter.Write([uint32]0)
                            $frameWriter.Write([uint32]0)

                            for ($y = $size - 1; $y -ge 0; $y--) {
                                for ($x = 0; $x -lt $size; $x++) {
                                    $pixel = $bitmap.GetPixel($x, $y)
                                    $frameWriter.Write([byte]$pixel.B)
                                    $frameWriter.Write([byte]$pixel.G)
                                    $frameWriter.Write([byte]$pixel.R)
                                    $frameWriter.Write([byte]$pixel.A)
                                }
                            }

                            for ($y = $size - 1; $y -ge 0; $y--) {
                                $maskRow = New-Object byte[] $maskRowBytes
                                for ($x = 0; $x -lt $size; $x++) {
                                    if ($bitmap.GetPixel($x, $y).A -lt 128) {
                                        $byteIndex = [int][math]::Floor($x / 8.0)
                                        $maskRow[$byteIndex] = $maskRow[$byteIndex] -bor (0x80 -shr ($x % 8))
                                    }
                                }
                                $frameWriter.Write($maskRow)
                            }
                        } finally { $frameWriter.Dispose() }
                        $iconFrames.Add($memory.ToArray())
                    } finally { $memory.Dispose() }
                } finally { $bitmap.Dispose() }
            }

            $output = [System.IO.File]::Open($DestinationPath, 'Create', 'Write', 'None')
            try {
                $writer = New-Object System.IO.BinaryWriter($output)
                try {
                    $writer.Write([uint16]0)
                    $writer.Write([uint16]1)
                    $writer.Write([uint16]$iconFrames.Count)
                    $offset = 6 + (16 * $iconFrames.Count)
                    for ($index = 0; $index -lt $iconFrames.Count; $index++) {
                        $size = @(16, 24, 32, 48, 64, 128, 256)[$index]
                        $writer.Write([byte]$(if ($size -eq 256) { 0 } else { $size }))
                        $writer.Write([byte]$(if ($size -eq 256) { 0 } else { $size }))
                        $writer.Write([byte]0)
                        $writer.Write([byte]0)
                        $writer.Write([uint16]1)
                        $writer.Write([uint16]32)
                        $writer.Write([uint32]$iconFrames[$index].Length)
                        $writer.Write([uint32]$offset)
                        $offset += $iconFrames[$index].Length
                    }
                    foreach ($frame in $iconFrames) { $writer.Write($frame) }
                } finally { $writer.Dispose() }
            } finally { $output.Dispose() }
        } finally { $sourceImage.Dispose() }
    } finally { $sourceStream.Dispose() }
}

function Get-InnoCompiler {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in @(
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Convert-InlineMarkdown {
    param([string]$Text)

    if ($null -eq $Text) { return '' }
    $segments = $Text -split '`'
    for ($i = 0; $i -lt $segments.Count; $i++) {
        $encoded = [System.Net.WebUtility]::HtmlEncode($segments[$i])
        if ($i % 2 -eq 1) {
            $segments[$i] = "<code>$encoded</code>"
        } else {
            $segments[$i] = [regex]::Replace($encoded, '\*\*(.+?)\*\*', '<strong>$1</strong>')
        }
    }
    return ($segments -join '')
}

function Get-HelpSlug {
    param([string]$Text)

    $slug = $Text.ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[^a-z0-9äöüß]+', '-')
    $slug = $slug.Trim('-')
    if (-not $slug) { return 'section' }
    return $slug
}

function Convert-MarkdownToHelpHtml {
    param(
        [string]$Markdown,
        [string]$Language,
        [string]$Title
    )

    $lines = $Markdown -split "`r?`n"
    $html = New-Object System.Collections.Generic.List[string]
    $toc = New-Object System.Collections.Generic.List[object]
    $paragraph = New-Object System.Collections.Generic.List[string]
    $state = [pscustomobject]@{
        InList = $false
        ListTag = $null
        LastListItemIndex = -1
        InTable = $false
        TableRowCount = 0
    }
    $pendingHeadingAnchor = $null

    function Close-Paragraph {
        if ($paragraph.Count -gt 0) {
            $html.Add(("<p>{0}</p>" -f (Convert-InlineMarkdown ($paragraph -join ' '))))
            $paragraph.Clear()
        }
    }

    function Close-List {
        if ($state.InList) {
            $html.Add("</$($state.ListTag)>")
            $state.InList = $false
            $state.ListTag = $null
            $state.LastListItemIndex = -1
        }
    }

    function Close-Table {
        if ($state.InTable) {
            $html.Add('</tbody></table>')
            $state.InTable = $false
            $state.TableRowCount = 0
        }
    }

    function Open-List {
        param([string]$Tag)
        if ($state.InList -and $state.ListTag -ne $Tag) { Close-List }
        if (-not $state.InList) {
            $html.Add("<$Tag>")
            $state.InList = $true
            $state.ListTag = $Tag
        }
    }

    function Add-ListItem {
        param([string]$Text)
        $html.Add(("<li>{0}</li>" -f (Convert-InlineMarkdown $Text)))
        $state.LastListItemIndex = $html.Count - 1
    }

    function Add-ListContinuation {
        param([string]$Text)
        if ($state.LastListItemIndex -lt 0) { return $false }
        $current = [string]$html[$state.LastListItemIndex]
        $html[$state.LastListItemIndex] = $current -replace '</li>$', (" {0}</li>" -f (Convert-InlineMarkdown $Text))
        return $true
    }

    function Open-Table {
        if (-not $state.InTable) {
            $html.Add('<table><tbody>')
            $state.InTable = $true
            $state.TableRowCount = 0
        }
    }

    foreach ($rawLine in $lines) {
        $line = $rawLine.TrimEnd()
        if (-not $line.Trim()) {
            Close-Paragraph
            Close-List
            Close-Table
            continue
        }

        if ($line -match '^\s*<a\s+id="([A-Za-z0-9_-]+)"></a>\s*$') {
            Close-Paragraph
            Close-List
            Close-Table
            $pendingHeadingAnchor = $matches[1]
            continue
        }

        if ($line -match '^(#{1,3})\s+(.+)$') {
            Close-Paragraph
            Close-List
            Close-Table

            $level = $matches[1].Length
            $headingText = $matches[2].Trim()
            if ($pendingHeadingAnchor) {
                $anchor = $pendingHeadingAnchor
                $pendingHeadingAnchor = $null
            } else {
                $anchor = Get-HelpSlug $headingText
            }
            $html.Add(("<h{0} id=""{1}"">{2}</h{0}>" -f $level, $anchor, (Convert-InlineMarkdown $headingText)))
            if ($level -eq 2) {
                $toc.Add([pscustomobject]@{ Anchor = $anchor; Text = $headingText })
            }
            continue
        }

        if ($pendingHeadingAnchor) {
            $html.Add(('<a id="{0}"></a>' -f $pendingHeadingAnchor))
            $pendingHeadingAnchor = $null
        }

        if ($line -match '^\s*---+\s*$') {
            Close-Paragraph
            Close-List
            Close-Table
            $html.Add('<hr>')
            continue
        }

        if ($line.TrimStart().StartsWith('|') -and $line.TrimEnd().EndsWith('|')) {
            Close-Paragraph
            Close-List
            $cells = @($line.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
            if ($cells.Count -gt 0 -and (@($cells | Where-Object { $_ -notmatch '^:?-{3,}:?$' }).Count -eq 0)) {
                Open-Table
                continue
            }
            Open-Table
            $tag = if ($state.TableRowCount -eq 0) { 'th' } else { 'td' }
            $cellHtml = @($cells | ForEach-Object { "<$tag>$(Convert-InlineMarkdown $_)</$tag>" }) -join ''
            $html.Add("<tr>$cellHtml</tr>")
            $state.TableRowCount++
            continue
        } elseif ($state.InTable) {
            Close-Table
        }

        if ($line -match '^\s*[-*]\s+(.+)$') {
            Close-Paragraph
            Open-List 'ul'
            Add-ListItem $matches[1].Trim()
            continue
        }

        if ($line -match '^\s*\d+\.\s+(.+)$') {
            Close-Paragraph
            Open-List 'ol'
            Add-ListItem $matches[1].Trim()
            continue
        }

        if ($state.InList -and (Add-ListContinuation $line.Trim())) { continue }

        $paragraph.Add($line.Trim())
    }

    Close-Paragraph
    Close-List
    Close-Table

    $tocItems = @($toc | ForEach-Object { "<li><a href=""#$($_.Anchor)"">$(Convert-InlineMarkdown $_.Text)</a></li>" }) -join [Environment]::NewLine
    $body = $html -join [Environment]::NewLine
    $encodedTitle = [System.Net.WebUtility]::HtmlEncode($Title)
    $languageCode = if ($Language -eq 'de') { 'de' } else { 'en' }

    return @"
<!doctype html>
<html lang="$languageCode">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$encodedTitle</title>
<style>
:root { color-scheme: light; --text: #18212b; --muted: #5b6570; --line: #d8dee6; --accent: #0067b8; --bg: #ffffff; --soft: #f5f7fa; }
* { box-sizing: border-box; }
body { margin: 0; font-family: "Segoe UI", Arial, sans-serif; color: var(--text); background: var(--bg); line-height: 1.55; }
main { max-width: 860px; margin: 0 auto; padding: 32px 28px 56px; }
h1 { font-size: 2rem; margin: 0 0 8px; }
h2 { font-size: 1.35rem; margin-top: 2rem; padding-top: .25rem; border-top: 1px solid var(--line); scroll-margin-top: 16px; }
h3 { font-size: 1.08rem; margin-top: 1.5rem; scroll-margin-top: 16px; }
p { margin: .7rem 0; }
a { color: var(--accent); }
code { font-family: Consolas, "Cascadia Mono", monospace; background: var(--soft); padding: .08rem .25rem; border-radius: 3px; }
table { width: 100%; border-collapse: collapse; margin: 1rem 0; }
th, td { border: 1px solid var(--line); padding: .45rem .55rem; text-align: left; vertical-align: top; }
th { background: var(--soft); }
.toc { border: 1px solid var(--line); background: var(--soft); padding: 1rem 1.25rem; margin: 1.4rem 0 2rem; }
.toc h2 { border: 0; margin: 0 0 .5rem; padding: 0; font-size: 1.1rem; }
.toc ul { columns: 2; margin: .5rem 0 0; padding-left: 1.2rem; }
@media print { main { max-width: none; padding: 0; } .toc { break-inside: avoid; } a { color: inherit; text-decoration: none; } }
</style>
</head>
<body>
<main>
<nav class="toc" aria-label="Contents">
<h2>$(if ($Language -eq 'de') { 'Inhalt' } else { 'Contents' })</h2>
<ul>
$tocItems
</ul>
</nav>
$body
</main>
</body>
</html>
"@
}

$buildVersion = (Get-BuildVersion) -replace '[^0-9A-Za-z._-]', '-'
if (-not $buildVersion) { throw 'The build version is empty.' }
$numericVersion = if ($buildVersion -match '^(\d+)\.(\d+)\.(\d+)') {
    '{0}.{1}.{2}.0' -f $matches[1], $matches[2], $matches[3]
} else { '0.0.0.0' }

Write-Host "Building Bibliothekssicherung $buildVersion"
Remove-BuildDirectory $buildDir
Remove-BuildDirectory $distDir
New-Item -ItemType Directory -Path $stageDir, $portableDir, $distDir -Force | Out-Null

if (-not (Test-Path -LiteralPath $logoPath -PathType Leaf)) { throw "Missing logo: $logoPath" }
New-AppIcon -SourcePath $logoPath -DestinationPath $iconPath

$releaseFiles = @(
    'LICENSE',
    'Bibliothekssicherung-GUI.ps1',
    'Bibliothekssicherung.ps1',
    'M24Backup.Shared.ps1',
    'Bibliothekssicherung starten.bat',
    'Bibliothekssicherung starten.vbs',
    'logo.jpg',
    'app.ico'
)

foreach ($name in $releaseFiles) {
    $source = Join-Path $root $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing release file: $source" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $stageDir $name) -Force
}

Set-Content -LiteralPath (Join-Path $stageDir 'version.txt') -Value $buildVersion -Encoding UTF8
$docsSourceDir = Join-Path $root 'docs'
$docsStageDir = Join-Path $stageDir 'docs'
$helpStageDir = Join-Path $stageDir 'Hilfe'
New-Item -ItemType Directory -Path $docsStageDir, $helpStageDir -Force | Out-Null

$helpSources = @(
    @{ Language = 'de'; Source = 'help.de.md'; Output = 'index.de.html'; Title = 'M24 Backup - Hilfe' },
    @{ Language = 'en'; Source = 'help.en.md'; Output = 'index.en.html'; Title = 'M24 Backup - Help' }
)
$buildDate = Get-Date -Format 'yyyy-MM-dd'
foreach ($helpSource in $helpSources) {
    $sourcePath = Join-Path $docsSourceDir $helpSource.Source
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Missing help source: $sourcePath" }

    $markdown = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
    $markdown = $markdown.Replace('{{VERSION}}', $buildVersion).Replace('{{BUILD_DATE}}', $buildDate)
    Set-Content -LiteralPath (Join-Path $docsStageDir $helpSource.Source) -Value $markdown -Encoding UTF8

    $html = Convert-MarkdownToHelpHtml -Markdown $markdown -Language $helpSource.Language -Title $helpSource.Title
    Set-Content -LiteralPath (Join-Path $helpStageDir $helpSource.Output) -Value $html -Encoding UTF8
}

$portableRoot = Join-Path $portableDir ("Bibliothekssicherung-{0}" -f $buildVersion)
New-Item -ItemType Directory -Path $portableRoot -Force | Out-Null
Copy-Item -Path (Join-Path $stageDir '*') -Destination $portableRoot -Recurse -Force
$zipPath = Join-Path $distDir ("Bibliothekssicherung-Portable-{0}.zip" -f $buildVersion)
Compress-Archive -Path $portableRoot -DestinationPath $zipPath -CompressionLevel Optimal
Write-Host "Portable ZIP: $zipPath"

$installerPath = $null
if (-not $SkipInstaller) {
    $iscc = Get-InnoCompiler
    if ($iscc) {
        if (-not (Test-Path -LiteralPath $installerScript -PathType Leaf)) { throw "Missing installer script: $installerScript" }
        & $iscc "/DMyAppVersion=$buildVersion" "/DMyNumericVersion=$numericVersion" "/DSourceDir=$stageDir" "/DOutputDir=$distDir" $installerScript
        if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE." }
        $installerPath = Join-Path $distDir ("Bibliothekssicherung-Setup-{0}.exe" -f $buildVersion)
        if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) { throw "Installer output was not found: $installerPath" }
        Write-Host "Installer: $installerPath"
    } elseif ($RequireInstaller) {
        throw 'Inno Setup 6 was not found. Install it with: winget install --id JRSoftware.InnoSetup -e'
    } else {
        Write-Warning 'Inno Setup 6 was not found; the portable ZIP was built, but the installer was skipped.'
    }
}

$artifacts = @(Get-ChildItem -LiteralPath $distDir -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object Name)
$hashLines = foreach ($artifact in $artifacts) {
    $hash = Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256
    "{0}  {1}" -f $hash.Hash.ToLowerInvariant(), $artifact.Name
}
Set-Content -LiteralPath (Join-Path $distDir 'SHA256SUMS.txt') -Value $hashLines -Encoding ASCII

Write-Host ""
Write-Host 'Build completed.'
$artifacts | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
