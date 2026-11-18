# Run in a dedicated PowerShell process. The build uses a disposable checkout.
[CmdletBinding()]
param(
    [string]$CacheRoot = (Join-Path $env:LOCALAPPDATA 'SyntrixPublicBuild'),
    [switch]$SourceOnly,
    [switch]$PrepareOnly,
    [switch]$UseInstalledNativeDependencies
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($env:OS -ne 'Windows_NT' -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') {
    throw 'Run this script with x64 PowerShell on Windows.'
}

function Run([string]$Tool, [string[]]$Arguments) {
    Write-Host "> $Tool $($Arguments -join ' ')"
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Tool exited with code $LASTEXITCODE." }
}

function Download([string]$Url, [string]$Path, [string]$Sha256 = '') {
    if (!(Test-Path -LiteralPath $Path)) {
        $partial = "$Path.partial"
        Run curl.exe @('--fail', '--location', '--retry', '3', '--silent',
            '--show-error', '--output', $partial, $Url)
        if ($Sha256 -and (Get-FileHash -LiteralPath $partial).Hash -ne $Sha256) {
            throw "SHA-256 mismatch for $Url."
        }
        Move-Item -LiteralPath $partial -Destination $Path
    }
    if ($Sha256 -and (Get-FileHash -LiteralPath $Path).Hash -ne $Sha256) {
        throw "SHA-256 mismatch for $Path."
    }
}

function Install-Package([string]$Id) {
    Run winget @('install', '--id', $Id, '--exact', '--source', 'winget',
        '--silent', '--disable-interactivity', '--accept-package-agreements',
        '--accept-source-agreements')
}

$root = $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $root 'source-manifest.json') -Raw |
    ConvertFrom-Json
$baseline = '95cca3f661f635b3cc85c04935fe8d96d8f432ef'
$vcpkgPin = '9e593bb18ea69cc5095e012465dcd675a822ed0d'
$rust = '1.75.0-x86_64-pc-windows-msvc'
$null = New-Item -ItemType Directory -Force -Path $CacheRoot
$physical = (Get-Item -LiteralPath $CacheRoot).FullName
$mapped = $null
$previousLocation = Get-Location

