<# =====================================================================
deploy.ps1 — reMarkable (rm2) Hebrew font + OSK patch + robust persistence
INSTALLER/WIZARD EDITION (Windows PowerShell)

Highlights:
  ✅ One-time password prompt (only if key auth is not yet configured):
     - Generates a script-local SSH key: .rm_ssh\id_ed25519_rm2
     - Installs its public key to /home/root/.ssh/authorized_keys (prompts once)
     - All future runs use key auth (no repeated password prompts)

  ✅ Installer-friendly output:
     - Clear step headers
     - Live streaming output during long-running remote steps (install/repair/rollback)

  ✅ Robustness:
     - Script-local known_hosts (host key churn handled)
     - CRLF-safe scripts; chmod AFTER normalization to prevent exec-bit loss
     - Rootfs remount RW immediately before OSK patch execution
     - /home/root/bin added to PATH for systemd/non-interactive shells
     - Remote work via uploaded runner scripts (no stdin deadlocks)

Rollback fixes:
  ✅ Rollback now stops/disables persistent services FIRST, removes units/drop-ins,
     then runs rollback.sh, then cleans artifacts so persistence can't re-apply changes.

Usage:
  powershell -ExecutionPolicy Bypass -File .\deploy.ps1
  powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Mode repair
  powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Mode rollback
  powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Mode status

Optional:
  -VerboseOutput   More detail (lists files, shows more remote output)
===================================================================== #>

[CmdletBinding()]
param(
  [ValidateSet("install","repair","rollback","status")]
  [string]$Mode = "install",

  [string]$Locale = "de_DE",

  [string]$RmIp   = "10.11.99.1",
  [string]$RmUser = "root",
  [int]$RmPort    = 22,

  [int]$ConnectTimeoutSec = 12,

  [bool]$EnablePersistence = $true,

  [switch]$SkipFontInstall,

  [switch]$VerboseOutput,

  [string]$BinLocal  = "",
  [string]$JsonLocal = "",
  [string]$FontLocal = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Logging helpers (installer-style)
# -----------------------------
function Write-Info([string]$Msg)  { Write-Host "[deploy] $Msg" }
function Write-Warn([string]$Msg)  { Write-Host "[deploy] WARN: $Msg" }
function Write-Err([string]$Msg)   { Write-Host "[deploy] ERROR: $Msg" }
function Write-Step([string]$Msg)  { Write-Host ""; Write-Host ("[deploy] === {0} ===" -f $Msg) }

# -----------------------------
# Resolve script root robustly
# -----------------------------
$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
  try { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { }
}
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
  $ScriptRoot = (Get-Location).Path
}

Write-Info "Mode=$Mode  Locale=$Locale"
Write-Info "ScriptRoot: $ScriptRoot"
Write-Info ("Target: {0}@{1}:{2}" -f $RmUser, $RmIp, $RmPort)

