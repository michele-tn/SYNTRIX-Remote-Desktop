[CmdletBinding()]
param(
    [string]$ToolchainRoot = (Join-Path $env:USERPROFILE '.syntrix-toolchain')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$bundle = Join-Path $repo 'flutter/build/windows/x64/runner/Release'
$runner = Join-Path $bundle 'rustdesk.exe'
$verify = Join-Path $PSScriptRoot 'verify-build.ps1'
$null = & $verify -Path $runner
if ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($runner).ProductName -ne 'SYNTRIX Remote') {
    throw 'Build the SYNTRIX Windows runner before creating the portable package.'
}

$packer = Join-Path $repo 'libs/portable'
$output = Join-Path $repo 'dist/windows-x64/portable'
$reports = Join-Path $repo 'dist/windows-x64/reports'
$cargoHome = Join-Path $ToolchainRoot 'cargo'
$rustupHome = Join-Path $ToolchainRoot 'rustup'
$previous = @{
    CARGO_HOME = $env:CARGO_HOME
    RUSTUP_HOME = $env:RUSTUP_HOME
    RUSTUP_TOOLCHAIN = $env:RUSTUP_TOOLCHAIN
    CARGO_TARGET_DIR = $env:CARGO_TARGET_DIR
    PYTHONPATH = $env:PYTHONPATH
}

Push-Location -LiteralPath $packer
try {
    $env:CARGO_HOME = $cargoHome
    $env:RUSTUP_HOME = $rustupHome
    $env:RUSTUP_TOOLCHAIN = '1.75.0-x86_64-pc-windows-msvc'
    $env:CARGO_TARGET_DIR = Join-Path $repo 'target/portable-packer'
    $pythonPackages = Join-Path $ToolchainRoot 'python'
    $env:PYTHONPATH = (@($pythonPackages, $env:PYTHONPATH) -ne $null) -join [IO.Path]::PathSeparator

    python ./generate.py --folder $bundle --output $packer --executable $runner --target x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) {
        throw "The upstream portable packer exited with code $LASTEXITCODE."
    }

    $packed = Join-Path $env:CARGO_TARGET_DIR 'x86_64-pc-windows-msvc/release/rustdesk-portable-packer.exe'
    $verified = & $verify -Path $packed
    $null = New-Item -ItemType Directory -Force -Path $output, $reports
    $artifact = Join-Path $output 'SYNTRIX-1.5.3-x64-portable.exe'
    Copy-Item -LiteralPath $packed -Destination $artifact
    $result = & $verify -Path $artifact
    if ($result.SHA256 -ne $verified.SHA256) {
        throw 'The staged portable executable has a different hash from the packer output.'
    }
    $result | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath (Join-Path $reports 'portable.json')
    $result
}
finally {
    Pop-Location
    foreach ($name in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
    }
}
