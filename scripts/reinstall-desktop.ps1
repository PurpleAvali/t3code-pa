# Rebuilds the Windows desktop installer from this checkout and installs it over the current T3 Code install.
# Usage: pnpm run reinstall:desktop [-- -SkipDeps] [-- -StopRunning] [-- -Arch arm64]
[CmdletBinding()]
param(
  [switch]$SkipDeps,
  [switch]$StopRunning,
  [ValidateSet("x64", "arm64")]
  [string]$Arch = "x64"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $repoRoot "release"
$installDir = Join-Path $env:LOCALAPPDATA "Programs\t3code"

Set-Location $repoRoot
# Local builds carry more native files than upstream's release cap allows.
$env:T3CODE_DESKTOP_WINDOWS_FILE_LIMIT = "150"
# The artifact script spawns `vp` directly.
$env:PATH = "$(Join-Path $repoRoot 'node_modules\.bin');$env:PATH"

# A release feed baked into the build would let upstream updates replace this fork.
foreach ($name in "T3CODE_DESKTOP_UPDATE_REPOSITORY", "GITHUB_REPOSITORY", "GH_TOKEN", "GITHUB_TOKEN") {
  Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

$running = Get-CimInstance Win32_Process |
  Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($installDir, [StringComparison]::OrdinalIgnoreCase) }
if ($running) {
  if (-not $StopRunning) {
    throw "T3 Code is running from $installDir. Close it, or re-run with -StopRunning to stop it (this ends its agent sessions)."
  }
  Write-Host "Stopping running T3 Code..."
  $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
}

if (-not $SkipDeps) {
  Write-Host "Installing dependencies..."
  pnpm install
  if ($LASTEXITCODE -ne 0) { throw "pnpm install failed ($LASTEXITCODE)" }
}

$buildStart = Get-Date
Write-Host "Building Windows installer ($Arch)..."
node scripts/build-desktop-artifact.ts --platform win --target nsis --arch $Arch --output-dir $releaseDir
if ($LASTEXITCODE -ne 0) { throw "Desktop build failed ($LASTEXITCODE)" }

$installer = Get-ChildItem $releaseDir -Filter "*.exe" -File |
  Where-Object { $_.LastWriteTime -ge $buildStart -and $_.Name -notlike "*__uninstaller*" } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $installer) { throw "No new installer found in $releaseDir" }

Write-Host "Installing $($installer.Name)..."
$proc = Start-Process -FilePath $installer.FullName -ArgumentList "/S" -Wait -PassThru
if ($proc.ExitCode -ne 0) { throw "Installer exited with $($proc.ExitCode)" }

$exe = Get-ChildItem $installDir -Filter "T3 Code*.exe" -File |
  Where-Object { $_.Name -notlike "Uninstall*" } |
  Select-Object -First 1
if (-not $exe) { throw "Install finished but no T3 Code executable was found in $installDir" }

Write-Host "Installed $($exe.VersionInfo.ProductVersion) at $($exe.FullName)"
