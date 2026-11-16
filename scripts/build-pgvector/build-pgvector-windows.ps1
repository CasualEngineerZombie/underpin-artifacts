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

    The build is pgvector's own documented Windows path (nmake with
    Makefile.win, against an installed PostgreSQL's pg_config), and the
    verification step loads the built extension and computes a vector with it:
    a build that compiles but does not load is worse than no build.

    The output is the layout a package manager installs:

        lib/vector.dll
        share/extension/vector.control
        share/extension/vector*.sql

.PARAMETER Version
    The upstream pgvector tag to build (default: v0.8.6).

.PARAMETER OutDir
    Where the packaged tree is written (default: ./out).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-pgvector-windows.ps1
#>
[CmdletBinding()]
param(
    [string]$Version = $(if ($env:PGVECTOR_VERSION) { $env:PGVECTOR_VERSION } else { 'v0.8.6' }),
    [string]$OutDir = $(if ($env:OUT_DIR) { $env:OUT_DIR } else { 'out' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "==> $Message" }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir = Join-Path $here 'src'
$pgConfig = (Get-Command pg_config -ErrorAction Stop).Source
Write-Step "building pgvector $Version against $pgConfig"

if (Test-Path $srcDir) { Remove-Item -Recurse -Force $srcDir }
New-Item -ItemType Directory -Force $srcDir | Out-Null
$repo = Join-Path $srcDir 'pgvector'
git clone --depth 1 --branch $Version https://github.com/pgvector/pgvector.git $repo
if ($LASTEXITCODE -ne 0) { throw "could not check out pgvector $Version" }

Push-Location $repo
try {
    # pgvector's own Windows build file; PG_CONFIG points it at the
    # PostgreSQL whose headers and libs it compiles against.
    $env:PG_CONFIG = $pgConfig
    nmake /F Makefile.win
    if ($LASTEXITCODE -ne 0) { throw 'the pgvector build failed' }
    nmake /F Makefile.win install
    if ($LASTEXITCODE -ne 0) { throw 'the pgvector install step failed' }
}
finally { Pop-Location }

# --- verify: the extension must LOAD and compute, not merely compile ---
Write-Step 'verifying the built extension'
$pgRoot = Split-Path -Parent (Split-Path -Parent $pgConfig)   # ...\bin\pg_config.exe -> ...\
$libDir = Join-Path $pgRoot 'lib'
$shareDir = Join-Path $pgRoot 'share\extension'

$verifyDb = "pgvector_verify_$PID"
& psql -v ON_ERROR_STOP=1 -d postgres -c "CREATE DATABASE $verifyDb"
if ($LASTEXITCODE -ne 0) { throw 'could not create the verification database' }
try {
    & psql -v ON_ERROR_STOP=1 -d $verifyDb -c 'CREATE EXTENSION vector'
    if ($LASTEXITCODE -ne 0) { throw 'the built extension does not load' }
    & psql -v ON_ERROR_STOP=1 -d $verifyDb -c 'CREATE TABLE v (id serial primary key, e vector(3))'
    & psql -v ON_ERROR_STOP=1 -d $verifyDb -c "INSERT INTO v (e) VALUES ('[1,0,0]')"
    $dist = (& psql -v ON_ERROR_STOP=1 -t -A -d $verifyDb -c 'SELECT round((e <=> ''[1,0,0]'')::numeric, 6) FROM v LIMIT 1').Trim()
    if ($dist -ne '0') { throw "the vector distance came back as '$dist', want 0" }
    Write-Step 'the built extension loads and computes'
}
finally {
    & psql -v ON_ERROR_STOP=1 -d postgres -c "DROP DATABASE IF EXISTS $verifyDb" | Out-Null
}

# --- package: the layout a package manager installs ---
if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Force (Join-Path $OutDir 'lib') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $OutDir 'share\extension') | Out-Null

Copy-Item (Join-Path $libDir 'vector.dll') (Join-Path $OutDir 'lib') -Force
Copy-Item (Join-Path $shareDir 'vector.control') (Join-Path $OutDir 'share\extension') -Force
Copy-Item (Join-Path $shareDir 'vector*.sql') (Join-Path $OutDir 'share\extension') -Force

Write-Step "packaged the extension into $OutDir"
Get-ChildItem -Recurse -File $OutDir | ForEach-Object { $_.FullName }
