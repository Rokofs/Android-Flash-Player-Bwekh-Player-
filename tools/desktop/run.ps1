# Bwekh Player on this PC (AIR's adl), to try games without the phone.
# Games: put .swf files into the "games" folder next to this file (made on the first start).
# Log: BwekhPlayer-log.txt next to this file (when logging is on in src\fp\Log.as).
# Ruffle runs only on the phone; here the games play in AIR / AVM1.
# Start: powershell -ExecutionPolicy Bypass -File run.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$sdk = (Get-Content (Join-Path $PSScriptRoot '..\..\sdk-path.txt') -Raw).Trim([char]0xFEFF).Trim()
# the TLF library for Flash CS5 games, built once with this SDK's compiler (tools\tlf)
# (again when its sources change: newer than air-built.txt / air-failed.txt)
$tlfDir = Join-Path $PSScriptRoot '..\tlf'
$marks = @('air-built.txt', 'air-failed.txt') | ForEach-Object { Join-Path $tlfDir $_ } | Where-Object { Test-Path $_ }
$markTime = if ($marks) { ($marks | ForEach-Object { (Get-Item $_).LastWriteTime } | Measure-Object -Maximum).Maximum } else { [datetime]::MinValue }
$srcTime = (Get-ChildItem (Join-Path $tlfDir 'src'), (Join-Path $tlfDir 'root') -Recurse -File | Measure-Object -Property LastWriteTime -Maximum).Maximum
if ($srcTime -gt $markTime) {
	& powershell -ExecutionPolicy Bypass -File (Join-Path $tlfDir 'build-tlf.ps1')
}
Write-Host 'Compiling...'
& (Join-Path $sdk 'bin\amxmlc.bat') '+configname=airmobile' '-source-path+=..\..\src' '-output' 'BwekhPlayer.swf' '..\..\src\Main.as'
if ($LASTEXITCODE -ne 0) { Write-Host 'compile failed'; exit 1 }
if (-not (Test-Path 'games')) { New-Item -ItemType Directory 'games' | Out-Null }
& (Join-Path $sdk 'bin\adl.exe') '-profile' 'extendedDesktop' 'desktop.xml'
