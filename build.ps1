<# =====================================================================
build.ps1 — build rm-xochitl-kbdpatch (Windows -> reMarkable 2 armv7)
Outputs:
  .\dist\Install.ps1
  .\dist\Rollback.ps1
  .\dist\scripts\...
===================================================================== #>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------
# Paths / config
# -----------------------
$Root   = $PSScriptRoot
$Proj   = Join-Path $Root "rm-xochitl-kbdpatch"
$Target = "armv7-unknown-linux-musleabihf"

$CargoToml = Join-Path $Proj "Cargo.toml"
$MainRs    = Join-Path $Proj "src\main.rs"

$KeyboardJsonSrc = Join-Path $Root "keyboard_layout.json"
$FontSrc         = Join-Path $Root "hebrew.ttf"
$DeployScriptSrc = Join-Path $Root "deploy.ps1"
$DeployStaticDirSrc = Join-Path $Root "static"

$DistDir   = Join-Path $Root "dist"
$DistScriptsDir = Join-Path $DistDir "scripts"
$BinLocal  = Join-Path $Proj "target\$Target\release\rm-xochitl-kbdpatch"
$BinOut    = Join-Path $DistScriptsDir "rm-xochitl-kbdpatch"
$JsonOut   = Join-Path $DistScriptsDir "keyboard_layout.json"
$FontOut   = Join-Path $DistScriptsDir "hebrew.ttf"
$DeployOut = Join-Path $DistScriptsDir "deploy.ps1"
$DeployStaticOutDir = Join-Path $DistScriptsDir "static"
$InstallWrapperOut = Join-Path $DistDir "Install.ps1"
$RollbackWrapperOut = Join-Path $DistDir "Rollback.ps1"

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# -----------------------
# Sanity: required commands
# -----------------------
foreach ($cmd in @("zig","cargo","rustup")) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    throw "Missing required command on PATH: $cmd"
  }
}

# -----------------------
# Project scaffolding
# -----------------------
New-Item -ItemType Directory -Force $Proj | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Proj "src") | Out-Null
New-Item -ItemType Directory -Force $DistDir | Out-Null
New-Item -ItemType Directory -Force $DistScriptsDir | Out-Null

Push-Location $Proj
try {
  if (!(Test-Path $CargoToml)) { cargo init --bin | Out-Null }

  if (!(Test-Path $MainRs)) { throw "Missing static main.rs: $MainRs" }
  if (!(Test-Path $KeyboardJsonSrc)) { throw "Missing static keyboard JSON: $KeyboardJsonSrc" }
  if (!(Test-Path $FontSrc)) { throw "Missing font file: $FontSrc" }
  if (!(Test-Path $DeployScriptSrc)) { throw "Missing deploy script: $DeployScriptSrc" }
  if (!(Test-Path $DeployStaticDirSrc)) { throw "Missing deploy static dir: $DeployStaticDirSrc" }

  # -----------------------
  # Cargo.toml
  # -----------------------
  $CargoTomlText = @'
[package]
name = "rm-xochitl-kbdpatch"
version = "4.2.1"
edition = "2021"

[dependencies]
anyhow = "1"
clap = { version = "4", features = ["derive"] }
hex = "0.4"
memchr = "2"
memmap2 = "0.9"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sha2 = "0.10"
zstd = "0.13"
'@
  Write-Utf8NoBom $CargoToml $CargoTomlText

  # -----------------------
  # Build
  # -----------------------
  rustup target add $Target | Out-Null

  Write-Host "[build] cargo zigbuild --release --target $Target"
  cargo zigbuild --release --target $Target
  if ($LASTEXITCODE -ne 0) { throw "Build failed (cargo zigbuild exit $LASTEXITCODE)." }

  if (!(Test-Path $BinLocal)) { throw "Binary not found after build: $BinLocal" }

  Copy-Item -Force $BinLocal $BinOut
  Copy-Item -Force $KeyboardJsonSrc $JsonOut
  Copy-Item -Force $FontSrc $FontOut
  Copy-Item -Force $DeployScriptSrc $DeployOut
  if (Test-Path $DeployStaticOutDir) { Remove-Item -Recurse -Force $DeployStaticOutDir }
  Copy-Item -Recurse -Force $DeployStaticDirSrc $DeployStaticOutDir

  $InstallWrapper = @'
$DeployScript = Join-Path $PSScriptRoot "scripts\deploy.ps1"
$ExitCode = 1

try {
  if (!(Test-Path -LiteralPath $DeployScript -PathType Leaf)) {
    throw "Missing deploy script: $DeployScript"
  }

  & $DeployScript -Mode install @args
  $ExitCode = $LASTEXITCODE
}
finally {
  Write-Host ""
  Write-Host "Press any key to exit..."
  [void][System.Console]::ReadKey($true)
}

exit $ExitCode
'@
  Write-Utf8NoBom $InstallWrapperOut $InstallWrapper

  $RollbackWrapper = @'
$DeployScript = Join-Path $PSScriptRoot "scripts\deploy.ps1"
$ExitCode = 1

try {
  if (!(Test-Path -LiteralPath $DeployScript -PathType Leaf)) {
    throw "Missing deploy script: $DeployScript"
  }

  & $DeployScript -Mode rollback @args
  $ExitCode = $LASTEXITCODE
}
finally {
  Write-Host ""
  Write-Host "Press any key to exit..."
  [void][System.Console]::ReadKey($true)
}

exit $ExitCode
'@
  Write-Utf8NoBom $RollbackWrapperOut $RollbackWrapper

  Write-Host "[build] OK"
  Write-Host "Artifacts:"
  Write-Host "  $InstallWrapperOut"
  Write-Host "  $RollbackWrapperOut"
  Write-Host "  $BinOut"
  Write-Host "  $JsonOut"
  Write-Host "  $FontOut"
  Write-Host "  $DeployOut"
  Write-Host "  $DeployStaticOutDir"
}
finally {
  Pop-Location
}
