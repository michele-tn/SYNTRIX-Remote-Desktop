[CmdletBinding()]
param(
 [ValidateSet('auto','stable','nightly')][string]$Channel='auto',
 [string]$Tag,[string]$Output,[switch]$Plan,[switch]$PrepareOnly,[switch]$Force
)
$arguments=@{Channel=$Channel;Variant='public';Plan=$Plan;PrepareOnly=$PrepareOnly;Force=$Force}
if($Tag){$arguments.Tag=$Tag}
if($Output){$arguments.Output=$Output}
& (Join-Path $PSScriptRoot 'maintenance/Update-Syntrix.ps1') @arguments
exit $LASTEXITCODE
