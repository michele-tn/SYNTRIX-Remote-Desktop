[CmdletBinding()]
param(
    [ValidateSet('auto','stable','nightly')][string]$Channel = 'auto',
    [ValidateSet('public','private','both')][string]$Variant = 'both',
    [string]$Tag,
    [string]$CacheRoot = (Join-Path $env:LOCALAPPDATA 'SyntrixUpdater'),
    [string]$ToolchainRoot = (Join-Path $env:USERPROFILE '.syntrix-toolchain'),
    [string]$Output,
    [switch]$Plan,
    [switch]$PrepareOnly,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or ![Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell or PowerShell 7.' }
$python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$ready = $false
if ($python -and $python.Source -notlike '*WindowsApps*') {
    & $python.Source -c 'import sys; sys.exit(sys.version_info < (3, 11))'
    $ready = $LASTEXITCODE -eq 0
}
if (!$ready) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $runtime = Join-Path $ToolchainRoot 'python-runtime'
    $installer = Join-Path $CacheRoot 'downloads/python-3.12.10-amd64.exe'
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $installer)
    Invoke-WebRequest -UseBasicParsing -Uri 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' -OutFile $installer
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Python Software Foundation') { throw 'Python installer signature validation failed.' }
    $process = Start-Process -FilePath $installer -ArgumentList @('/quiet','InstallAllUsers=0',('TargetDir="' + $runtime + '"'),'PrependPath=0','Include_launcher=0','AssociateFiles=0','Shortcuts=0','Include_test=0') -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Python setup exited with code $($process.ExitCode)." }
    $pythonPath = Join-Path $runtime 'python.exe'
} else { $pythonPath = $python.Source }
$arguments = @((Join-Path $PSScriptRoot 'update_syntrix.py'),'--channel',$Channel,'--variant',$Variant,'--cache',$CacheRoot,'--toolchain',$ToolchainRoot)
if ($Tag) { $arguments += @('--tag',$Tag) }
if ($Output) { $arguments += @('--output',$Output) }
if ($Plan) { $arguments += '--plan' }
if ($PrepareOnly) { $arguments += '--prepare-only' }
if ($Force) { $arguments += '--force' }
& $pythonPath @arguments
exit $LASTEXITCODE
