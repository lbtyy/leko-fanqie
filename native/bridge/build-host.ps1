[CmdletBinding()]
param(
    [string]$QuickJsRoot = (Join-Path $PSScriptRoot '..\..\third_party\quickjs-2026-06-04'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\..\build\host')
)

$ErrorActionPreference = 'Stop'
$gcc = Get-Command gcc -ErrorAction SilentlyContinue
$clang = Get-Command clang -ErrorAction SilentlyContinue
$compiler = if ($clang) { $clang.Source } elseif ($gcc) { $gcc.Source } else { $null }
if (-not $compiler) {
    Write-Output 'BUILD_BLOCKED: gcc/clang is not available on PATH; no production file was changed.'
    exit 3
}
if (-not (Test-Path -LiteralPath (Join-Path $QuickJsRoot 'quickjs.c'))) {
    throw "QuickJS source not found: $QuickJsRoot"
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$bridge = Join-Path $PSScriptRoot 'lqjs_bridge.c'
$test = Join-Path $PSScriptRoot 'test_lqjs_bridge.c'
$sources = @(
    $bridge,
    (Join-Path $QuickJsRoot 'quickjs.c'),
    (Join-Path $QuickJsRoot 'dtoa.c'),
    (Join-Path $QuickJsRoot 'libregexp.c'),
    (Join-Path $QuickJsRoot 'libunicode.c'),
    (Join-Path $QuickJsRoot 'cutils.c')
)
$library = Join-Path $OutputDir 'liblekoqjs.dll'
$testExe = Join-Path $OutputDir 'test_lqjs_bridge.exe'
$flags = @('-std=c11', '-O2', '-shared', '-D_GNU_SOURCE', '-D_WIN32', '-DCONFIG_VERSION="2026-06-04"', "-I$QuickJsRoot")
& $compiler @flags @sources '-o' $library
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $compiler '-std=c11' '-O2' "-I$PSScriptRoot" $test "-L$OutputDir" '-llekoqjs' '-o' $testExe
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $testExe
exit $LASTEXITCODE
