#Requires -Version 5.1
<#
  deploy.ps1 — локальное развёртывание wkbdy2api под Windows.

  Что делает:
    1. проверяет Node.js (>= 20) и ставит pnpm при отсутствии (corepack / npm);
    2. клонирует или обновляет репозиторий;
    3. разрешает postinstall-скрипт esbuild (иначе pnpm 12 падает с
       ERR_PNPM_IGNORED_BUILDS);
    4. устанавливает зависимости, создаёт .env, ключ хранилища аккаунтов и
       каталог data/;
    5. подготавливает снимок конфигурации для тестов, запускает typecheck и
       тесты;
    6. поднимает сервер через start.bat и печатает адреса и API-ключ.

  Запуск:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1 -SkipTests -NoStart
#>
[CmdletBinding()]
param(
  [string] $InstallDir = (Join-Path (Get-Location) 'WkBdy2api'),
  [string] $Repo = 'https://github.com/MixxxGit/WkBdy2api.git',
  [string] $Branch = 'feature/admin-i18n-ru-default',
  [switch] $SkipTests,
  [switch] $NoStart
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step { param([string] $Text) Write-Host "[..] $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Text) Write-Host "[ok] $Text" -ForegroundColor Green }
function Write-Warn { param([string] $Text) Write-Host "[!]  $Text" -ForegroundColor Yellow }
function Fail       { param([string] $Text) Write-Host "[xx] $Text" -ForegroundColor Red; exit 1 }

# Внешнюю команду запускаем с Continue: иначе stderr от pnpm/git в PowerShell 5.1
# превращается в terminating error при $ErrorActionPreference = 'Stop'.
function Invoke-Native {
  param([string] $Exe, [string[]] $Arguments = @())
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
  if ($null -eq $code) { $code = 0 }
  return [pscustomobject]@{ Code = [int] $code; Output = ($output | Out-String).Trim() }
}

function Get-RandomBytes {
  param([int] $Count)
  $bytes = New-Object 'byte[]' $Count
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return $bytes
}

function Resolve-EnvValue {
  param([string] $Path, [string] $Name)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match "^\s*$Name\s*=\s*(.*)\s*$") { return $Matches[1].Trim() }
  }
  return $null
}

Write-Host ''
Write-Host '=== wkbdy2api :: local Windows deployment ===' -ForegroundColor White
Write-Host ''

# --- 1. Node.js -------------------------------------------------------------
Write-Step 'checking Node.js'
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Fail 'Node.js is not installed or not in PATH. Install Node.js 20+ from https://nodejs.org and re-run.'
}
$nodeVersion = (& node -v).Trim()
$nodeMajor = [int] (($nodeVersion -replace '^v', '') -split '\.')[0]
if ($nodeMajor -lt 20) {
  Fail "Node.js $nodeVersion found, but version 20 or newer is required."
}
Write-Ok "Node.js $nodeVersion"

# --- 2. pnpm ----------------------------------------------------------------
Write-Step 'checking pnpm'
if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
  Write-Warn 'pnpm not found, installing'
  $corepack = Invoke-Native 'corepack' @('enable')
  if ($corepack.Code -eq 0) { $null = Invoke-Native 'corepack' @('prepare', 'pnpm@latest', '--activate') }
  if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    $npmInstall = Invoke-Native 'npm' @('install', '-g', 'pnpm@9')
    if ($npmInstall.Code -ne 0) { Fail "cannot install pnpm.`n$($npmInstall.Output)" }
  }
  if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) { Fail 'pnpm is still unavailable in PATH. Reopen the shell and re-run.' }
}
Write-Ok "pnpm $(( & pnpm -v ).Trim())"

# --- 3. git + исходники -----------------------------------------------------
Write-Step 'checking git'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Fail 'git is not installed or not in PATH. Install Git for Windows from https://git-scm.com and re-run.'
}
Write-Ok 'git found'

if (Test-Path -LiteralPath (Join-Path $InstallDir '.git')) {
  Write-Step "updating existing checkout: $InstallDir"
  $fetch = Invoke-Native 'git' @('-C', $InstallDir, 'fetch', '--all', '--prune')
  if ($fetch.Code -ne 0) { Write-Warn "git fetch failed: $($fetch.Output)" }
  $checkout = Invoke-Native 'git' @('-C', $InstallDir, 'checkout', $Branch)
  if ($checkout.Code -ne 0) { Fail "git checkout $Branch failed: $($checkout.Output)" }
  $pull = Invoke-Native 'git' @('-C', $InstallDir, 'pull', '--ff-only', 'origin', $Branch)
  if ($pull.Code -ne 0) { Write-Warn "git pull failed (continuing with local copy): $($pull.Output)" }
} elseif (Test-Path -LiteralPath $InstallDir) {
  if ((Get-ChildItem -LiteralPath $InstallDir -Force | Measure-Object).Count -gt 0) {
    Fail "directory '$InstallDir' already exists and is not a git checkout. Pass -InstallDir with an empty path."
  }
} else {
  Write-Step "cloning $Repo ($Branch) -> $InstallDir"
  $clone = Invoke-Native 'git' @('clone', '--branch', $Branch, $Repo, $InstallDir)
  if ($clone.Code -ne 0) { Fail "git clone failed: $($clone.Output)" }
}
if (-not (Test-Path -LiteralPath $InstallDir)) { Fail "install directory '$InstallDir' was not created." }
Write-Ok "sources ready: $InstallDir"