try {
    $cache = $physical
    if ($physical.Length -gt 8) {
        $letter = @('X','W','V','U','T','R','Q','P') |
            Where-Object { !(Test-Path "${_}:/") } | Select-Object -First 1
        if (!$letter) { throw 'No free drive letter is available for the build cache.' }
        Run subst.exe @("${letter}:", $physical)
        $mapped = "${letter}:"
        $cache = "$mapped\"
    }

    if (!(Get-Command git -ErrorAction SilentlyContinue)) {
        Install-Package 'Git.Git'
        $env:PATH = "$env:ProgramFiles\Git\cmd;$env:LOCALAPPDATA\Programs\Git\cmd;$env:PATH"
    }
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:CARGO_NET_GIT_FETCH_WITH_CLI = 'true'
    $env:GIT_CONFIG_GLOBAL = Join-Path $cache 'syntrix.gitconfig'
    Run git @('config','--file',$env:GIT_CONFIG_GLOBAL,'core.longpaths','true')
    Run git @('config','--file',$env:GIT_CONFIG_GLOBAL,
        'url.https://github.com/webmproject/libwebm.git.insteadOf',
        'https://chromium.googlesource.com/webm/libwebm')

    $patch = Join-Path $root 'SYNTRIX-vs-RustDesk-1.5.3.patch'
    $checkout = Join-Path $cache 'syntrix-public-1.5.3'
    if (!(Test-Path -LiteralPath $checkout)) {
        Run git @('clone','--branch','1.5.3','--depth','1',
            'https://github.com/rustdesk/rustdesk.git',$checkout)
    }
    Set-Location -LiteralPath $checkout
    $commit = git rev-parse HEAD
    if ($LASTEXITCODE -or $commit -ne $baseline) { throw 'Unexpected RustDesk baseline.' }
    Run git @('submodule','update','--init','--recursive')
    $submoduleCommit = git -C libs/hbb_common rev-parse HEAD
    if ($LASTEXITCODE -or $submoduleCommit -ne $manifest.hbbCommon) {
        throw 'Unexpected hbb_common revision.'
    }
    git apply --reverse --check --index $patch 2>$null
    if ($LASTEXITCODE) {
        Run git @('apply','--check','--index',$patch)
        Run git @('apply','--index',$patch)
    }
    $patchedTree = git write-tree
    if ($LASTEXITCODE -or $patchedTree -ne $manifest.patchedTree) {
        throw 'The patched checkout does not match the published source tree.'
    }
    Run git @('diff','--exit-code','--ignore-submodules=untracked')
    if ($SourceOnly) { Write-Host "Patched checkout: $physical\syntrix-public-1.5.3"; return }

    $python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $pythonReady = $false
    if ($python -and $python.Source -notlike '*\WindowsApps\python.exe') {
        & $python.Source -c 'import sys; sys.exit(sys.version_info < (3, 11))'
        $pythonReady = $LASTEXITCODE -eq 0
    }
    if (!$pythonReady) {
        Install-Package 'Python.Python.3.12'
        $env:PATH = "$env:LOCALAPPDATA\Programs\Python\Python312;$env:ProgramFiles\Python312;$env:PATH"
    }
    Run python @('--version')

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vs = $null
    if (Test-Path -LiteralPath $vswhere) {
        $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath
    }
    if (!$vs) {
        $installer = Join-Path $cache 'vs_buildtools.exe'
        Download 'https://aka.ms/vs/17/release/vs_buildtools.exe' $installer
        $installation = Start-Process -FilePath $installer -ArgumentList (
            '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
        ) -WindowStyle Hidden -PassThru -Wait
        if ($installation.ExitCode -eq 3010) { throw 'Restart Windows and rerun the build.' }
        if ($installation.ExitCode) { throw "Build Tools installer exited with code $($installation.ExitCode)." }
    }

    $env:CI = 'true'
    $env:RUSTUP_HOME = Join-Path $cache 'rustup'
    $env:CARGO_HOME = Join-Path $cache 'cargo'
    $env:PUB_CACHE = Join-Path $cache 'pub-cache'
    $env:VCPKG_ROOT = Join-Path $cache 'vcpkg'
    $env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
    $env:PYTHONPATH = Join-Path $cache 'python'
    $env:PATH = "$(Join-Path $env:CARGO_HOME 'bin');$(Join-Path $cache 'flutter/bin');$env:PATH"
    if (!(Test-Path -LiteralPath (Join-Path $env:CARGO_HOME 'bin/rustup.exe'))) {
        $installer = Join-Path $cache 'rustup-init.exe'
        Download 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' $installer
        Run $installer @('-y','--no-modify-path','--profile','minimal','--default-toolchain',$rust)
    }
    Run rustup @('toolchain','install',$rust,'--profile','minimal','--component','rustfmt')
    $env:RUSTUP_TOOLCHAIN = $rust

    $flutterRoot = Join-Path $cache 'flutter'
    $flutter = Join-Path $flutterRoot 'bin/flutter.bat'
    if (!(Test-Path -LiteralPath $flutter)) {
        $zip = Join-Path $cache 'flutter-3.24.5.zip'
        Download 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.24.5-stable.zip' $zip 'B8A7485ACD3C6FB23A76B7AC09F89E8D93D62FBFF7147C6F5F8C5686D949EEAC'
        Run tar.exe @('-xf',$zip,'-C',$cache)
    }
    $flutterPin = git -C $flutterRoot rev-parse HEAD
    if ($LASTEXITCODE -or $flutterPin -ne 'dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668') {
        throw 'The Flutter SDK is not at the required revision.'
    }
    $dropdown = Join-Path $checkout '.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff'
    git -C $flutterRoot apply --reverse --check $dropdown 2>$null
    if ($LASTEXITCODE) { Run git @('-C',$flutterRoot,'apply',$dropdown) }
    $studioMap = Join-Path $flutterRoot 'packages/flutter_tools/lib/src/windows/visual_studio.dart'
    $map = [IO.File]::ReadAllText($studioMap)
    if (!$map.Contains("18 => 'Visual Studio 18 2026',")) {
        $old = "17 => 'Visual Studio 17 2022',"
        if (!$map.Contains($old)) { throw 'Unexpected Flutter generator source.' }
        [IO.File]::WriteAllText($studioMap, $map.Replace($old, "18 => 'Visual Studio 18 2026',`n      $old"))
        $stamp = Join-Path $flutterRoot 'bin/cache/flutter_tools.stamp'
        if (Test-Path -LiteralPath $stamp) { Remove-Item -LiteralPath $stamp }
    }
    Run $flutter @('precache','--windows')
    $engine = Join-Path $cache 'rustdesk-engine-windows-x64-release.zip'
    Download 'https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip' $engine 'EC8CABF36EE4FF24C8D98DE25B00E70781EB03876265AEE84D0FE554A110036E'
    Run tar.exe @('-xf',$engine,'-C',(Join-Path $flutterRoot 'bin/cache/artifacts/engine/windows-x64-release'))

    if (!(Test-Path -LiteralPath $env:VCPKG_ROOT)) {
        Run git @('init',$env:VCPKG_ROOT)
        Run git @('-C',$env:VCPKG_ROOT,'fetch','--no-tags',
            'https://github.com/microsoft/vcpkg.git',$vcpkgPin)
        Run git @('-C',$env:VCPKG_ROOT,'checkout','--detach',$vcpkgPin)
    }
    $vcpkgHead = git -C $env:VCPKG_ROOT rev-parse HEAD
    if ($LASTEXITCODE -or $vcpkgHead -ne $vcpkgPin) { throw 'Unexpected vcpkg revision.' }
    if (!(Test-Path -LiteralPath (Join-Path $env:VCPKG_ROOT 'vcpkg.exe'))) {
        Run (Join-Path $env:VCPKG_ROOT 'bootstrap-vcpkg.bat') @('-disableMetrics')
    }
    if ($UseInstalledNativeDependencies) {
        $installed = Join-Path $env:VCPKG_ROOT 'installed/x64-windows-static'
        if (!(Test-Path -LiteralPath (Join-Path $installed 'lib') -PathType Container) -or
            !(Test-Path -LiteralPath (Join-Path $installed 'include') -PathType Container)) {
            throw 'The x64-windows-static dependency cache is missing.'
        }
    } else {
        Run (Join-Path $env:VCPKG_ROOT 'vcpkg.exe') @(
            'install','--triplet','x64-windows-static',"--x-install-root=$env:VCPKG_ROOT/installed")
    }
    $native = @(
        (Join-Path $env:VCPKG_ROOT 'downloads/tools/cmake-4.4.0-windows/cmake-4.4.0-windows-x86_64/bin'),
        (Join-Path $env:VCPKG_ROOT 'downloads/tools/nasm/nasm-3.01')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $env:PATH = (@($native) + $env:PATH) -join ';'

    Run python @('-m','pip','install','--only-binary=:all:','--target',$env:PYTHONPATH,'brotli==1.2.1','libclang==18.1.1')
    $env:LIBCLANG_PATH = Join-Path $env:PYTHONPATH 'clang/native'
    $ffigen = Join-Path $cache 'llvm-ffigen'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $ffigen 'bin')
    Copy-Item -LiteralPath (Join-Path $env:LIBCLANG_PATH 'libclang.dll') -Destination (Join-Path $ffigen 'bin')
    $env:RUST_LOG = 'info'
    foreach ($tool in @(@{ Crate='cargo-expand'; Version='1.0.95'; Extra=@() },
                         @{ Crate='flutter_rust_bridge_codegen'; Version='1.80.1'; Extra=@('--features','uuid') })) {
        if (!(Test-Path -LiteralPath (Join-Path $env:CARGO_HOME "bin/$($tool.Crate).exe"))) {
            Run cargo (@('install',$tool.Crate,'--version',$tool.Version,'--locked') + $tool.Extra)
        }
    }
    Push-Location flutter
    try { Run $flutter @('pub','get','--enforce-lockfile') }
    finally { Pop-Location }
    Run flutter_rust_bridge_codegen @('--skip-add-mod-to-lib','--llvm-path',$ffigen,
        '--rust-input','./src/flutter_ffi.rs','--dart-output','./flutter/lib/generated_bridge.dart',
        '--c-output','./flutter/macos/Runner/bridge_generated.h')
    if ($PrepareOnly) { Write-Host "Prepared checkout: $physical\syntrix-public-1.5.3"; return }

    $env:CARGO_TARGET_DIR = Join-Path $checkout 'target'
    Run cargo @('build','--locked','--release','--features','hwcodec,vram,flutter','--lib')
    $target = (Get-Item -LiteralPath 'flutter/windows/flutter/ephemeral/.plugin_symlinks/flutter_gpu_texture_renderer').Target
    $include = Join-Path $env:PUB_CACHE "git/$(Split-Path -Leaf $target.TrimEnd('\','/'))/windows"
    $previousCl = $env:CL
    $env:CL = "/I`"$include`" /I`"$include/include`" $previousCl"
    try {
        Run python @('build.py','--portable','--flutter','--skip-portable-pack','--hwcodec','--vram','--skip-cargo')
    }
    finally { $env:CL = $previousCl }

    $runner = Join-Path $checkout 'flutter/build/windows/x64/runner/Release/rustdesk.exe'
    $version = (& $runner --version | Out-String).Trim()
    if ($LASTEXITCODE -or $version -ne '1.5.3') { throw "Unexpected runner version: $version." }
    $nativeLibrary = Join-Path (Split-Path -Parent $runner) 'librustdesk.dll'
    Run python @((Join-Path $root 'normalize-diagnostics.py'),$nativeLibrary)
    & ./scripts/package-windows.ps1 -ToolchainRoot $cache
    $artifact = Join-Path $checkout 'dist/windows-x64/portable/SYNTRIX-1.5.3-x64-portable.exe'
    Run python @((Join-Path $root 'package-release.py'),$artifact,(Join-Path $root 'release'))
    $published = Join-Path $root 'release/SYNTRIX-1.5.3-x64-portable.exe'
    Run python @((Join-Path $root 'package-release.py'),$published,'--verify')
}
finally {
    Set-Location -LiteralPath $previousLocation.Path
    if ($mapped) { Run subst.exe @($mapped,'/D') }
}