# -----------------------------
# Local artifacts auto-detect
# -----------------------------
function Resolve-Artifact([string]$Override, [string[]]$Candidates) {
  function Resolve-IfFile([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return (Resolve-Path -LiteralPath $Path).Path
  }

  if (-not [string]::IsNullOrWhiteSpace($Override)) {
    $resolvedOverride = Resolve-IfFile $Override
    if ([string]::IsNullOrWhiteSpace($resolvedOverride)) {
      throw "Override path is not a file: $Override"
    }
    return $resolvedOverride
  }

  foreach ($c in $Candidates) {
    $p = Join-Path $ScriptRoot $c
    $resolvedCandidate = Resolve-IfFile $p
    if (-not [string]::IsNullOrWhiteSpace($resolvedCandidate)) {
      return $resolvedCandidate
    }
  }
  return ""
}

$NeedsPayload  = ($Mode -eq "install" -or $Mode -eq "repair")
$NeedsRollback = ($Mode -eq "rollback")

$BinLocal  = if ($NeedsPayload) { Resolve-Artifact $BinLocal  @("rm-xochitl-kbdpatch","dist\rm-xochitl-kbdpatch","scripts\rm-xochitl-kbdpatch","dist\scripts\rm-xochitl-kbdpatch") } else { "" }
$JsonLocal = if ($NeedsPayload) { Resolve-Artifact $JsonLocal @("keyboard_layout.json","dist\keyboard_layout.json","scripts\keyboard_layout.json","dist\scripts\keyboard_layout.json") } else { "" }
$FontLocal = if ($NeedsPayload) { Resolve-Artifact $FontLocal @("hebrew.ttf","dist\hebrew.ttf","scripts\hebrew.ttf","dist\scripts\hebrew.ttf") } else { "" }

$StaticFiles = @{}
if ($NeedsPayload -or $NeedsRollback) {
  $StaticFiles = @{
    "fonts.conf"                  = Resolve-Artifact "" @("static\config\fonts.conf","dist\scripts\static\config\fonts.conf","static\fonts.conf","dist\static\fonts.conf")
    "rollback.sh"                 = Resolve-Artifact "" @("static\scripts\rollback.sh","dist\scripts\static\scripts\rollback.sh","static\rollback.sh","dist\static\rollback.sh")
    "99-rm-custom.conf"           = Resolve-Artifact "" @("static\config\99-rm-custom.conf","dist\scripts\static\config\99-rm-custom.conf","static\99-rm-custom.conf","dist\static\99-rm-custom.conf")
    "rm-ssh-ensure.sh"            = Resolve-Artifact "" @("static\scripts\rm-ssh-ensure.sh","dist\scripts\static\scripts\rm-ssh-ensure.sh","static\rm-ssh-ensure.sh","dist\static\rm-ssh-ensure.sh")
    "rm-slot-sync.sh"             = Resolve-Artifact "" @("static\scripts\rm-slot-sync.sh","dist\scripts\static\scripts\rm-slot-sync.sh","static\rm-slot-sync.sh","dist\static\rm-slot-sync.sh")
    "rm-update-watch.sh"          = Resolve-Artifact "" @("static\scripts\rm-update-watch.sh","dist\scripts\static\scripts\rm-update-watch.sh","static\rm-update-watch.sh","dist\static\rm-update-watch.sh")
    "rm-customizations.sh"        = Resolve-Artifact "" @("static\scripts\rm-customizations.sh","dist\scripts\static\scripts\rm-customizations.sh","static\rm-customizations.sh","dist\static\rm-customizations.sh")
    "rm-fix-boot-hang.sh"         = Resolve-Artifact "" @("static\scripts\rm-fix-boot-hang.sh","dist\scripts\static\scripts\rm-fix-boot-hang.sh","static\rm-fix-boot-hang.sh","dist\static\rm-fix-boot-hang.sh")
    "rm-ssh-ensure.service"       = Resolve-Artifact "" @("static\services\rm-ssh-ensure.service","dist\scripts\static\services\rm-ssh-ensure.service","static\rm-ssh-ensure.service","dist\static\rm-ssh-ensure.service")
    "rm-customizations.service"   = Resolve-Artifact "" @("static\services\rm-customizations.service","dist\scripts\static\services\rm-customizations.service","static\rm-customizations.service","dist\static\rm-customizations.service")
    "rm-slot-sync.service"        = Resolve-Artifact "" @("static\services\rm-slot-sync.service","dist\scripts\static\services\rm-slot-sync.service","static\rm-slot-sync.service","dist\static\rm-slot-sync.service")
    "rm-update-watch.service"     = Resolve-Artifact "" @("static\services\rm-update-watch.service","dist\scripts\static\services\rm-update-watch.service","static\rm-update-watch.service","dist\static\rm-update-watch.service")
  }
}

function Assert-StaticFile([string]$Name) {
  if (-not $StaticFiles.ContainsKey($Name)) { throw "Internal: StaticFiles missing key '$Name'." }
  $p = $StaticFiles[$Name]
  if ([string]::IsNullOrWhiteSpace($p) -or !(Test-Path -LiteralPath $p -PathType Leaf)) {
    throw "Missing static file '$Name' next to deploy.ps1 (static\, scripts\static\, dist\scripts\static\, or dist\static\)."
  }
}

if ($NeedsRollback) {
  Assert-StaticFile "rollback.sh"
}

if ($NeedsPayload) {
  foreach ($f in @(
    "fonts.conf","99-rm-custom.conf","rm-ssh-ensure.sh","rm-slot-sync.sh","rm-update-watch.sh",
    "rm-customizations.sh","rm-fix-boot-hang.sh","rm-ssh-ensure.service","rm-customizations.service",
    "rm-slot-sync.service","rm-update-watch.service"
  )) { Assert-StaticFile $f }

  if ([string]::IsNullOrWhiteSpace($BinLocal) -or !(Test-Path -LiteralPath $BinLocal -PathType Leaf)) {
    throw "Missing rm-xochitl-kbdpatch next to deploy.ps1 (or scripts\ / dist\scripts\)."
  }
  if ([string]::IsNullOrWhiteSpace($JsonLocal) -or !(Test-Path -LiteralPath $JsonLocal -PathType Leaf)) {
    throw "Missing keyboard_layout.json next to deploy.ps1 (or scripts\ / dist\scripts\)."
  }
  if (-not $SkipFontInstall) {
    if ([string]::IsNullOrWhiteSpace($FontLocal) -or !(Test-Path -LiteralPath $FontLocal -PathType Leaf)) {
      throw "Missing hebrew.ttf next to deploy.ps1 (or scripts\ / dist\scripts\). Use -SkipFontInstall to skip."
    }
  }
}

# -----------------------------
# Required OpenSSH tools
# -----------------------------
Write-Step "Checking prerequisites"
foreach ($cmd in @("ssh","scp","ssh-keygen","ssh-keyscan")) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    throw "$cmd not found on PATH. Install Windows OpenSSH Client feature."
  }
}
Write-Info "OpenSSH tools found."

# -----------------------------
# Script-local SSH state (key + known_hosts)
# -----------------------------
$SshDir = Join-Path $ScriptRoot ".rm_ssh"
if (-not (Test-Path -LiteralPath $SshDir)) {
  New-Item -ItemType Directory -Force -Path $SshDir | Out-Null
}

$KnownHosts = Join-Path $SshDir "known_hosts"
if (-not (Test-Path -LiteralPath $KnownHosts)) {
  New-Item -ItemType File -Force -Path $KnownHosts | Out-Null
}
$KnownHostsPath = (Resolve-Path -LiteralPath $KnownHosts).Path
$KnownHostsPathForSsh = ($KnownHostsPath -replace '\\','/')

$KeyPath = Join-Path $SshDir "id_ed25519_rm2"
$KeyPubPath = "$KeyPath.pub"

# -----------------------------
# scp -O auto-detect (use only if supported by local scp)
# -----------------------------
$script:UseLegacyScpProtocol = $false
try {
  $help = (& scp -h 2>&1 | Out-String)
  if ($help -match '(\s|,)-O(\s|,|$)') { $script:UseLegacyScpProtocol = $true }
} catch { }

