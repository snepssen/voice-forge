# Voice Forge installer, Windows.
#
#   irm https://raw.githubusercontent.com/snepssen/voice-forge/main/install.ps1 | iex
#
# Read it before you run it. Piping a remote script into a shell is exactly the
# thing worth being suspicious of, and this one is short enough to skim:
#
#   irm https://raw.githubusercontent.com/snepssen/voice-forge/main/install.ps1
#
# It asks GitHub for the latest release, downloads the installer for this
# machine, checks its SHA256 against the checksums published in the same
# release, and runs it. It never writes outside your temp folder and whatever
# the installer itself creates.
$ErrorActionPreference = 'Stop'
$repo = 'snepssen/voice-forge'

function Say  { param($m) Write-Host "  $m" }
function Die  { param($m) Write-Host ''; Write-Host "  $m" -ForegroundColor Red; Write-Host ''; exit 1 }

Write-Host ''; Write-Host '  Voice Forge'; Write-Host ''

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
Say "system:  Windows $arch"

try {
  $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
} catch {
  Die @"
Could not reach the release. If the repository is still private this will always
  fail -- the download needs credentials a public installer cannot have. Ask for
  a build directly instead: https://t.me/snepssen
"@
}
Say "release: $($rel.tag_name)"

# Asset names are read from the release rather than constructed, so a change to
# how the build names its files cannot silently break this.
$asset = $rel.assets | Where-Object { $_.name -like "*$arch*.exe" } | Select-Object -First 1
if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -like '*.exe' } | Select-Object -First 1 }
if (-not $asset) { Die "This release has no Windows installer." }

$tmp = Join-Path $env:TEMP ("voice-forge-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$file = Join-Path $tmp $asset.name

Say "file:    $($asset.name)"
Write-Host '  downloading... ' -NoNewline
Invoke-WebRequest $asset.browser_download_url -OutFile $file
Write-Host ("done ({0:N0} MB)" -f ((Get-Item $file).Length / 1MB))

# Checked against the checksums published alongside the build. A mismatch means
# the file is not the one that was built, and that is a stop, not a warning.
$sums = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
if ($sums) {
  $text = (Invoke-WebRequest $sums.browser_download_url).Content
  $line = ($text -split "`n") | Where-Object { $_ -match [regex]::Escape($asset.name) } | Select-Object -First 1
  if ($line) {
    $want = ($line -split '\s+')[0]
    $got  = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    if ($want.ToLower() -ne $got) { Die "Checksum mismatch. Expected $want, got $got. Nothing was installed." }
    Say 'checksum: verified'
  } else { Say 'checksum: this file is not listed in SHA256SUMS -- not verified' }
} else { Say 'checksum: no SHA256SUMS in this release -- not verified' }

Write-Host ''
Say 'Running the installer. Windows may warn that the publisher is unknown --'
Say 'the app is unsigned, because code signing certificates cost money this'
Say 'project does not spend. Choose "More info" then "Run anyway" if you trust it.'
Write-Host ''
Start-Process -FilePath $file -Wait

Write-Host ''
Say 'Done. Voice Forge should be in your Start menu.'
Say 'Nothing here talks to the network. If it stops working: https://t.me/snepssen'
Write-Host ''
