[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ExpectedVersion
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$escapedVersion = [regex]::Escape($ExpectedVersion)

$checks = @(
    @{
        Label = 'README heading'
        Path = Join-Path $repositoryRoot 'README.md'
        Pattern = "(?m)^# PlayerNotes v$escapedVersion`r?$"
    },
    @{
        Label = 'Lua source header'
        Path = Join-Path $repositoryRoot 'scripts/mods/PlayerNotes/PlayerNotes.lua'
        Pattern = "(?m)^\s+Version:\s+$escapedVersion`r?$"
    },
    @{
        Label = 'Lua debug load message'
        Path = Join-Path $repositoryRoot 'scripts/mods/PlayerNotes/PlayerNotes.lua'
        Pattern = "\[PlayerNotes\] v$escapedVersion Loaded\."
    },
    @{
        Label = 'DMF mod metadata'
        Path = Join-Path $repositoryRoot 'scripts/mods/PlayerNotes/PlayerNotes_data.lua'
        Pattern = "(?m)^\s*version\s*=\s*`"$escapedVersion`",`r?$"
    },
    @{
        Label = 'Changelog release entry'
        Path = Join-Path $repositoryRoot 'CHANGELOG.md'
        Pattern = "(?m)^## \[$escapedVersion\] - (Unreleased|\d{4}-\d{2}-\d{2})`r?$"
    }
)

$failures = @()

foreach ($check in $checks) {
    if (-not (Test-Path -LiteralPath $check.Path -PathType Leaf)) {
        $failures += "$($check.Label): missing file $($check.Path)"
        continue
    }

    $content = Get-Content -LiteralPath $check.Path -Raw -Encoding UTF8
    if ($content -notmatch $check.Pattern) {
        $failures += "$($check.Label): expected version $ExpectedVersion"
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Output "Release metadata is consistent for PlayerNotes v$ExpectedVersion."