Push-Location -LiteralPath $InstallDir
try {

  # --- 4. разрешить сборку esbuild ------------------------------------------
  # pnpm 10+ блокирует postinstall-скрипты; без этого install падает с
  # ERR_PNPM_IGNORED_BUILDS, а tsx остаётся без бинарника esbuild.
  $workspaceFile = Join-Path $InstallDir 'pnpm-workspace.yaml'
  if (-not (Test-Path -LiteralPath $workspaceFile)) {
    Write-Step 'allowing esbuild postinstall (pnpm-workspace.yaml)'
    "allowBuilds:`n  esbuild: true`n" | Set-Content -LiteralPath $workspaceFile -Encoding ascii -NoNewline
  }

  # --- 5. зависимости -------------------------------------------------------
  Write-Step 'installing dependencies (pnpm install)'
  $install = Invoke-Native 'pnpm' @('install')
  if ($install.Code -ne 0) {
    if ($install.Output -match 'IGNORED_BUILDS|approve-builds') {
      Write-Warn 'build scripts are blocked, approving and retrying'
      $null = Invoke-Native 'pnpm' @('approve-builds', '--yes', '--all')
      $install = Invoke-Native 'pnpm' @('install')
    }
    if ($install.Code -ne 0) { Fail "pnpm install failed:`n$($install.Output)" }
  }
  Write-Ok 'dependencies installed'

  # --- 6. .env --------------------------------------------------------------
  $envFile = Join-Path $InstallDir '.env'
  $exampleFile = Join-Path $InstallDir '.env.example'
  if (-not (Test-Path -LiteralPath $envFile)) {
    Write-Step 'creating .env from .env.example'
    if (-not (Test-Path -LiteralPath $exampleFile)) { Fail '.env.example not found, nothing to bootstrap the config from.' }
    $apiKey = 'wkb-' + [BitConverter]::ToString((Get-RandomBytes 24)).Replace('-', '').ToLowerInvariant()
    $content = Get-Content -LiteralPath $exampleFile
    $content = $content -replace '^WKB2API_API_KEY=.*$', "WKB2API_API_KEY=$apiKey"
    Set-Content -LiteralPath $envFile -Value $content -Encoding utf8
    Write-Ok 'generated .env with a random API key'
  } else {
    Write-Ok '.env already exists, keeping it'
  }
  $apiKey = Resolve-EnvValue -Path $envFile -Name 'WKB2API_API_KEY'
  if ([string]::IsNullOrWhiteSpace($apiKey) -or $apiKey.Length -lt 16) {
    Fail 'WKB2API_API_KEY in .env is missing or shorter than 16 characters.'
  }

  # --- 7. ключ хранилища аккаунтов -----------------------------------------
  $keyFile = Join-Path $InstallDir 'account-store.key'
  if (-not (Test-Path -LiteralPath $keyFile)) {
    Write-Step 'generating account-store.key (32 bytes, base64)'
    [System.IO.File]::WriteAllText($keyFile, [Convert]::ToBase64String((Get-RandomBytes 32)))
    Write-Ok 'account-store.key created (keep it secret and back it up)'
  } else {
    Write-Ok 'account-store.key already exists, keeping it'
  }

  # --- 8. служебные каталоги и снимок конфигурации -------------------------
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'data')
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'logs')

  # Тесты читают wb_v3config_live.json; в репозитории лежит только публичный
  # снимок, поэтому делаем из него копию под ожидаемым именем.
  $liveConfig = Join-Path $InstallDir 'wb_v3config_live.json'
  $publicConfig = Join-Path $InstallDir 'wb_v3config.public.json'
  if (-not (Test-Path -LiteralPath $liveConfig) -and (Test-Path -LiteralPath $publicConfig)) {
    Write-Step 'preparing wb_v3config_live.json for tests'
    Copy-Item -LiteralPath $publicConfig -Destination $liveConfig
  }

  # --- 9. проверки ----------------------------------------------------------
  if ($SkipTests) {
    Write-Warn 'skipping typecheck and tests (-SkipTests)'
  } else {
    Write-Step 'running typecheck'
    $typecheck = Invoke-Native 'pnpm' @('typecheck')
    if ($typecheck.Code -ne 0) { Fail "typecheck failed:`n$($typecheck.Output)" }
    Write-Ok 'typecheck passed'

    Write-Step 'running tests'
    $tests = Invoke-Native 'pnpm' @('test')
    if ($tests.Code -ne 0) { Fail "tests failed:`n$($tests.Output)" }
    Write-Ok 'tests passed'
  }

  # --- 10. запуск -----------------------------------------------------------
  $host_ = Resolve-EnvValue -Path $envFile -Name 'HOST'; if (-not $host_) { $host_ = '127.0.0.1' }
  $port = Resolve-EnvValue -Path $envFile -Name 'PORT'; if (-not $port) { $port = '7891' }

  if ($NoStart) {
    Write-Warn 'server not started (-NoStart)'
  } else {
    Write-Step 'starting server (start.bat)'
    $start = Invoke-Native 'cmd.exe' @('/c', 'start.bat')
    $start.Output -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "     $_" }
    if ($start.Code -ne 0) { Fail "start.bat failed with code $($start.Code)" }
    $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if (-not $listener) { Fail "port $port is not listening. See logs\server.log" }
    Write-Ok "server is listening on ${host_}:${port}"
  }

  Write-Host ''
  Write-Host '=== deployment finished ===' -ForegroundColor White
  Write-Host "  install dir : $InstallDir"
  Write-Host "  api         : http://${host_}:${port}/v1/models"
  Write-Host "  admin panel : http://${host_}:${port}/admin"
  Write-Host "  api key     : $apiKey"
  Write-Host "  logs        : $(Join-Path $InstallDir 'logs\server.log')"
  Write-Host "  stop        : $(Join-Path $InstallDir 'stop.bat')"
  Write-Host ''
} finally {
  Pop-Location
}