# -----------------------------
# Windows CreateProcess argument escaping (global)
# -----------------------------
function Escape-WinArg([string]$arg) {
  if ($null -eq $arg) { return '""' }
  if ($arg.Length -eq 0) { return '""' }
  if ($arg -notmatch '[\s"]') { return $arg }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')

  $bsCount = 0
  foreach ($ch in $arg.ToCharArray()) {
    if ($ch -eq '\') { $bsCount++; continue }
    if ($ch -eq '"') {
      if ($bsCount -gt 0) { [void]$sb.Append(('\' * ($bsCount * 2 + 1))) }
      else { [void]$sb.Append('\') }
      [void]$sb.Append('"')
      $bsCount = 0
      continue
    }
    if ($bsCount -gt 0) { [void]$sb.Append(('\' * $bsCount)); $bsCount = 0 }
    [void]$sb.Append($ch)
  }
  if ($bsCount -gt 0) { [void]$sb.Append(('\' * ($bsCount * 2))) }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Join-WinArgs([AllowEmptyString()][string[]]$ArgList) {
  if ($null -eq $ArgList -or $ArgList.Count -eq 0) { return "" }
  return (($ArgList | ForEach-Object { Escape-WinArg $_ }) -join " ")
}

# -----------------------------
# Process capture (safe, non-interactive)
# -----------------------------
function Invoke-ProcessCapture {
  param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][AllowEmptyString()][string[]]$ArgList,
    [int]$TimeoutSec = 0
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.Arguments = (Join-WinArgs $ArgList)

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  $null = $p.Start()

  if ($TimeoutSec -gt 0) {
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      try { $p.Kill() } catch { }
      return [pscustomobject]@{ ExitCode = 124; Output = "Timed out after ${TimeoutSec}s: $Exe $($psi.Arguments)" }
    }
  } else {
    $p.WaitForExit()
  }

  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $out = (($stdout + $stderr) | Out-String)
  return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out }
}

# -----------------------------
# Process live streaming (for long remote commands)
# -----------------------------
function Invoke-ProcessLive {
  param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][AllowEmptyString()][string[]]$ArgList,
    [string]$Prefix = "",
    [int]$TimeoutSec = 0
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.Arguments = (Join-WinArgs $ArgList)

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  $p.EnableRaisingEvents = $true

  $lines = New-Object System.Collections.Generic.List[string]

  $handlerOut = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $e)
    if ($null -ne $e.Data -and $e.Data.Length -gt 0) {
      if ($Prefix) { Write-Host ("{0}{1}" -f $Prefix, $e.Data) } else { Write-Host $e.Data }
      $lines.Add($e.Data) | Out-Null
    }
  }
  $handlerErr = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $e)
    if ($null -ne $e.Data -and $e.Data.Length -gt 0) {
      if ($Prefix) { Write-Host ("{0}{1}" -f $Prefix, $e.Data) } else { Write-Host $e.Data }
      $lines.Add($e.Data) | Out-Null
    }
  }

  $p.add_OutputDataReceived($handlerOut)
  $p.add_ErrorDataReceived($handlerErr)

  $null = $p.Start()
  $p.BeginOutputReadLine()
  $p.BeginErrorReadLine()

  if ($TimeoutSec -gt 0) {
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      try { $p.Kill() } catch { }
      return [pscustomobject]@{ ExitCode = 124; Output = ("Timed out after ${TimeoutSec}s: {0} {1}" -f $Exe, $psi.Arguments) }
    }
  } else {
    $p.WaitForExit()
  }

  return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($lines -join "`n") }
}

function Is-HostKeyMismatch([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  return (
    $Text -match "REMOTE HOST IDENTIFICATION HAS CHANGED" -or
    $Text -match "Host key verification failed" -or
    $Text -match "Offending .* key" -or
    $Text -match "POSSIBLE DNS SPOOFING"
  )
}

function Remove-HostKeyEntries {
  try {
    & ssh-keygen -R $RmIp -f $KnownHostsPath 2>$null | Out-Null
    if ($RmPort -ne 22) {
      & ssh-keygen -R ("[{0}]:{1}" -f $RmIp, $RmPort) -f $KnownHostsPath 2>$null | Out-Null
    }
  } catch { }
}

function Prime-HostKey {
  param([int]$TimeoutSec = 5)

  if (-not (Get-Command ssh-keyscan -ErrorAction SilentlyContinue)) { return }
  Write-Info "Priming host key (timeout ${TimeoutSec}s)..."

  $argList = @("-4", "-T", "$TimeoutSec", "-p", "$RmPort", $RmIp)
  $r = Invoke-ProcessCapture -Exe "ssh-keyscan" -ArgList $argList -TimeoutSec ($TimeoutSec + 2)

  if ($r.ExitCode -ne 0 -and $VerboseOutput) {
    Write-Warn "ssh-keyscan exit $($r.ExitCode) (continuing)"
  }

  $lines = @(
    $r.Output -split "`r?`n" | Where-Object {
      $_ -match '^\S+\s+(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa)\s+\S+'
    }
  )
  if ($lines.Count -gt 0) {
    Add-Content -LiteralPath $KnownHostsPath -Encoding Ascii -Value $lines
  }
}

# -----------------------------
# SSH/SCP argument builders
# -----------------------------
function Get-CommonSshOptsKey {
  @(
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=$KnownHostsPathForSsh",
    "-o", "CheckHostIP=no",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=$ConnectTimeoutSec",
    "-o", "ConnectionAttempts=1",
    "-o", "IdentitiesOnly=yes",
    "-o", "BatchMode=yes"
  )
}

function Get-CommonSshOptsPassword {
  @(
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=$KnownHostsPathForSsh",
    "-o", "CheckHostIP=no",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=$ConnectTimeoutSec",
    "-o", "ConnectionAttempts=1",
    "-o", "BatchMode=no",
    "-o", "PreferredAuthentications=password",
    "-o", "PubkeyAuthentication=no"
  )
}

function Get-SshArgsKey([string]$RemoteCommand) {
  @(
    "-i", $KeyPath,
    "-T",
    "-p", "$RmPort"
  ) + (Get-CommonSshOptsKey) + @("$RmUser@$RmIp", $RemoteCommand)
}

function Get-SshArgsPassword([string]$RemoteCommand) {
  @(
    "-T",
    "-p", "$RmPort"
  ) + (Get-CommonSshOptsPassword) + @("$RmUser@$RmIp", $RemoteCommand)
}

function Get-ScpArgsKey([string[]]$LocalPaths, [string]$Dest) {
  $args = @(
    "-i", $KeyPath,
    "-P", "$RmPort"
  ) + (Get-CommonSshOptsKey)

  if (-not $VerboseOutput) { $args = @("-q") + $args }
  if ($script:UseLegacyScpProtocol) { $args = @("-O") + $args }
  return $args + $LocalPaths + @($Dest)
}

# -----------------------------
# Key provisioning (password ONCE)
# -----------------------------
function Ensure-LocalKey {
  if ( (Test-Path -LiteralPath $KeyPath -PathType Leaf) -and (Test-Path -LiteralPath $KeyPubPath -PathType Leaf) ) {
    return
  }

  Write-Info "Generating local SSH key (ed25519)..."
  $r = Invoke-ProcessCapture -Exe "ssh-keygen" -ArgList @(
    "-q",
    "-t","ed25519",
    "-N","",          # empty passphrase (must be preserved)
    "-f",$KeyPath
  ) -TimeoutSec 30

  if ($r.ExitCode -ne 0) {
    throw "ssh-keygen failed (exit $($r.ExitCode))`n$($r.Output)"
  }

  if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) { throw "ssh-keygen failed to create key: $KeyPath" }
  if (-not (Test-Path -LiteralPath $KeyPubPath -PathType Leaf)) { throw "ssh-keygen failed to create pubkey: $KeyPubPath" }
}

function Test-KeyAuth {
  $args = Get-SshArgsKey "echo ok"
  $r = Invoke-ProcessCapture -Exe "ssh" -ArgList $args -TimeoutSec ($ConnectTimeoutSec + 10)
  return ($r.ExitCode -eq 0)
}

function Provision-KeyOnDevice {
  Ensure-LocalKey

  $pub = (Get-Content -LiteralPath $KeyPubPath -Raw).Trim()
  if ([string]::IsNullOrWhiteSpace($pub)) { throw "Public key is empty: $KeyPubPath" }

  # One remote command, prompts once.
  $remote = @"
mkdir -p /home/root/.ssh &&
chmod 700 /home/root/.ssh &&
touch /home/root/.ssh/authorized_keys &&
chmod 600 /home/root/.ssh/authorized_keys &&
grep -qxF '$pub' /home/root/.ssh/authorized_keys || echo '$pub' >> /home/root/.ssh/authorized_keys
"@ -replace "`r","" -replace "`n"," "

  Write-Info "One-time SSH setup: you will be prompted for the tablet password ONCE..."
  Remove-HostKeyEntries
  Prime-HostKey

  $sshArgs = Get-SshArgsPassword $remote

  # Pass-through so the password prompt is visible.
  & ssh @sshArgs
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    throw "Password provisioning failed (ssh exit $code)."
  }

  if (-not (Test-KeyAuth)) {
    throw "Provisioning ran, but key auth still fails. Check /home/root/.ssh perms and rerun."
  }

  Write-Info "SSH key installed. Future runs will not prompt for password."
}

# -----------------------------
# Run SSH/SCP with key (captured + live)
# -----------------------------
function Invoke-RmSshCapture {
  param(
    [Parameter(Mandatory)][string]$RemoteCommand,
    [int]$TimeoutSec = 0
  )

  $args = Get-SshArgsKey $RemoteCommand
  $r = Invoke-ProcessCapture -Exe "ssh" -ArgList $args -TimeoutSec $TimeoutSec
  if ($r.ExitCode -ne 0 -and (Is-HostKeyMismatch $r.Output)) {
    Write-Warn "Host key mismatch detected. Refreshing known_hosts and retrying once..."
    Remove-HostKeyEntries
    Prime-HostKey
    $r = Invoke-ProcessCapture -Exe "ssh" -ArgList $args -TimeoutSec $TimeoutSec
  }

  if ($r.ExitCode -ne 0) {
    throw "ssh failed (exit $($r.ExitCode)) running: $RemoteCommand`n$($r.Output)"
  }
  return $r.Output
}

function Invoke-RmSshLive {
  param(
    [Parameter(Mandatory)][string]$RemoteCommand,
    [string]$Prefix = ""
  )

  $args = Get-SshArgsKey $RemoteCommand
  $r = Invoke-ProcessLive -Exe "ssh" -ArgList $args -Prefix $Prefix -TimeoutSec 0
  if ($r.ExitCode -ne 0 -and (Is-HostKeyMismatch $r.Output)) {
    Write-Warn "Host key mismatch detected. Refreshing known_hosts and retrying once..."
    Remove-HostKeyEntries
    Prime-HostKey
    $r = Invoke-ProcessLive -Exe "ssh" -ArgList $args -Prefix $Prefix -TimeoutSec 0
  }
  if ($r.ExitCode -ne 0) {
    throw "ssh failed (exit $($r.ExitCode)) running: $RemoteCommand"
  }
  return $r.Output
}

function Invoke-RmScpCapture {
  param(
    [Parameter(Mandatory)][string[]]$LocalPaths,
    [Parameter(Mandatory)][string]$StageDir
  )

  $dest = "{0}@{1}:{2}/" -f $RmUser, $RmIp, $StageDir
  $args = Get-ScpArgsKey -LocalPaths $LocalPaths -Dest $dest

  $r = Invoke-ProcessCapture -Exe "scp" -ArgList $args -TimeoutSec 0
  if ($r.ExitCode -ne 0) {
    if ($script:UseLegacyScpProtocol -and ($r.Output -match "unknown option.*-O" -or $r.Output -match "illegal option.*-O")) {
      Write-Warn "scp legacy protocol (-O) not supported. Retrying without -O..."
      $script:UseLegacyScpProtocol = $false
      $args = Get-ScpArgsKey -LocalPaths $LocalPaths -Dest $dest
      $r = Invoke-ProcessCapture -Exe "scp" -ArgList $args -TimeoutSec 0
    }
  }

  if ($r.ExitCode -ne 0 -and (Is-HostKeyMismatch $r.Output)) {
    Write-Warn "Host key mismatch detected during scp. Refreshing known_hosts and retrying once..."
    Remove-HostKeyEntries
    Prime-HostKey
    $args = Get-ScpArgsKey -LocalPaths $LocalPaths -Dest $dest
    $r = Invoke-ProcessCapture -Exe "scp" -ArgList $args -TimeoutSec 0
  }

  if ($r.ExitCode -ne 0) {
    throw "scp failed (exit $($r.ExitCode))`n$($r.Output)"
  }
}

# -----------------------------
# Helpers: sizes + LF/no-BOM file write
# -----------------------------
function Format-FileSize([long]$Bytes) {
  if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
  if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
  if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
  return "$Bytes B"
}

function Get-TotalSize([string[]]$Paths) {
  $total = 0L
  foreach ($p in $Paths) {
    if (Test-Path -LiteralPath $p) {
      $total += (Get-Item -LiteralPath $p).Length
    }
  }
  return $total
}

function Write-TextFileNoBomLf {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Text
  )
  $lf = $Text -replace "`r",""
  $enc = New-Object System.Text.UTF8Encoding($false) # UTF-8 NO BOM
  [System.IO.File]::WriteAllText($Path, $lf, $enc)
}

