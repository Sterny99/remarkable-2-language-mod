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