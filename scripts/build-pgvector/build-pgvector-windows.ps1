<#
.SYNOPSIS
    build-pgvector-windows.ps1 — build pgvector FROM SOURCE for Windows and
    package it as a relocatable extension tree.

.DESCRIPTION
    The desktop install needs a pgvector build for the PostgreSQL it
    provisions. Upstream pgvector publishes NO Windows binaries (building it
    needs the MSVC toolchain), so the Windows artifact has historically come
    from a third-party community build. This script builds it ourselves, from a
    pinned upstream tag, in our own CI — which takes the third-party binary
    out of the install's trust boundary.

    It builds against, and verifies against, THE EXACT PostgreSQL TREE THE
    INSTALL SHIPS: the EDB "binaries without installer" archive, unpacked, and
    started from a scratch cluster here. Verifying against some separately
    installed PostgreSQL would only prove that the extension loads into THAT
    server, which is not the question the check exists to answer.

    The build is pgvector's own documented Windows path (nmake with
    Makefile.win), and the verification step loads the built extension and
    computes a vector with it: a build that compiles but does not load is worse
    than no build.

    The output is the layout a package manager installs:

        lib/vector.dll
        share/extension/vector.control
        share/extension/vector*.sql

.PARAMETER Version
    The upstream pgvector tag to build (default: v0.8.6).

.PARAMETER OutDir
    Where the packaged tree is written (default: ./out).

.PARAMETER PgRoot
    The PostgreSQL tree to build against — the one the install ships
    (default: $env:PG_ROOT, else the tree that pg_config on PATH belongs to).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-pgvector-windows.ps1
#>
[CmdletBinding()]
param(
    [string]$Version = $(if ($env:PGVECTOR_VERSION) { $env:PGVECTOR_VERSION } else { 'v0.8.6' }),
    [string]$OutDir = $(if ($env:OUT_DIR) { $env:OUT_DIR } else { 'out' }),
    [string]$PgRoot = $env:PG_ROOT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "==> $Message" }

# Native commands do NOT throw on a non-zero exit under $ErrorActionPreference,
# so every one of them is checked explicitly. A build step that fails quietly
# and leaves a half-built tree is exactly the failure this check prevents.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$([System.IO.Path]::GetFileName($Exe)) $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