# -----------------------------
# Establish authentication (key preferred)
# -----------------------------
Write-Step "Establishing SSH authentication"
Ensure-LocalKey
Remove-HostKeyEntries
Prime-HostKey
Write-Info "Checking whether SSH key authentication works..."

if (-not (Test-KeyAuth)) {
  Write-Info "SSH key auth not yet configured. Starting one-time password provisioning..."
  Provision-KeyOnDevice
} else {
  Write-Info "SSH key auth is already configured."
}

# -----------------------------
# Remote paths
# -----------------------------
$StageDir              = "/home/root/.cache/rm-custom/stage"
$RemoteBin             = "/home/root/bin/rm-xochitl-kbdpatch"
$RemoteJsonDir         = "/home/root/.local/share/rm-custom/keyboards/$Locale"
$RemoteJson            = "$RemoteJsonDir/keyboard_layout.json"
$RemoteFontHomeDir     = "/home/root/.local/share/fonts"
$RemoteFontHome        = "$RemoteFontHomeDir/hebrew.ttf"
$RemoteFontSysDir      = "/usr/share/fonts/rm-custom"
$RemoteFontSys         = "$RemoteFontSysDir/hebrew.ttf"
$RemoteBootSh          = "/home/root/bin/rm-customizations.sh"
$RemoteSlotSh          = "/home/root/bin/rm-slot-sync.sh"
$RemoteSshSh           = "/home/root/bin/rm-ssh-ensure.sh"
$RemoteUpdSh           = "/home/root/bin/rm-update-watch.sh"
$RemoteFixBootHangSh   = "/home/root/bin/rm-fix-boot-hang.sh"
$RemoteXoDropIn        = "/etc/systemd/system/xochitl.service.d/99-rm-custom.conf"
$RemoteUnitCus         = "/etc/systemd/system/rm-customizations.service"
$RemoteUnitSlt         = "/etc/systemd/system/rm-slot-sync.service"
$RemoteUnitSsh         = "/etc/systemd/system/rm-ssh-ensure.service"
$RemoteUnitUpd         = "/etc/systemd/system/rm-update-watch.service"

