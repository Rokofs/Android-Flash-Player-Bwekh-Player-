# Сборка нативного Ruffle (Rust) для Bwekh Player: native\build\ruffle-libs\<abi>\libruffle_android.so
# Исходники: native\ruffle-rs (ruffle-android, переделанный под NativeActivity).
# Нужны: Rust (rustup), cargo-ndk, Android NDK. Запускается через build-ruffle-native.bat.

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Step($t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Info($t) { Write-Host "    $t" }
function Fail($t) { Write-Host ''; Write-Host "ОШИБКА: $t" -ForegroundColor Red; exit 1 }

$env:PATH = "$HOME\.cargo\bin;$env:PATH"

Step 'Проверяю Rust'
if (-not (Get-Command rustup.exe -ErrorAction SilentlyContinue)) {
	Start-Process 'https://rustup.rs'
	Fail 'Rust не найден. Установите его с https://rustup.rs (rustup-init.exe, всё по умолчанию) и запустите ещё раз.'
}

Step 'Ищу Android NDK'
$sdk = $null
foreach ($v in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, "$env:LOCALAPPDATA\Android\Sdk")) {
	if ($v -and (Test-Path (Join-Path $v 'ndk'))) { $sdk = $v; break }
}
if (-not $sdk) { Fail 'Не найден Android SDK с NDK (Android Studio → SDK Manager → SDK Tools → NDK (Side by side)).' }
$ndk = Get-ChildItem -LiteralPath (Join-Path $sdk 'ndk') -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $ndk) { Fail 'В Android SDK нет NDK (Android Studio → SDK Manager → SDK Tools → NDK (Side by side)).' }
$env:ANDROID_NDK_HOME = $ndk.FullName
$env:ANDROID_NDK_ROOT = $ndk.FullName
Info "NDK: $($ndk.FullName)"

$Crate = Join-Path $Root 'native\ruffle-rs'
$Out = Join-Path $Root 'native\build\ruffle-libs'
# короткий путь: длинные пути Windows ломают сборку
$env:CARGO_TARGET_DIR = Join-Path $HOME 'ruffle-target'
Set-Location $Crate

Step 'Rust нужной версии и цели Android (в первый раз — несколько минут)'
& rustup toolchain install
if ($LASTEXITCODE -ne 0) { Fail 'rustup toolchain install не удался (текст выше).' }
& rustup target add aarch64-linux-android armv7-linux-androideabi
if ($LASTEXITCODE -ne 0) { Fail 'rustup target add не удался (текст выше).' }

Step 'cargo-ndk'
if (-not (Get-Command cargo-ndk.exe -ErrorAction SilentlyContinue)) {
	& cargo install cargo-ndk
	if ($LASTEXITCODE -ne 0) { Fail 'cargo install cargo-ndk не удался (текст выше).' }
}

Step 'Собираю Ruffle (в первый раз 20-60 минут)'
Remove-Item -LiteralPath $Out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Out | Out-Null
# -P 21: работает с Android 5.0
& cargo ndk -t armeabi-v7a -t arm64-v8a -P 21 -o $Out build --release
if ($LASTEXITCODE -ne 0) { Fail 'Сборка не удалась. Скопируйте последние 30-50 строк текста выше и пришлите их.' }

Step 'Проверяю результат'
$readelf = Get-ChildItem -Path (Join-Path $ndk.FullName 'toolchains\llvm\prebuilt') -Filter 'llvm-readelf.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
foreach ($abi in @('arm64-v8a', 'armeabi-v7a')) {
	$so = Join-Path $Out "$abi\libruffle_android.so"
	if (-not (Test-Path $so)) { Fail "Нет $so" }
	$mb = [math]::Round((Get-Item $so).Length / 1MB, 1)
	Info "$abi\libruffle_android.so — $mb МБ"
	if ($readelf) {
		$needed = (& $readelf.FullName -d $so) | Where-Object { $_ -match 'NEEDED' } | ForEach-Object { if ($_ -match '\[(.+)\]') { $Matches[1] } }
		Info ("  нужны: " + ($needed -join ', '))
		if ($needed -contains 'libc++_shared.so') {
			$cxx = Get-ChildItem -Path (Join-Path $ndk.FullName 'toolchains\llvm\prebuilt') -Recurse -Filter 'libc++_shared.so' -ErrorAction SilentlyContinue |
				Where-Object { $_.FullName -match $(if ($abi -eq 'arm64-v8a') { 'aarch64-linux-android' } else { 'arm-linux-androideabi' }) } | Select-Object -First 1
			if ($cxx) { Copy-Item $cxx.FullName (Join-Path $Out "$abi\libc++_shared.so"); Info '  + libc++_shared.so' }
		}
	}
}
Write-Host ''
Write-Host '    Готово: native\build\ruffle-libs. Теперь запустите make-apk.bat.' -ForegroundColor Green
exit 0
