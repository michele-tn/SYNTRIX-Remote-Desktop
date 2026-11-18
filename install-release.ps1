[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$release = Join-Path $PSScriptRoot 'release/SYNTRIX-1.5.3-x64-portable.exe'
& python (Join-Path $PSScriptRoot 'package-release.py') $release --verify
if ($LASTEXITCODE -ne 0) { throw 'Release verification failed.' }

# Use the upstream installer interface so the operator can check the target path.
Start-Process -FilePath $release -ArgumentList '--install'