# Ensure stage exists
Write-Step "Preparing remote staging"
Write-Info "Ensuring stage and cache directories exist on the device..."
Invoke-RmSshCapture "mkdir -p $StageDir /home/root/.cache/rm-custom" | Out-Null
Write-Info "Remote staging directories ready."

# -----------------------------
# STATUS
# -----------------------------
if ($Mode -eq "status") {
  Write-Step "Status"
  $StatusCmd = @"
set -e
echo '--- device ---'
uname -a 2>/dev/null || true
echo '--- xochitl sha ---'
sha256sum /usr/bin/xochitl 2>/dev/null || true
echo '--- font files ---'
ls -l /home/root/.local/share/fonts/hebrew.ttf 2>/dev/null || true
ls -l /usr/share/fonts/rm-custom/hebrew.ttf 2>/dev/null || true
echo '--- keyboard json ---'
ls -l $RemoteJson 2>/dev/null || true
echo '--- perms ---'
ls -l /home/root/bin/rm-customizations.sh 2>/dev/null || true
ls -l /home/root/bin/rm-xochitl-kbdpatch 2>/dev/null || true
echo '--- units (enabled/active) ---'
systemctl is-enabled rm-customizations.service 2>/dev/null || echo disabled
systemctl is-active  rm-customizations.service 2>/dev/null || echo inactive
systemctl is-enabled rm-slot-sync.service 2>/dev/null || echo disabled
systemctl is-active  rm-slot-sync.service 2>/dev/null || echo inactive
systemctl is-enabled rm-update-watch.service 2>/dev/null || echo disabled
systemctl is-active  rm-update-watch.service 2>/dev/null || echo inactive
echo '--- last logs ---'
tail -n 80 /home/root/.cache/rm-custom/deploy.log 2>/dev/null || true
tail -n 120 /home/root/.cache/rm-custom/customizations.log 2>/dev/null || true
tail -n 120 /home/root/.cache/rm-custom/slot-sync.log 2>/dev/null || true
tail -n 120 /home/root/.cache/rm-custom/update-watch.log 2>/dev/null || true
tail -n 120 /home/root/.cache/rm-custom/fix-boot-hang.log 2>/dev/null || true
"@

  $StatusRunName  = "rm-status-run.sh"
  $StatusRunLocal = Join-Path $ScriptRoot $StatusRunName
  Write-TextFileNoBomLf -Path $StatusRunLocal -Text $StatusCmd

  Write-Info "Uploading status runner..."
  Invoke-RmScpCapture -LocalPaths @($StatusRunLocal) -StageDir $StageDir

  Write-Info "Running status..."
  $out = Invoke-RmSshCapture "sh $StageDir/$StatusRunName" -TimeoutSec 0
  Write-Host $out

  Remove-Item -Force -ErrorAction SilentlyContinue $StatusRunLocal
  exit 0
}

