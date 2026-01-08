<#
.SYNOPSIS
  Install the monitoring stack on a Linux host from PowerShell (Windows/macOS/Linux).

.DESCRIPTION
  - If -Host is provided, uploads the companion Bash installer to the remote machine via scp,
    then executes it over ssh.
  - If -Host is omitted and you are on Linux, runs the Bash installer locally.

  This script does NOT attempt to install Prometheus/Grafana natively on Windows.
  It’s intended to drive a Linux install (local or remote).

.EXAMPLE
  # Run against a remote Linux host (will prompt for password if needed)
  .\monitoring-stack-install.ps1 -Host 192.168.1.36 -User root

.EXAMPLE
  # Pin versions
  .\monitoring-stack-install.ps1 -Host 192.168.1.36 -User root -Env @{ PROM_VERSION = "2.53.0"; GRAFANA_VERSION = "12.1.0" }

.EXAMPLE
  # Run locally on Linux (PowerShell 7+)
  sudo pwsh ./monitoring-stack-install.ps1
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$Host,

  [Parameter(Mandatory = $false)]
  [string]$User = "root",

  [Parameter(Mandatory = $false)]
  [int]$Port = 22,

  [Parameter(Mandatory = $false)]
  [string]$IdentityFile,

  [Parameter(Mandatory = $false)]
  [hashtable]$Env = @{},

  [Parameter(Mandatory = $false)]
  [string]$RemotePath = "/tmp/monitoring-stack-install.sh",

  [Parameter(Mandatory = $false)]
  [string]$LocalScriptPath = (Join-Path -Path $PSScriptRoot -ChildPath "monitoring-stack-install.sh")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found in PATH: $Name"
  }
}

function Escape-BashSingleQuoted([string]$Value) {
  # bash single-quote escape: close, escape a single quote, reopen
  return $Value -replace "'", "'\"'\"'"
}

function Format-BashEnv([hashtable]$Vars) {
  if (-not $Vars -or $Vars.Count -eq 0) { return "" }
  $pairs = foreach ($k in $Vars.Keys) {
    $v = [string]$Vars[$k]
    $ek = $k
    $ev = Escape-BashSingleQuoted $v
    "$ek='$ev'"
  }
  return ($pairs -join " ")
}

function Quote-BashSingle([string]$Value) {
  return "'" + (Escape-BashSingleQuoted $Value) + "'"
}

Require-Command "ssh"
Require-Command "scp"

if (-not (Test-Path -LiteralPath $LocalScriptPath)) {
  throw "Local bash installer not found: $LocalScriptPath"
}

$envPrefix = Format-BashEnv $Env
if ($Host) {
  $target = "$User@$Host"

  $sshArgs = @("-p", "$Port")
  $scpArgs = @("-P", "$Port")
  if ($IdentityFile) {
    $sshArgs += @("-i", $IdentityFile)
    $scpArgs += @("-i", $IdentityFile)
  }

  Write-Host "[*] Uploading installer to $target:$RemotePath"
  & scp @scpArgs -- $LocalScriptPath "$target:$RemotePath"

  $rp = Quote-BashSingle $RemotePath
  $run = if ($envPrefix) { "$envPrefix $rp" } else { $rp }
  $sudoRun = if ($envPrefix) { "sudo $envPrefix $rp" } else { "sudo $rp" }

  # Run everything under bash -lc for consistent parsing.
  $remoteBody = @"
set -euo pipefail
chmod +x $rp
if [ "`$(id -u)" -eq 0 ]; then
  $run
else
  $sudoRun
fi
"@
  $remoteCmd = "bash -lc " + (Quote-BashSingle $remoteBody)

  Write-Host "[*] Running installer on remote host..."
  & ssh @sshArgs -- $target $remoteCmd
  exit 0
}

# Local mode (Linux only)
if (-not $IsLinux) {
  throw "Local mode requires Linux (use -Host to install on a remote Linux machine)."
}

Write-Host "[*] Running installer locally..."
$lp = Quote-BashSingle $LocalScriptPath
$cmd = if ($envPrefix) { "$envPrefix bash $lp" } else { "bash $lp" }

if ((id -u) -ne 0) {
  # Prefer sudo if available
  if (Get-Command sudo -ErrorAction SilentlyContinue) {
    & sudo bash -lc $cmd
  } else {
    throw "Run as root or install sudo."
  }
} else {
  & bash -lc $cmd
}

