[CmdletBinding()]
param(
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$OutputDirectory = if ($OutputDirectory) { $OutputDirectory } else { Join-Path $repoRoot 'dist' }
$pluginRoot = Join-Path $repoRoot 'leko.koplugin'
$versionFile = Join-Path $pluginRoot 'Leko\Version.lua'
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
    throw "Missing version file: $versionFile"
}

$versionText = Get-Content -Raw -Encoding UTF8 -LiteralPath $versionFile
$match = [regex]::Match($versionText, 'version\s*=\s*"([^"]+)"')
if (-not $match.Success) { throw 'Unable to read plugin version.' }
$version = $match.Groups[1].Value
$mainFile = Join-Path $pluginRoot 'main.lua'
$mainText = Get-Content -Raw -Encoding UTF8 -LiteralPath $mainFile
$mainMatch = [regex]::Match($mainText, 'EXPECTED_VERSION\s*=\s*"([^"]+)"')
if (-not $mainMatch.Success -or $mainMatch.Groups[1].Value -ne $version) {
    throw 'Version.lua and main.lua do not declare the same release version.'
}
$installFile = Join-Path $pluginRoot 'INSTALL.txt'
$installText = Get-Content -Raw -Encoding UTF8 -LiteralPath $installFile
$installMatch = [regex]::Match($installText, '(?m)^Leko Reader\s+([^\s]+)\s+安装说明')
if (-not $installMatch.Success -or $installMatch.Groups[1].Value -ne $version) {
    throw 'Version.lua and INSTALL.txt do not declare the same release version.'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$zipPath = Join-Path $OutputDirectory ("Leko-Reader-KOReader-{0}.zip" -f $version)
if (Test-Path -LiteralPath $zipPath) {
    throw "Refusing to overwrite an existing archive: $zipPath"
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('leko-public-package-' + [Guid]::NewGuid().ToString('N'))
$stagePlugin = Join-Path $tempRoot 'leko.koplugin'
New-Item -ItemType Directory -Path $stagePlugin -Force | Out-Null

try {
    foreach ($name in @('main.lua', '_meta.lua', 'INSTALL.txt', 'config.example.lua', 'LICENSE', 'NOTICE.md')) {
        Copy-Item -LiteralPath (Join-Path $pluginRoot $name) -Destination $stagePlugin
    }
    foreach ($name in @('Leko', 'book_sources', 'resources')) {
        Copy-Item -LiteralPath (Join-Path $pluginRoot $name) -Destination (Join-Path $stagePlugin $name) -Recurse
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination (Join-Path $stagePlugin 'README.md')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $stagePlugin 'LICENSE')

    # [seam] leko-plus T12：多平台 QuickJS 产物（可选，需要 build-host.ps1 先构建）
    $nativeRoot = Join-Path $stagePlugin 'native'
    foreach ($target in @('kindle-armv7', 'kobo-armv7', 'linux-x86_64', 'windows-x86_64')) {
        $candidate = Join-Path (Join-Path $repoRoot 'build') "$target/liblekoqjs.so"
        if (-not (Test-Path -LiteralPath $candidate)) {
            $candidate = Join-Path (Join-Path $repoRoot 'build') "$target/liblekoqjs.dll"
        }
        if (Test-Path -LiteralPath $candidate) {
            $targetDir = Join-Path $nativeRoot $target
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            Copy-Item -LiteralPath $candidate -Destination (Join-Path $targetDir (Split-Path -Leaf $candidate))
        }
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $stagePlugin -Recurse -File | Sort-Object FullName) {
            $entry = $file.FullName.Substring($tempRoot.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $file.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

# Validate the archive that will be handed to the user.  A valid ZIP can still
# be installed into a partially overwritten plugin directory, so fail here if
# the archive itself is missing any loader-critical file or contains malformed
# paths.  This keeps packaging failures separate from device-side copy failures.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entries = @($archive.Entries)
    $duplicateNames = @($entries | Group-Object FullName | Where-Object { $_.Count -gt 1 })
    if ($duplicateNames.Count -gt 0) {
        throw 'Package contains duplicate ZIP entry names.'
    }
    $invalidNames = @($entries | Where-Object {
        $_.FullName -notmatch '^leko\.koplugin/' -or $_.FullName -match '(^|/)\.\.?(/|$)'
    })
    if ($invalidNames.Count -gt 0) {
        throw 'Package contains an invalid ZIP entry path.'
    }
    foreach ($required in @(
        'leko.koplugin/main.lua',
        'leko.koplugin/_meta.lua',
        'leko.koplugin/Leko/App.lua',
        'leko.koplugin/Leko/MemoryGuard.lua',
        'leko.koplugin/Leko/ProcessBudget.lua',
        'leko.koplugin/Leko/Version.lua'
    )) {
        $entry = $archive.GetEntry($required)
        if ($null -eq $entry -or $entry.Length -le 0) {
            throw "Package is missing or has an empty required file: $required"
        }
    }
} finally {
    $archive.Dispose()
}

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject]@{
    package = $zipPath
    size_bytes = (Get-Item -LiteralPath $zipPath).Length
    verified = $true
    sha256 = $hash
} | ConvertTo-Json