# -----------------------------
# ROLLBACK (fixed for persistence)
# -----------------------------
if ($Mode -eq "rollback") {
  Write-Step "Rollback"
  Assert-StaticFile "rollback.sh"

 $RollbackBody = Get-Content -LiteralPath $StaticFiles["rollback.sh"] -Raw
$RollbackBody = $RollbackBody -replace "`r",""   # ensure LF-only before embedding

# IMPORTANT: single-quoted here-string so $LOG/$1 are NOT expanded by PowerShell
$RollbackWrapperTemplate = @'
set -e
LOCALE="__LOCALE__"

LOG=/home/root/.cache/rm-custom/rollback.log
mkdir -p /home/root/.cache/rm-custom
: > "$LOG"
log(){ echo "$1" | tee -a "$LOG"; }

log "[rollback] begin"
log "[rollback] stopping services (prevent persistence re-applying patches)"
mount -o remount,rw / 2>/dev/null || true

for u in rm-update-watch.service rm-slot-sync.service rm-customizations.service rm-ssh-ensure.service; do
  systemctl stop "$u" 2>/dev/null || true
done

for u in rm-update-watch.service rm-slot-sync.service rm-customizations.service rm-ssh-ensure.service; do
  systemctl disable "$u" 2>/dev/null || true
done

systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

log "[rollback] removing unit files and xochitl drop-in"
rm -f /etc/systemd/system/rm-update-watch.service 2>/dev/null || true
rm -f /etc/systemd/system/rm-slot-sync.service 2>/dev/null || true
rm -f /etc/systemd/system/rm-customizations.service 2>/dev/null || true
rm -f /etc/systemd/system/rm-ssh-ensure.service 2>/dev/null || true

rm -f /etc/systemd/system/xochitl.service.d/99-rm-custom.conf 2>/dev/null || true
rmdir /etc/systemd/system/xochitl.service.d 2>/dev/null || true

systemctl daemon-reload 2>/dev/null || true

log "[rollback] running rollback.sh"
# --- rollback.sh begins ---
__ROLLBACK_BODY__
# --- rollback.sh ends ---

log "[rollback] cleanup of remaining artifacts (best-effort)"
rm -f /home/root/bin/rm-xochitl-kbdpatch 2>/dev/null || true
rm -f /home/root/bin/rm-customizations.sh 2>/dev/null || true
rm -f /home/root/bin/rm-slot-sync.sh 2>/dev/null || true
rm -f /home/root/bin/rm-update-watch.sh 2>/dev/null || true
rm -f /home/root/bin/rm-ssh-ensure.sh 2>/dev/null || true
rm -f /home/root/bin/rm-fix-boot-hang.sh 2>/dev/null || true

rm -rf /home/root/.local/share/rm-custom/keyboards/$LOCALE 2>/dev/null || true
rm -f /home/root/.local/share/fonts/hebrew.ttf 2>/dev/null || true
rm -f /usr/share/fonts/rm-custom/hebrew.ttf 2>/dev/null || true

fc-cache -f /home/root/.local/share/fonts 2>/dev/null || true

log "[rollback] restarting xochitl"
systemctl stop xochitl 2>/dev/null || true
systemctl start xochitl 2>/dev/null || true

mount -o remount,ro / 2>/dev/null || true
log "[rollback] DONE"
echo "---- tail rollback.log ----"
tail -n 220 "$LOG" 2>/dev/null || true
'@

$RollbackWrapper = $RollbackWrapperTemplate.
  Replace("__LOCALE__", $Locale).
  Replace("__ROLLBACK_BODY__", $RollbackBody)


  $RollbackRunName  = "rm-rollback-run.sh"
  $RollbackRunLocal = Join-Path $ScriptRoot $RollbackRunName
  Write-TextFileNoBomLf -Path $RollbackRunLocal -Text $RollbackWrapper

  Write-Info "Uploading rollback runner..."
  Invoke-RmScpCapture -LocalPaths @($RollbackRunLocal) -StageDir $StageDir

  Write-Info "Running rollback (live output)..."
  Invoke-RmSshLive "sh $StageDir/$RollbackRunName" "[rm2] " | Out-Null

  Remove-Item -Force -ErrorAction SilentlyContinue $RollbackRunLocal

  Write-Host ""
  Write-Info "Rollback complete."
  Write-Info "Device logs:"
  Write-Info "  - /home/root/.cache/rm-custom/rollback.log"
  Write-Info "  - /home/root/.cache/rm-custom/deploy.log (if present)"
  exit 0
}

# -----------------------------
# INSTALL / REPAIR
# -----------------------------
Write-Step ("{0}" -f ($(if ($Mode -eq "repair") { "Repair" } else { "Install" })))

Write-Info "Preparing directories on device..."
Invoke-RmSshCapture "mkdir -p $StageDir /home/root/bin $RemoteJsonDir /home/root/.cache/rm-custom $RemoteFontHomeDir" | Out-Null

# Remote installer runner (uploaded + executed; no stdin deadlocks)
$RemoteRun = @'
set -e

PERSIST="__PERSIST__"
LOCALE="__LOCALE__"

STAGE="__STAGE__"
BIN_DST="__RBIN__"
JSON_DIR="__RJSONDIR__"
JSON_DST="__RJSON__"

FONT_STAGE="$STAGE/hebrew.ttf"
FONT_HOME_DIR="__RFONTHOMEDIR__"
FONT_HOME="__RFONTHOME__"

FONT_SYS_DIR="__RFONTSYSDIR__"
FONT_SYS="__RFONTSYS__"

CUS_SH="__RBOOT__"
SLOT_SH="__RSLOT__"
SSH_SH="__RSSH__"
UPD_SH="__RUPD__"
FIX_BOOT_HANG_SH="__RFIXBOOTHANG__"

XO_DROPIN="__RXODROPIN__"

UNIT_CUS="__RUNITCUS__"
UNIT_SLT="__RUNITSLOT__"
UNIT_SSH="__RUNITSSH__"
UNIT_UPD="__RUNITUPD__"

LOG=/home/root/.cache/rm-custom/deploy.log
mkdir -p /home/root/.cache/rm-custom
: > "$LOG"
log(){ echo "$1" | tee -a "$LOG"; }

log "[deploy] begin (installer-rev=live+permfix+rw-before-customizations)"
log "[deploy] locale=$LOCALE persist=$PERSIST"

export PATH="/home/root/bin:$PATH"

