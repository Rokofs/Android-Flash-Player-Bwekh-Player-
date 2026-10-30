# Builds src\fp\assets\textLayout_1.0.0.595.swf (Text Layout Framework 1.0, build 595) with the
# AIR SDK's own compiler (see README.txt). Run by tools\desktop\run.ps1 once (air-built.txt marks it).
# Start by hand: powershell -ExecutionPolicy Bypass -File build-tlf.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$sdk = (Get-Content (Join-Path $PSScriptRoot '..\..\sdk-path.txt') -Raw).Trim([char]0xFEFF).Trim()
$out = Join-Path $PSScriptRoot 'textLayout-air.swf'
Write-Host 'Compiling the Text Layout Framework (the first start only, takes a minute)...'
$log = Join-Path $PSScriptRoot 'build-tlf.log'
Remove-Item (Join-Path $PSScriptRoot 'air-failed.txt') -ErrorAction SilentlyContinue
Remove-Item $out -ErrorAction SilentlyContinue
$ErrorActionPreference = 'Continue'
& (Join-Path $sdk 'bin\amxmlc.bat') '+configname=airmobile' `
	'-source-path+=src\textLayout_core\src' '-source-path+=src\textLayout_conversion\src' '-source-path+=src\textLayout_edit\src' `
	'-define=CONFIG::debug,false' '-define=CONFIG::release,true' '-warnings=false' `
	'-output' $out 'root\TlfAll.as' 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) {
	Set-Content (Join-Path $PSScriptRoot 'air-failed.txt') ('failed ' + (Get-Date) + ', see build-tlf.log')
	Write-Host 'TLF compile failed (tools\tlf\build-tlf.log): the player keeps the TLF it has'
	exit 1
}
Copy-Item $out (Join-Path $PSScriptRoot '..\..\src\fp\assets\textLayout_1.0.0.595.swf') -Force
Set-Content (Join-Path $PSScriptRoot 'air-built.txt') ('built ' + (Get-Date))
Write-Host 'TLF built.'
