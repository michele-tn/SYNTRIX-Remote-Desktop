[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$ToolchainRoot,
    [Parameter(Mandatory)][string]$Output,
    [ValidateSet('public','private')][string]$Variant,
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or ![Environment]::Is64BitProcess) { throw 'Windows x64 build host required.' }
function Run([string]$Tool, [string[]]$Arguments) {
    Write-Host "> $Tool $($Arguments -join ' ')"
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Tool @Arguments; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "$Tool failed with exit code $code." }
}
function Map-ShortPath([string]$Path) {
    if ($Path.Length -le 3) { return $Path }
    $letter = @('Z','W','V','U','T','R','Q','P','O','N') | Where-Object { !(Test-Path ($_ + ':/')) } | Select-Object -First 1
    if (!$letter) { throw 'Two free drive letters are needed for short build paths.' }
    Run subst.exe @(($letter + ':'),$Path)
    $script:mappings += ($letter + ':')
    return ($letter + ':/')
}
$sourcePhysical = [IO.Path]::GetFullPath($Source)
$toolchainPhysical = [IO.Path]::GetFullPath($ToolchainRoot)
$outputPhysical = [IO.Path]::GetFullPath($Output)
$null = New-Item -ItemType Directory -Force -Path $toolchainPhysical,$outputPhysical
$script:mappings = @()
$previousLocation = Get-Location
try {
    $shortTools = Map-ShortPath $toolchainPhysical
    $shortSource = Map-ShortPath $sourcePhysical
    & (Join-Path $PSScriptRoot 'Prepare-Toolchain.ps1') -Source $shortSource -ToolchainRoot $shortTools -Python $Python
    if (!$env:SYNTRIX_FLUTTER) { throw 'Toolchain preparation failed.' }
    Set-Location -LiteralPath $shortSource
    $version = (& $Python -c 'import tomllib; print(tomllib.load(open("Cargo.toml","rb"))["package"]["version"])' | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') { throw 'Invalid source package version.' }
    $packerManifest = Join-Path $shortSource 'libs/portable/Cargo.toml'
    $packerText = [IO.File]::ReadAllText($packerManifest)
    $packerText = [regex]::Replace($packerText, '(?m)^OriginalFilename\s*=\s*"SYNTRIX-[^"]+"', ('OriginalFilename = "SYNTRIX-' + $version + '-x64-portable.exe"'))
    [IO.File]::WriteAllText($packerManifest,$packerText)
    Run $Python @('-c','from pathlib import Path; from datetime import datetime,timezone; import sys; Path("src/version.rs").write_text("pub const VERSION: &str = "+chr(34)+sys.argv[1]+chr(34)+";\n#[allow(dead_code)]\npub const BUILD_DATE: &str = "+chr(34)+datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")+chr(34)+";\n",encoding="utf-8")',$version)
    $env:CARGO_TARGET_DIR = Join-Path $shortSource 'target'
    Push-Location flutter
    try {
        Run $env:SYNTRIX_FLUTTER @('pub','get','--enforce-lockfile')
        Run $env:SYNTRIX_FLUTTER @('test','--no-pub','test/hide_cm_visibility_test.dart')
    } finally { Pop-Location }
    Run cargo @('build','--locked','--release','--features','hwcodec,vram,flutter','--lib')
    Run cargo @('build','--locked','--release','--manifest-path','libs/virtual_display/dylib/Cargo.toml')
    Push-Location flutter
    try {
        $includes = @(Get-ChildItem 'windows/flutter/ephemeral/.plugin_symlinks' | ForEach-Object {
            $windows = Join-Path $_.Target 'windows'
            if (Test-Path -LiteralPath $windows) { '/I"' + $windows + '"'; '/I"' + (Join-Path $windows 'include') + '"' }
        })
        $env:CL = ($includes -join ' ') + ' ' + $env:CL
        Run $env:SYNTRIX_FLUTTER @('build','windows','--release','--no-pub')
    } finally { Pop-Location }
    $bundle = Join-Path $shortSource 'flutter/build/windows/x64/runner/Release'
    Copy-Item -LiteralPath (Join-Path $env:CARGO_TARGET_DIR 'release/librustdesk.dll') -Destination $bundle -Force
    Copy-Item -LiteralPath (Join-Path $env:CARGO_TARGET_DIR 'release/deps/dylib_virtual_display.dll') -Destination $bundle -Force
    $runner = Join-Path $bundle 'rustdesk.exe'
    $reportedVersion = (& $runner --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $reportedVersion -cne $version) { throw "Runtime version mismatch: $reportedVersion vs $version" }
    $verifier = Join-Path $PSScriptRoot 'verify_artifacts.py'
    if ($Variant -eq 'public') {
        Run $Python @($verifier,'normalize',(Join-Path $bundle 'librustdesk.dll'),'--prefix',$sourcePhysical,'--prefix',$toolchainPhysical,'--prefix',$env:USERPROFILE)
    }
    $env:CARGO_TARGET_DIR = Join-Path $shortSource 'target/portable-packer'
    Push-Location libs/portable
    try {
        Run $Python @('generate.py','--folder',$bundle,'--output',(Get-Location).Path,'--executable',$runner,'--target','x86_64-pc-windows-msvc')
    } finally { Pop-Location }
    $packed = Join-Path $env:CARGO_TARGET_DIR 'x86_64-pc-windows-msvc/release/rustdesk-portable-packer.exe'
    $artifact = Join-Path $outputPhysical ('SYNTRIX-' + $version + '-x64-portable.exe')
    Copy-Item -LiteralPath $packed -Destination $artifact -Force
    Run $Python @($verifier,'publish','--source',$shortSource,'--artifact',$artifact,'--version',$version,'--variant',$Variant,'--output',$outputPhysical)
} finally {
    Set-Location -LiteralPath $previousLocation.Path
    foreach ($drive in $script:mappings) { & subst.exe $drive /D }
}
