[CmdletBinding()]
param(
    [string]$ToolchainRoot = (Join-Path $env:USERPROFILE '.syntrix-toolchain')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-BuildCommand {
    param([string]$Executable, [string[]]$Arguments)

    Write-Host "> $Executable $($Arguments -join ' ')"
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Executable exited with code $LASTEXITCODE."
    }
}

$repo = Split-Path -Parent $PSScriptRoot
$flutter = Join-Path $ToolchainRoot 'flutter/bin'
$rustup = Join-Path $ToolchainRoot 'rustup'
$vcpkg = Join-Path $ToolchainRoot 'vcpkg'
$rust = '1.75.0-x86_64-pc-windows-msvc'
$vcpkgPin = '9e593bb18ea69cc5095e012465dcd675a822ed0d'

$environment = @{
    PATH = "$flutter;$env:PATH"
    CARGO_HOME = (Join-Path $ToolchainRoot 'cargo')
    PUB_CACHE = (Join-Path $ToolchainRoot 'pub-cache')
    RUSTUP_HOME = $rustup
    RUSTUP_TOOLCHAIN = $rust
    VCPKG_ROOT = $vcpkg
    VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
}
$libClang = Join-Path $ToolchainRoot 'libclang/clang/native'
if (!$env:LIBCLANG_PATH -and (Test-Path -LiteralPath (Join-Path $libClang 'libclang.dll'))) {
    $environment.LIBCLANG_PATH = $libClang
}
$previous = @{}

Push-Location -LiteralPath $repo
try {
    foreach ($name in $environment.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process')
    }

    $requiredFiles = @(
        (Join-Path $flutter 'flutter.bat')
        (Join-Path $vcpkg 'vcpkg.exe')
        'src/bridge_generated.rs'
        'src/bridge_generated.io.rs'
        'flutter/lib/generated_bridge.dart'
        'flutter/lib/generated_bridge.freezed.dart'
    )
    $missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count) {
        throw "Missing build inputs:`n$($missing -join "`n")"
    }

    Invoke-BuildCommand git @('status', '--short', '--branch')
    Invoke-BuildCommand git @('log', '-1', '--format=%H')
    $submodules = @(git submodule status --recursive)
    if ($LASTEXITCODE -ne 0 -or !$submodules.Count -or ($submodules -match '^[-+U]')) {
        throw 'Initialize the pinned submodules before building.'
    }
    $submodules | Write-Host

    $vcpkgCommit = git -C $vcpkg rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $vcpkgCommit -ne $vcpkgPin) {
        throw "vcpkg must be checked out at $vcpkgPin."
    }

    Invoke-BuildCommand cargo @('--version')
    Invoke-BuildCommand (Join-Path $flutter 'flutter.bat') @('--version')
    Invoke-BuildCommand python @('--version')
    Invoke-BuildCommand (Join-Path $vcpkg 'vcpkg.exe') @(
        'install', '--triplet', 'x64-windows-static', "--x-install-root=$vcpkg/installed"
    )
    $nativeTools = @(
        (Join-Path $vcpkg 'downloads/tools/cmake-4.4.0-windows/cmake-4.4.0-windows-x86_64/bin')
        (Join-Path $vcpkg 'downloads/tools/nasm/nasm-3.01')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
    $env:PATH = (@($nativeTools) + $env:PATH) -join [IO.Path]::PathSeparator
    Invoke-BuildCommand python @(
        'build.py', '--portable', '--flutter', '--skip-portable-pack', '--hwcodec', '--vram'
    )

    $exe = Join-Path $repo 'flutter/build/windows/x64/runner/Release/rustdesk.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Expected Windows executable was not found at $exe."
    }
    $artifact = & (Join-Path $PSScriptRoot 'verify-build.ps1') -Path $exe
    $versionLine = Select-String -LiteralPath Cargo.toml -Pattern '^version\s*=\s*"([^"]+)"' |
        Select-Object -First 1
    $productVersion = $versionLine.Matches[0].Groups[1].Value
    $reportedVersion = (& $exe --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $reportedVersion -cne $productVersion) {
        throw "Runner version check failed: expected '$productVersion', got '$reportedVersion'."
    }
    $artifact
}
finally {
    Pop-Location
    foreach ($name in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
    }
}
