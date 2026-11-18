[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$artifact = Get-Item -LiteralPath $Path
if ($artifact -isnot [System.IO.FileInfo] -or $artifact.Extension -ne '.exe') {
    throw "Expected a Windows executable at $Path."
}

$reader = [System.IO.BinaryReader]::new($artifact.OpenRead())
try {
    if ($artifact.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) {
        throw "Invalid DOS header in $($artifact.FullName)."
    }
    $reader.BaseStream.Position = 0x3c
    $peOffset = $reader.ReadUInt32()
    if ($peOffset -lt 64 -or $peOffset -gt ($artifact.Length - 26)) {
        throw "Invalid PE header offset in $($artifact.FullName)."
    }
    $reader.BaseStream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) {
        throw "Expected an AMD64 PE executable at $($artifact.FullName)."
    }
    $reader.BaseStream.Position = $peOffset + 24
    if ($reader.ReadUInt16() -ne 0x20b) {
        throw "Expected a PE32+ optional header in $($artifact.FullName)."
    }
    $reader.BaseStream.Position = 0
    $hash = Get-FileHash -InputStream $reader.BaseStream -Algorithm SHA256
    [pscustomobject]@{
        Path = $artifact.FullName
        Architecture = 'x64'
        Bytes = $reader.BaseStream.Length
        SHA256 = $hash.Hash
    }
}
finally {
    $reader.Dispose()
}