# nmake and cl.exe live INSIDE the Visual Studio installation and are not on
# PATH by default: the command that exports them is vcvars64.bat, which sets
# its variables in the cmd.exe process that runs it. Run it there, ask that
# process to print its environment, and re-export every variable into this
# one -- otherwise `nmake` is simply "not recognized" and the build never
# starts (which is exactly how the first CI run of this script failed).
#
# CC=cl comes from that environment too, and pgvector's Makefile.win uses
# $(CC): entering the environment is what supplies the compiler, not just PATH.
function Enter-MsvcToolchain {
    if (Get-Command nmake -ErrorAction SilentlyContinue) { return }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe is missing at $vswhere - this machine has no Visual Studio installer"
    }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw 'no Visual Studio installation carries the C++ toolchain (vswhere found none)' }
    $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path $vcvars)) { throw "vcvars64.bat is missing at $vcvars" }

    # /s strips only the outer quotes, so the quoted batch path survives;
    # `set` with no arguments prints the environment as NAME=VALUE, which is
    # how vcvars64.bat's exports get back here (PATH, INCLUDE, LIB, CC).
    $envLines = cmd /s /c "call `"$vcvars`" >nul && set"
    foreach ($line in $envLines) {
        $eq = $line.IndexOf('=')
        if ($eq -gt 0) { Set-Item -Path ('env:' + $line.Substring(0, $eq)) -Value $line.Substring($eq + 1) }
    }
    if (-not (Get-Command nmake -ErrorAction SilentlyContinue)) {
        throw 'nmake is still not on PATH after entering the MSVC environment'
    }
    Write-Step "entered the MSVC environment: $vs"
}

# ANCHOR THE OUTPUT DIRECTORY before anything changes directory, for the same
# reason the Linux script does: the build happens in the checked-out source
# tree, and a relative OutDir would be resolved against it.
$invocationDir = (Get-Location).Path
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $invocationDir $OutDir }

if (-not $PgRoot) {
    $pgConfig = (Get-Command pg_config -ErrorAction Stop).Source
    # ...\bin\pg_config.exe -> ...\ (the tree root)
    $PgRoot = Split-Path -Parent (Split-Path -Parent $pgConfig)
}
if (-not (Test-Path (Join-Path $PgRoot 'bin\pg_config.exe'))) {
    throw "PG_ROOT ($PgRoot) is not a PostgreSQL tree: bin\pg_config.exe is missing"
}
Write-Step "building pgvector $Version against $PgRoot"

Enter-MsvcToolchain

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir = Join-Path $here 'src'
if (Test-Path $srcDir) { Remove-Item -Recurse -Force $srcDir }
New-Item -ItemType Directory -Force $srcDir | Out-Null
$repo = Join-Path $srcDir 'pgvector'
Invoke-Native git @('clone', '--depth', '1', '--branch', $Version, 'https://github.com/pgvector/pgvector.git', $repo)

Push-Location $repo
try {
    # pgvector's own Windows build file. It does NOT read PG_CONFIG: it takes
    # the PostgreSQL tree from PGROOT (and errors out if PGROOT is unset), so
    # the environment variable nmake needs is PGROOT.
    $env:PGROOT = $PgRoot
    Invoke-Native nmake @('/F', 'Makefile.win')
    Invoke-Native nmake @('/F', 'Makefile.win', 'install')
}
finally { Pop-Location }

# --- verify: the extension must LOAD and compute, not merely compile ---
# The server is a scratch cluster started from THE SHIPPED TREE, on its own
# port and data directory, and it is torn down again whatever happens.
Write-Step 'verifying the built extension'
$binDir = Join-Path $PgRoot 'bin'
$libDir = Join-Path $PgRoot 'lib'
$shareDir = Join-Path $PgRoot 'share\extension'
$psql = Join-Path $binDir 'psql.exe'

$verifyDir = Join-Path ([System.IO.Path]::GetTempPath()) "pgvector-verify-$PID"
$dataDir = Join-Path $verifyDir 'data'
$verifyPort = 55440
$verifyDb = 'pgvector_verify'
New-Item -ItemType Directory -Force $verifyDir | Out-Null

$started = $false
try {
    Invoke-Native (Join-Path $binDir 'initdb.exe') @('-D', $dataDir, '-U', 'postgres', '--no-locale')
    $started = $true
    $serverLog = Join-Path $verifyDir 'server.log'
    try {
        Invoke-Native (Join-Path $binDir 'pg_ctl.exe') @('-D', $dataDir, '-o', "-p $verifyPort", '-w', '-l', $serverLog, 'start')
    }
    catch {
        if (Test-Path $serverLog) { Get-Content $serverLog | ForEach-Object { Write-Host "    $_" } }
        throw
    }

    $psqlArgs = @('-h', '127.0.0.1', '-p', $verifyPort, '-U', 'postgres', '-v', 'ON_ERROR_STOP=1')
    Invoke-Native $psql ($psqlArgs + @('-d', 'postgres', '-c', "CREATE DATABASE $verifyDb"))
    $db = $psqlArgs + @('-d', $verifyDb)
    Invoke-Native $psql ($db + @('-c', 'CREATE EXTENSION vector'))
    Write-Step 'the built extension loads'
    Invoke-Native $psql ($db + @('-c', 'CREATE TABLE v (id serial primary key, e vector(3))'))
    Invoke-Native $psql ($db + @('-c', "INSERT INTO v (e) VALUES ('[1,0,0]')")) | Out-Null
    $dist = (Invoke-Native $psql ($db + @('-t', '-A', '-c', "SELECT round((e <=> '[1,0,0]')::numeric, 6) FROM v LIMIT 1"))).Trim()
    # The comparison is NUMERIC, not textual: the value arrives as
    # "0.000000", and a string comparison against "0" fails a check whose
    # subject is in fact correct. (The Linux script learned this the same
    # way; this one learned it from the first Windows run of this workflow.)
    $distance = 0.0
    if (-not [double]::TryParse($dist, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$distance) -or $distance -ne 0) {
        throw "the vector distance came back as '$dist', want 0"
    }
    Write-Step 'the built extension computes a vector'
}
finally {
    if ($started -and (Test-Path (Join-Path $dataDir 'postmaster.pid'))) {
        & (Join-Path $binDir 'pg_ctl.exe') @('-D', $dataDir, '-m', 'immediate', 'stop') | Out-Null
    }
    if (Test-Path $verifyDir) { Remove-Item -Recurse -Force $verifyDir -ErrorAction SilentlyContinue }
}

# --- package: the layout a package manager installs ---
if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Force (Join-Path $OutDir 'lib') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $OutDir 'share\extension') | Out-Null

Copy-Item (Join-Path $libDir 'vector.dll') (Join-Path $OutDir 'lib') -Force
Copy-Item (Join-Path $shareDir 'vector.control') (Join-Path $OutDir 'share\extension') -Force
Copy-Item (Join-Path $shareDir 'vector*.sql') (Join-Path $OutDir 'share\extension') -Force

Write-Step "packaged the extension into $OutDir"
$packaged = @(Get-ChildItem -Recurse -File $OutDir)
if ($packaged.Count -lt 3) {
    throw "the packaged tree carries only $($packaged.Count) file(s); expected the DLL, the control file and at least one SQL script"
}
$packaged | ForEach-Object { $_.FullName }
