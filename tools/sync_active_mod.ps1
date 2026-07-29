[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path

if ([string]::IsNullOrWhiteSpace($Destination)) {
    # Expected local layout:
    #   Content\mods_to_optimize_2\PlayerNotes  (source repository)
    #   Content\mods\PlayerNotes                (active game installation)
    $sourceParent = Split-Path -Parent $repositoryRoot
    $contentRoot = Split-Path -Parent $sourceParent
    $Destination = Join-Path $contentRoot 'mods\PlayerNotes'
}

if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
    throw "Active PlayerNotes directory not found: $Destination"
}

$destinationRoot = (Resolve-Path -LiteralPath $Destination).Path

if ($repositoryRoot.Equals(
        $destinationRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Source and destination resolve to the same directory.'
}

if ((Split-Path -Leaf $destinationRoot) -ne 'PlayerNotes') {
    throw "Refusing to synchronize an unexpected destination: $destinationRoot"
}

if (-not (Test-Path -LiteralPath (
        Join-Path $destinationRoot 'PlayerNotes.mod'
    ) -PathType Leaf)) {
    throw "Destination does not contain PlayerNotes.mod: $destinationRoot"
}

$trackedFiles = @(& git -C $repositoryRoot ls-files)
if ($LASTEXITCODE -ne 0 -or $trackedFiles.Count -eq 0) {
    throw 'Could not read the canonical Git tracked-file manifest.'
}

$trackedSet = @{}
foreach ($relativePath in $trackedFiles) {
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        continue
    }
    $trackedSet[$relativePath.Replace([char]92, [char]47)] = $true
}

function Get-PayloadExtras {
    $gitMetadataRoot = Join-Path $destinationRoot '.git'
    $extras = @()

    Get-ChildItem -LiteralPath $destinationRoot -File -Recurse -Force |
        ForEach-Object {
            if ($_.FullName.StartsWith(
                    $gitMetadataRoot + [IO.Path]::DirectorySeparatorChar,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                return
            }

            $relativePath = $_.FullName.Substring(
                $destinationRoot.Length
            ).TrimStart([char]92, [char]47)
            $relativePath = $relativePath.Replace([char]92, [char]47)

            if ($relativePath.EndsWith('.pyc') -or
                $relativePath.Contains('/__pycache__/') -or
                $relativePath.StartsWith('__pycache__/')) {
                return
            }

            if (-not $trackedSet.ContainsKey($relativePath)) {
                $extras += $relativePath
            }
        }

    return @($extras | Sort-Object -Unique)
}

function Get-FileDifferences {
    $differences = @()

    foreach ($relativePath in $trackedFiles) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }

        $sourcePath = Join-Path $repositoryRoot $relativePath
        $destinationPath = Join-Path $destinationRoot $relativePath

        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            $differences += "missing: $relativePath"
            continue
        }

        $sourceHash = (
            Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256
        ).Hash
        $destinationHash = (
            Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256
        ).Hash

        if ($sourceHash -ne $destinationHash) {
            $differences += "different: $relativePath"
        }
    }

    return $differences
}

if (-not $Check) {
    $copiedCount = 0

    foreach ($relativePath in $trackedFiles) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }

        $sourcePath = Join-Path $repositoryRoot $relativePath
        $destinationPath = Join-Path $destinationRoot $relativePath
        $destinationParent = Split-Path -Parent $destinationPath

        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationParent -Force |
                Out-Null
        }

        $needsCopy = -not (
            Test-Path -LiteralPath $destinationPath -PathType Leaf
        )
        if (-not $needsCopy) {
            $sourceHash = (
                Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256
            ).Hash
            $destinationHash = (
                Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256
            ).Hash
            $needsCopy = $sourceHash -ne $destinationHash
        }

        if ($needsCopy) {
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
            $copiedCount += 1
        }
    }

    Write-Output "Copied $copiedCount changed tracked file(s) to $destinationRoot."
}

$differences = @(Get-FileDifferences)
$extras = @(Get-PayloadExtras)

if ($differences.Count -gt 0 -or $extras.Count -gt 0) {
    if ($differences.Count -gt 0) {
        Write-Error (
            "Tracked-file differences remain:`n - " +
            ($differences -join "`n - ")
        )
    }
    if ($extras.Count -gt 0) {
        Write-Error (
            "Untracked active payload files require review:`n - " +
            ($extras -join "`n - ")
        )
    }
    exit 1
}

Write-Output (
    "PlayerNotes synchronization verified: " +
    "$($trackedSet.Count) tracked files match exactly."
)

if (-not $Check -and (Get-Process -Name Darktide -ErrorAction SilentlyContinue)) {
    Write-Warning 'Darktide is running; restart it to load synchronized Lua files.'
}
