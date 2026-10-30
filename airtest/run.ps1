# Desktop test of how AIR takes a game patched by SoPatch (see AirTest.as).
# Put the game next to this file as game.swf, then: powershell -ExecutionPolicy Bypass -File run.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$sdk = (Get-Content (Join-Path $PSScriptRoot '..\..\sdk-path.txt') -Raw).Trim([char]0xFEFF).Trim()
& (Join-Path $sdk 'bin\amxmlc.bat') '+configname=air' '-source-path+=..\..\src' '-output' 'AirTest.swf' 'AirTest.as'
if ($LASTEXITCODE -ne 0) { Write-Host 'compile failed'; exit 1 }
& (Join-Path $sdk 'bin\adl.exe') 'airtest.xml'
Write-Host 'log: airtest-log.txt'