log "[deploy] validating staged payload..."
req() { [ -f "$1" ] || { log "[deploy] ERROR missing: $1"; exit 2; }; }
req "$STAGE/rm-xochitl-kbdpatch"
req "$STAGE/keyboard_layout.json"
req "$STAGE/fonts.conf"
req "$STAGE/99-rm-custom.conf"
req "$STAGE/rm-ssh-ensure.sh"
req "$STAGE/rm-slot-sync.sh"
req "$STAGE/rm-update-watch.sh"
req "$STAGE/rm-customizations.sh"
req "$STAGE/rm-fix-boot-hang.sh"
req "$STAGE/rm-ssh-ensure.service"
req "$STAGE/rm-customizations.service"
req "$STAGE/rm-slot-sync.service"
req "$STAGE/rm-update-watch.service"

log "[deploy] ensuring directories..."
mkdir -p /home/root/bin "$JSON_DIR" /home/root/.cache/rm-custom "$FONT_HOME_DIR" \
  /home/root/.config/fontconfig /home/root/.cache/fontconfig

log "[deploy] remounting rootfs RW (best-effort)..."
mount -o remount,rw / 2>/dev/null || true

log "[deploy] installing patch binary + keyboard json..."
cp -f "$STAGE/rm-xochitl-kbdpatch" "$BIN_DST"
cp -f "$STAGE/keyboard_layout.json" "$JSON_DST"

log "[deploy] installing font + fontconfig..."
if [ -f "$FONT_STAGE" ]; then
  cp -f "$FONT_STAGE" "$FONT_HOME"
  chmod 0644 "$FONT_HOME" 2>/dev/null || true
  log "[deploy] font installed to $FONT_HOME"
else
  log "[deploy] font stage missing (SkipFontInstall?)"
fi

cp -f "$STAGE/fonts.conf" /home/root/.config/fontconfig/fonts.conf
cp -f /home/root/.config/fontconfig/fonts.conf /home/root/.fonts.conf 2>/dev/null || true

mkdir -p "$FONT_SYS_DIR" 2>/dev/null || true
if [ -f "$FONT_HOME" ]; then
  cp -f "$FONT_HOME" "$FONT_SYS" 2>/dev/null || true
  chmod 0644 "$FONT_SYS" 2>/dev/null || true
  log "[deploy] font mirrored to $FONT_SYS"
fi

log "[deploy] installing xochitl drop-in + scripts + units..."
mkdir -p "$(dirname "$XO_DROPIN")" 2>/dev/null || true
cp -f "$STAGE/99-rm-custom.conf" "$XO_DROPIN"

cp -f "$STAGE/rm-ssh-ensure.sh" "$SSH_SH"
cp -f "$STAGE/rm-slot-sync.sh" "$SLOT_SH"
cp -f "$STAGE/rm-update-watch.sh" "$UPD_SH"
cp -f "$STAGE/rm-customizations.sh" "$CUS_SH"
cp -f "$STAGE/rm-fix-boot-hang.sh" "$FIX_BOOT_HANG_SH"

cp -f "$STAGE/rm-ssh-ensure.service" "$UNIT_SSH"
cp -f "$STAGE/rm-customizations.service" "$UNIT_CUS"
cp -f "$STAGE/rm-slot-sync.service" "$UNIT_SLT"
cp -f "$STAGE/rm-update-watch.service" "$UNIT_UPD"

log "[deploy] normalizing CRLF (may reset exec bits; we fix perms after)..."
norm_lf() {
  f="$1"
  [ -f "$f" ] || return 0
  tmp="$f.$$"
  tr -d '\015' < "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null || true
}
norm_lf /home/root/.config/fontconfig/fonts.conf
norm_lf /home/root/.fonts.conf
norm_lf "$XO_DROPIN"
norm_lf "$SSH_SH"
norm_lf "$SLOT_SH"
norm_lf "$UPD_SH"
norm_lf "$CUS_SH"
norm_lf "$FIX_BOOT_HANG_SH"
norm_lf "$UNIT_SSH"
norm_lf "$UNIT_CUS"
norm_lf "$UNIT_SLT"
norm_lf "$UNIT_UPD"

log "[deploy] ensuring PATH export exists inside scripts (systemd-safe)..."
ensure_path() {
  f="$1"
  [ -f "$f" ] || return 0
  grep -q 'export PATH="/home/root/bin:\$PATH"' "$f" 2>/dev/null && return 0
  if head -n 1 "$f" | grep -q '^#!'; then
    sed -i '1a export PATH="/home/root/bin:$PATH"' "$f" 2>/dev/null || true
  else
    sed -i '1i export PATH="/home/root/bin:$PATH"' "$f" 2>/dev/null || true
  fi
}
ensure_path "$SSH_SH"
ensure_path "$SLOT_SH"
ensure_path "$UPD_SH"
ensure_path "$CUS_SH"
ensure_path "$FIX_BOOT_HANG_SH"

log "[deploy] substituting tokens in customizations..."
sed -i "s#__LOCALE__#$LOCALE#g" "$CUS_SH" 2>/dev/null || true
sed -i "s#__RJSON__#$JSON_DST#g" "$CUS_SH" 2>/dev/null || true
sed -i "s#__RFONTHOMEDIR__#$FONT_HOME_DIR#g" "$CUS_SH" 2>/dev/null || true
sed -i "s#__RFONTHOME__#$FONT_HOME#g" "$CUS_SH" 2>/dev/null || true
sed -i "s#__RFONTSYSDIR__#$FONT_SYS_DIR#g" "$CUS_SH" 2>/dev/null || true
sed -i "s#__RFONTSYS__#$FONT_SYS#g" "$CUS_SH" 2>/dev/null || true

log "[deploy] enforcing permissions AFTER edits..."
chmod 0755 "$BIN_DST" 2>/dev/null || true
chmod 0755 "$SSH_SH" "$SLOT_SH" "$UPD_SH" "$CUS_SH" "$FIX_BOOT_HANG_SH" 2>/dev/null || true
chmod 0644 "$XO_DROPIN" "$UNIT_SSH" "$UNIT_CUS" "$UNIT_SLT" "$UNIT_UPD" 2>/dev/null || true

