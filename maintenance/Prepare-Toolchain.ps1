[CmdletBinding()]
param([Parameter(Mandatory)][string]$ToolchainRoot,[string]$Source,[string]$Python='python',[switch]$GitOnly)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

function Run([string]$Tool, [string[]]$Arguments) {
    Write-Host "> $Tool $($Arguments -join ' ')"
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Tool @Arguments; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "$Tool failed with exit code $code." }
}
function Json([string]$Url) {
    $headers = @{'User-Agent'='SYNTRIX-Updater'}
    if ($env:GITHUB_TOKEN) { $headers.Authorization = 'Bearer ' + $env:GITHUB_TOKEN }
    elseif ($env:GH_TOKEN) { $headers.Authorization = 'Bearer ' + $env:GH_TOKEN }
    Invoke-RestMethod -Uri $Url -Headers $headers
}
function Download([string]$Url, [string]$Destination, [string]$Sha256='') {
    if ((Test-Path -LiteralPath $Destination) -and (!$Sha256 -or (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -eq $Sha256)) { return }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Destination)
    $partial = $Destination + '.partial'
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $partial
    if ($Sha256 -and (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $Sha256) { throw "Download integrity check failed: $Destination" }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}
function WorkflowValue([string]$Name) {
    $match = [regex]::Match($workflow, ('(?m)^  ' + [regex]::Escape($Name) + ':\s*["'']([^"'']+)["'']'))
    if (!$match.Success) { throw "Cannot resolve upstream tool version: $Name" }
    $match.Groups[1].Value
}
$null = New-Item -ItemType Directory -Force -Path $ToolchainRoot
$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (!$git) {
    $gitExe = Join-Path $ToolchainRoot 'git/cmd/git.exe'
    if (!(Test-Path -LiteralPath $gitExe)) {
        $release = Json 'https://api.github.com/repos/git-for-windows/git/releases/latest'
        $asset = $release.assets | Where-Object { $_.name -like 'PortableGit-*-64-bit.7z.exe' } | Select-Object -First 1
        if (!$asset -or $asset.digest -notmatch '^sha256:([0-9a-f]{64})$') { throw 'No verified Git for Windows portable package.' }
        $archive = Join-Path $ToolchainRoot ('downloads/' + $asset.name)
        Download $asset.browser_download_url $archive $asset.digest.Substring(7)
        Run $archive @('-y',('-o' + (Join-Path $ToolchainRoot 'git')))
    }
    $env:PATH = (Split-Path $gitExe) + ';' + $env:PATH
}
if ($GitOnly) { return }
if (!$Source) { throw 'A prepared source checkout is required.' }
$workflow = [IO.File]::ReadAllText((Join-Path $Source '.github/workflows/flutter-build.yml'))
$rust = WorkflowValue 'RUST_VERSION'
if ($rust -match '^\d+\.\d+$') { $rust += '.0' }
$rust += '-x86_64-pc-windows-msvc'
$flutterVersion = WorkflowValue 'FLUTTER_VERSION'
$vcpkgPin = WorkflowValue 'VCPKG_COMMIT_ID'
$llvmVersion = WorkflowValue 'LLVM_VERSION'
if ($vcpkgPin -notmatch '^[0-9a-f]{40}$') { throw 'Invalid upstream vcpkg revision.' }
$vswhere = Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Microsoft Visual Studio/Installer/vswhere.exe'
$visualStudio = $null
if (Test-Path -LiteralPath $vswhere) {
    $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath
}
if (!$visualStudio) {
    $installer = Join-Path $ToolchainRoot 'downloads/vs_buildtools.exe'
    if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer }
    Download 'https://aka.ms/vs/17/release/vs_buildtools.exe' $installer
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'Visual Studio installer signature validation failed.' }
    $setup = Start-Process -FilePath $installer -ArgumentList '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended' -WindowStyle Hidden -Wait -PassThru
    if ($setup.ExitCode -eq 3010) { throw 'Windows restart required. Restart and rerun the updater.' }
    if ($setup.ExitCode -ne 0) { throw "Visual Studio setup failed: $($setup.ExitCode)." }
}
$env:RUSTUP_HOME = Join-Path $ToolchainRoot 'rustup'
$env:CARGO_HOME = Join-Path $ToolchainRoot 'cargo'
$env:RUSTUP_TOOLCHAIN = $rust
$env:PUB_CACHE = Join-Path $ToolchainRoot 'pub-cache'
$env:VCPKG_ROOT = Join-Path $ToolchainRoot 'vcpkg'
$env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
$env:GIT_TERMINAL_PROMPT = '0'
$env:GIT_CONFIG_GLOBAL = Join-Path $ToolchainRoot 'syntrix-updater.gitconfig'
Run git @('config','--file',$env:GIT_CONFIG_GLOBAL,'core.longpaths','true')
Run git @('config','--file',$env:GIT_CONFIG_GLOBAL,'url.https://github.com/webmproject/libwebm.git.insteadOf','https://chromium.googlesource.com/webm/libwebm')
$env:PATH = (Join-Path $env:CARGO_HOME 'bin') + ';' + $env:PATH
$rustup = Join-Path $env:CARGO_HOME 'bin/rustup.exe'
if (!(Test-Path -LiteralPath $rustup)) {
    $url = 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe'
    $expected = ((Invoke-WebRequest -UseBasicParsing -Uri ($url + '.sha256')).Content.Trim() -split '\s+')[0]
    $installer = Join-Path $ToolchainRoot 'downloads/rustup-init.exe'
    Download $url $installer $expected
    Run $installer @('-y','--no-modify-path','--profile','minimal','--default-toolchain',$rust)
}
Run $rustup @('toolchain','install',$rust,'--profile','minimal','--component','rustfmt')
$flutterRoot = Join-Path $ToolchainRoot ('flutter-' + $flutterVersion)
$flutter = Join-Path $flutterRoot 'bin/flutter.bat'
if (!(Test-Path -LiteralPath $flutter)) {
    $existing = Join-Path $ToolchainRoot 'flutter/bin/cache/flutter.version.json'
    $existingVersion = ''
    if (Test-Path -LiteralPath $existing) { $existingVersion = (Get-Content -LiteralPath $existing -Raw | ConvertFrom-Json).frameworkVersion }
    if ($existingVersion -eq $flutterVersion) {
        $flutterRoot = Join-Path $ToolchainRoot 'flutter'
        $flutter = Join-Path $flutterRoot 'bin/flutter.bat'
    } else {
        $manifest = Invoke-RestMethod 'https://storage.googleapis.com/flutter_infra_release/flutter/releases/releases_windows.json'
        $sdk = $manifest.releases | Where-Object { $_.version -eq $flutterVersion -and (!$_.PSObject.Properties['dart_sdk_arch'] -or $_.dart_sdk_arch -eq 'x64') } | Select-Object -First 1
        if (!$sdk -or !$sdk.sha256) { throw "No official Windows x64 Flutter SDK $flutterVersion." }
        $archive = Join-Path $ToolchainRoot ('downloads/flutter-' + $flutterVersion + '.zip')
        Download ($manifest.base_url + '/' + $sdk.archive) $archive $sdk.sha256
        $expanded = Join-Path $ToolchainRoot ('expand-flutter-' + $flutterVersion)
        $null = New-Item -ItemType Directory -Force -Path $expanded
        Run tar.exe @('-xf',$archive,'-C',$expanded)
        $resolved = [IO.Path]::GetFullPath((Join-Path $expanded 'flutter'))
        if (!$resolved.StartsWith([IO.Path]::GetFullPath($ToolchainRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar)) { throw 'SDK extraction escaped the toolchain root.' }
        Move-Item -LiteralPath $resolved -Destination $flutterRoot
    }
}
$mapFile = Join-Path $flutterRoot 'packages/flutter_tools/lib/src/windows/visual_studio.dart'
$mapping = [IO.File]::ReadAllText($mapFile)
if (!$mapping.Contains("18 => 'Visual Studio 18 2026',") -and $mapping.Contains("17 => 'Visual Studio 17 2022',")) {
    [IO.File]::WriteAllText($mapFile, $mapping.Replace("17 => 'Visual Studio 17 2022',", "18 => 'Visual Studio 18 2026'," + [Environment]::NewLine + "      17 => 'Visual Studio 17 2022',"))
    $stamp = Join-Path $flutterRoot 'bin/cache/flutter_tools.stamp'
    if (Test-Path -LiteralPath $stamp) { Remove-Item -LiteralPath $stamp }
}
$dropdown = Join-Path $Source '.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff'
if ($flutterVersion -eq '3.24.5' -and (Test-Path -LiteralPath $dropdown)) {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & git -C $flutterRoot apply --reverse --check $dropdown 2>$null
    $alreadyPatched = $LASTEXITCODE -eq 0
    $ErrorActionPreference = $previous
    if (!$alreadyPatched) { Run git @('-C',$flutterRoot,'apply','--check',$dropdown); Run git @('-C',$flutterRoot,'apply',$dropdown) }
}
$env:PATH = (Split-Path $flutter) + ';' + $env:PATH
Run $flutter @('precache','--windows')
if ($workflow.Contains('rustdesk/engine/releases/download/main/windows-x64-release.zip')) {
    $engineRelease = Json 'https://api.github.com/repos/rustdesk/engine/releases/tags/main'
    $engine = $engineRelease.assets | Where-Object { $_.name -eq 'windows-x64-release.zip' } | Select-Object -First 1
    if (!$engine -or $engine.digest -notmatch '^sha256:([0-9a-f]{64})$') { throw 'No SHA-256-verified custom Windows Flutter engine.' }
    $archive = Join-Path $ToolchainRoot ('downloads/engine-' + $engine.digest.Substring(7) + '.zip')
    Download $engine.browser_download_url $archive $engine.digest.Substring(7)
    Run tar.exe @('-xf',$archive,'-C',(Join-Path $flutterRoot 'bin/cache/artifacts/engine/windows-x64-release'))
}
if (!(Test-Path -LiteralPath (Join-Path $env:VCPKG_ROOT '.git'))) { Run git @('clone','https://github.com/microsoft/vcpkg.git',$env:VCPKG_ROOT) }
Run git @('-C',$env:VCPKG_ROOT,'fetch','origin',$vcpkgPin)
Run git @('-C',$env:VCPKG_ROOT,'checkout','--detach',$vcpkgPin)
if (!(Test-Path -LiteralPath (Join-Path $env:VCPKG_ROOT 'vcpkg.exe'))) { Run (Join-Path $env:VCPKG_ROOT 'bootstrap-vcpkg.bat') @('-disableMetrics') }
Run (Join-Path $env:VCPKG_ROOT 'vcpkg.exe') @('install','--triplet','x64-windows-static',('--x-install-root=' + (Join-Path $env:VCPKG_ROOT 'installed')))
$nativeTools = Get-ChildItem -LiteralPath (Join-Path $env:VCPKG_ROOT 'downloads/tools') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('cmake.exe','nasm.exe','ninja.exe') } | Select-Object -ExpandProperty DirectoryName -Unique
$env:PATH = (@($nativeTools) + $env:PATH) -join ';'
$pythonVersion = (& $Python -c 'import sys; print(str(sys.version_info.major)+"."+str(sys.version_info.minor))' | Out-String).Trim()
$pythonPackages = Join-Path $ToolchainRoot ('python-tools/' + $pythonVersion + '-llvm-' + $llvmVersion)
if (!(Test-Path -LiteralPath (Join-Path $pythonPackages 'clang/native/libclang.dll'))) {
    Run $Python @('-m','pip','install','--only-binary=:all:','--target',$pythonPackages,('libclang==' + $llvmVersion),'brotli==1.2.1')
}
$env:PYTHONPATH = $pythonPackages
$env:LIBCLANG_PATH = Join-Path $pythonPackages 'clang/native'
$env:SYNTRIX_FLUTTER = $flutter
Write-Host "Toolchain ready: Rust $rust; Flutter $flutterVersion; vcpkg $vcpkgPin; LLVM $llvmVersion"