log "[deploy] enabling services..."
systemctl daemon-reload 2>/dev/null || true
systemctl enable rm-ssh-ensure.service 2>/dev/null || true
systemctl enable rm-customizations.service 2>/dev/null || true
systemctl enable rm-update-watch.service 2>/dev/null || true

if [ "$PERSIST" = "true" ]; then
  systemctl enable rm-slot-sync.service 2>/dev/null || true
  log "[deploy] persistence enabled"
else
  systemctl disable rm-slot-sync.service 2>/dev/null || true
  log "[deploy] persistence disabled (per flag)"
fi

log "[deploy] running ssh-ensure now..."
( systemctl start rm-ssh-ensure.service 2>/dev/null || sh /home/root/bin/rm-ssh-ensure.sh ) 2>&1 | tee -a "$LOG" || true

log "[deploy] applying boot-hang ordering fix..."
sh /home/root/bin/rm-fix-boot-hang.sh 2>&1 | tee -a "$LOG" || true

log "[deploy] running customizations now (OSK patch + xochitl restart)..."
mount -o remount,rw / 2>/dev/null || true
sh /home/root/bin/rm-customizations.sh 2>&1 | tee -a "$LOG"

if [ "$PERSIST" = "true" ]; then
  log "[deploy] seeding inactive slot now..."
  sh /home/root/bin/rm-slot-sync.sh 2>&1 | tee -a "$LOG" || true
fi

log "[deploy] refreshing font cache + restarting xochitl..."
fc-cache -f "$FONT_HOME_DIR" 2>&1 | tee -a "$LOG" || true
systemctl stop xochitl 2>&1 | tee -a "$LOG" || true
systemctl start xochitl 2>&1 | tee -a "$LOG" || true

log "[deploy] remounting rootfs RO..."
mount -o remount,ro / 2>/dev/null || true

log "[deploy] DONE"
echo "---- tail deploy.log ----"
tail -n 200 "$LOG" 2>/dev/null || true
'@

$RemoteRun = $RemoteRun.
  Replace("__PERSIST__", ($(if ($EnablePersistence) { "true" } else { "false" }))).
  Replace("__LOCALE__", $Locale).
  Replace("__STAGE__", $StageDir).
  Replace("__RBIN__", $RemoteBin).
  Replace("__RJSONDIR__", $RemoteJsonDir).
  Replace("__RJSON__", $RemoteJson).
  Replace("__RFONTHOMEDIR__", $RemoteFontHomeDir).
  Replace("__RFONTHOME__", $RemoteFontHome).
  Replace("__RFONTSYSDIR__", $RemoteFontSysDir).
  Replace("__RFONTSYS__", $RemoteFontSys).
  Replace("__RBOOT__", $RemoteBootSh).
  Replace("__RSLOT__", $RemoteSlotSh).
  Replace("__RSSH__", $RemoteSshSh).
  Replace("__RUPD__", $RemoteUpdSh).
  Replace("__RFIXBOOTHANG__", $RemoteFixBootHangSh).
  Replace("__RXODROPIN__", $RemoteXoDropIn).
  Replace("__RUNITCUS__", $RemoteUnitCus).
  Replace("__RUNITSLOT__", $RemoteUnitSlt).
  Replace("__RUNITSSH__", $RemoteUnitSsh).
  Replace("__RUNITUPD__", $RemoteUnitUpd)

$RemoteRunName  = "rm-deploy-run.sh"
$RemoteRunLocal = Join-Path $ScriptRoot $RemoteRunName
Write-Info "Generating temporary local installer runner: $RemoteRunLocal"
Write-TextFileNoBomLf -Path $RemoteRunLocal -Text $RemoteRun

# Upload list (single scp)
$files = @($BinLocal, $JsonLocal)
if (-not $SkipFontInstall) { $files += $FontLocal }

$files += @(
  $StaticFiles["fonts.conf"],
  $StaticFiles["99-rm-custom.conf"],
  $StaticFiles["rm-ssh-ensure.sh"],
  $StaticFiles["rm-slot-sync.sh"],
  $StaticFiles["rm-update-watch.sh"],
  $StaticFiles["rm-customizations.sh"],
  $StaticFiles["rm-fix-boot-hang.sh"],
  $StaticFiles["rm-ssh-ensure.service"],
  $StaticFiles["rm-customizations.service"],
  $StaticFiles["rm-slot-sync.service"],
  $StaticFiles["rm-update-watch.service"],
  $RemoteRunLocal
)

$size = Get-TotalSize -Paths $files
Write-Info ("Uploading payload: {0} file(s), {1} total..." -f $files.Count, (Format-FileSize $size))
if ($VerboseOutput) {
  foreach ($p in $files) {
    if (Test-Path -LiteralPath $p) {
      $it = Get-Item -LiteralPath $p
      Write-Host ("[deploy]   - {0} ({1})" -f $it.Name, (Format-FileSize $it.Length))
    } else {
      Write-Host ("[deploy]   - missing: {0}" -f $p)
    }
  }
}

Invoke-RmScpCapture -LocalPaths $files -StageDir $StageDir
Write-Info "Upload complete."
Write-Info "Payload staged at: $StageDir"
Write-Info "Staged runner path: $StageDir/$RemoteRunName"

Write-Info "Running installer on device (live output)..."
Invoke-RmSshLive "sh $StageDir/$RemoteRunName" "[rm2] " | Out-Null
Write-Info "Installer run finished on device."

Remove-Item -Force -ErrorAction SilentlyContinue $RemoteRunLocal
Write-Info "Removed temporary local runner script."

Write-Host ""
Write-Info "Done! The device may restart several times to complete the installation."
Write-Info "Device logs:"
Write-Info "  - /home/root/.cache/rm-custom/deploy.log"
Write-Info "  - /home/root/.cache/rm-custom/customizations.log"
Write-Info "  - /home/root/.cache/rm-custom/slot-sync.log"
Write-Info "  - /home/root/.cache/rm-custom/ssh-ensure.log"
Write-Info "  - /home/root/.cache/rm-custom/update-watch.log"
Write-Info "  - /home/root/.cache/rm-custom/fix-boot-hang.log"
