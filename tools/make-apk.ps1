# Сборка Bwekh Player для Android: BwekhPlayer-arm64.apk и BwekhPlayer-arm32.apk.
# Запускается через make-apk.bat в корне проекта.

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$AppName   = 'BwekhPlayer'
$StorePass = 'flashplayer'
$ExtId     = 'com.vibefoxcodding.fpnative'
$SdkPage   = 'https://airsdk.harman.com/download'

function Step($t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Info($t) { Write-Host "    $t" }
function Warn($t) { Write-Host "    $t" -ForegroundColor Yellow }
function Fail($t) {
	Write-Host ''
	Write-Host "ОШИБКА: $t" -ForegroundColor Red
	exit 1
}
function Ask($t, $defaultYes = $true) {
	$hint = if ($defaultYes) { '[Y/n]' } else { '[y/N]' }
	$a = Read-Host "$t $hint"
	if ($a -eq '') { return $defaultYes }
	return ($a -match '^[YyДд]')
}

# ===========================================================================
# 1. AIR SDK
# ===========================================================================

function Test-Sdk($p) {
	return ($p -and (Test-Path (Join-Path $p 'bin\adt.bat')) -and (Test-Path (Join-Path $p 'bin\amxmlc.bat')))
}

function Find-SdkUnder($dir, $depth) {
	if (-not $dir -or -not (Test-Path $dir)) { return $null }
	if (Test-Sdk $dir) { return (Resolve-Path $dir).Path }
	if ($depth -le 0) { return $null }
	$subs = Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
	foreach ($s in $subs) {
		$r = Find-SdkUnder $s.FullName ($depth - 1)
		if ($r) { return $r }
	}
	return $null
}

$SdkPathFile = Join-Path $Root 'sdk-path.txt'

function Find-Sdk {
	if (Test-Sdk $env:AIR_SDK) { return $env:AIR_SDK }
	if (Test-Path $SdkPathFile) {
		$saved = (Get-Content -LiteralPath $SdkPathFile -Raw -ErrorAction SilentlyContinue)
		if ($saved) {
			$r = Find-SdkUnder $saved.Trim() 2
			if ($r) { return $r }
		}
	}
	$places = @(
		@("$Root\AIRSDK", 2),
		@("$HOME\sdks", 3),
		@('C:\AIRSDK', 1),
		@("$HOME\AIRSDK", 1),
		@("$HOME\AIR SDKs", 2),
		@("$HOME\Documents\sdks", 3),
		@('C:\sdks', 3),
		@('D:\sdks', 3),
		@('D:\AIRSDK', 1),
		@("$HOME\Documents\AIRSDK", 1),
		@("$HOME\Downloads\AIRSDK", 1)
	)
	foreach ($p in $places) {
		$r = Find-SdkUnder $p[0] $p[1]
		if ($r) { return $r }
	}
	foreach ($base in @("$HOME\Downloads", "$HOME\Desktop", "$HOME\Documents")) {
		if (-not (Test-Path $base)) { continue }
		$dirs = Get-ChildItem -LiteralPath $base -Directory -Filter 'AIRSDK*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
		foreach ($d in $dirs) {
			$r = Find-SdkUnder $d.FullName 2
			if ($r) { return $r }
		}
	}
	return $null
}

function Expand-SdkZip {
	$zips = @()
	foreach ($base in @("$HOME\Downloads", "$HOME\Desktop", "$HOME\Documents", $Root)) {
		if (Test-Path $base) {
			$zips += Get-ChildItem -LiteralPath $base -File -Filter 'AIRSDK*.zip' -ErrorAction SilentlyContinue
		}
	}
	if ($zips.Count -eq 0) { return $null }
	$zip = $zips | Sort-Object LastWriteTime -Descending | Select-Object -First 1
	$dest = Join-Path $Root 'AIRSDK'
	Info "Распаковываю $($zip.FullName) в $dest ..."
	New-Item -ItemType Directory -Force -Path $dest | Out-Null
	$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
	if ($tar) { & tar.exe -xf $zip.FullName -C $dest }
	if (-not $tar -or $LASTEXITCODE -ne 0) { Expand-Archive -LiteralPath $zip.FullName -DestinationPath $dest -Force }
	return (Find-SdkUnder $dest 2)
}

function Select-Folder($description) {
	try {
		Add-Type -AssemblyName System.Windows.Forms
		$dlg = New-Object System.Windows.Forms.FolderBrowserDialog
		$dlg.Description = $description
		$dlg.ShowNewFolderButton = $false
		$owner = New-Object System.Windows.Forms.Form
		$owner.TopMost = $true
		if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
	} catch { }
	return $null
}

Step 'Ищу Harman AIR SDK'
$Sdk = Find-Sdk
if (-not $Sdk) { $Sdk = Expand-SdkZip }
if (-not $Sdk) {
	Warn 'Не нашёл AIR SDK сам — выберите его папку в открывшемся окне.'
	Warn '(Если у вас только AIR SDK Manager — сначала скачайте в нём SDK.)'
	$picked = Select-Folder 'Папка с AIR SDK (в ней есть bin) или папка, куда AIR SDK Manager скачивает SDK'
	if ($picked) { $Sdk = Find-SdkUnder $picked 2 }
}
if (-not $Sdk) {
	Write-Host ''
	Write-Host 'AIR SDK не найден.' -ForegroundColor Yellow
	Write-Host ' - Через AIR SDK Manager: откройте его, скачайте SDK 51.x и запустите make-apk.bat ещё раз.'
	Write-Host ' - Или скачайте zip-архив AIR SDK с открывшейся страницы и оставьте его в «Загрузках».'
	Start-Process $SdkPage
	exit 1
}
Set-Content -LiteralPath $SdkPathFile -Value $Sdk -Encoding UTF8
Info "AIR SDK: $Sdk"

$Amxmlc = Join-Path $Sdk 'bin\amxmlc.bat'
$Acompc = Join-Path $Sdk 'bin\acompc.bat'
$Adt    = Join-Path $Sdk 'bin\adt.bat'
if (-not (Test-Path $Acompc)) { $Acompc = Join-Path $Sdk 'bin\compc.bat' }

# ===========================================================================
# 2. Java
# ===========================================================================

function Get-JavaMajor($exe) {
	$text = (& $exe -version 2>&1 | ForEach-Object { "$_" }) -join "`n"
	if ($text -match 'version "(\d+)(?:\.(\d+))?') {
		$major = [int]$Matches[1]
		if ($major -eq 1 -and $Matches[2]) { $major = [int]$Matches[2] }
		return $major
	}
	return 0
}

function Find-Java {
	$cands = New-Object System.Collections.ArrayList
	if ($env:JAVA_HOME) { [void]$cands.Add((Join-Path $env:JAVA_HOME 'bin\java.exe')) }
	foreach ($p in @(
		"$env:ProgramFiles\Android\Android Studio\jbr",
		"$env:ProgramFiles\Android\Android Studio\jre",
		"$env:LOCALAPPDATA\Programs\Android Studio\jbr")) {
		[void]$cands.Add((Join-Path $p 'bin\java.exe'))
	}
	foreach ($base in @(
		"$env:ProgramFiles\Java", "$env:ProgramFiles\Eclipse Adoptium", "$env:ProgramFiles\Microsoft",
		"$env:ProgramFiles\Zulu", "$env:ProgramFiles\BellSoft", "$env:ProgramFiles\Amazon Corretto",
		"$env:ProgramFiles\Unity\Hub\Editor")) {
		if (-not (Test-Path $base)) { continue }
		$dirs = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
		foreach ($d in $dirs) {
			[void]$cands.Add((Join-Path $d.FullName 'bin\java.exe'))
			# Unity ships its own OpenJDK
			[void]$cands.Add((Join-Path $d.FullName 'Editor\Data\PlaybackEngines\AndroidPlayer\OpenJDK\bin\java.exe'))
		}
	}
	$onPath = Get-Command java.exe -ErrorAction SilentlyContinue
	if ($onPath) { [void]$cands.Add($onPath.Source) }
	foreach ($exe in $cands) {
		if (-not (Test-Path $exe)) { continue }
		if ((Get-JavaMajor $exe) -ge 11) { return $exe }
	}
	return $null
}

Step 'Ищу Java 11+'
$Java = Find-Java
if (-not $Java) {
	Warn 'Java не найдена.'
	if ((Get-Command winget.exe -ErrorAction SilentlyContinue) -and (Ask 'Установить Microsoft OpenJDK 17 через winget?')) {
		& winget.exe install --id Microsoft.OpenJDK.17 -e --source winget
		$Java = Find-Java
	}
	if (-not $Java) {
		Start-Process 'https://learn.microsoft.com/java/openjdk/download'
		Fail 'Установите Java 17 и запустите make-apk.bat ещё раз.'
	}
}
$JavaBin = Split-Path -Parent $Java
$env:JAVA_HOME = Split-Path -Parent $JavaBin
$env:PATH = "$JavaBin;$env:PATH"
Info "Java: $Java"

# ===========================================================================
# 3. Android SDK (AIR собирает APK через Gradle и Android SDK)
# ===========================================================================

$AdtCfgDir = Join-Path $HOME '.airsdk'
$AdtCfg = Join-Path $AdtCfgDir 'adt.cfg'

function Test-AndroidSdk($p) {
	return ($p -and (Test-Path (Join-Path $p 'platforms')) -and (Test-Path (Join-Path $p 'build-tools')))
}

function Find-AndroidSdk {
	$cands = New-Object System.Collections.ArrayList
	if (Test-Path $AdtCfg) {
		foreach ($line in (Get-Content -LiteralPath $AdtCfg -ErrorAction SilentlyContinue)) {
			if ($line -match '^\s*AndroidPlatformSDK\s*=\s*(.+)$') { [void]$cands.Add($Matches[1].Trim().Replace('/', '\')) }
		}
	}
	foreach ($v in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, "$env:LOCALAPPDATA\Android\Sdk", 'C:\Android\Sdk', "$HOME\AppData\Local\Android\Sdk")) {
		if ($v) { [void]$cands.Add($v) }
	}
	foreach ($base in @("$env:ProgramFiles\Unity\Hub\Editor", "$env:ProgramFiles\Unity")) {
		if (-not (Test-Path $base)) { continue }
		$dirs = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
		foreach ($d in $dirs) { [void]$cands.Add((Join-Path $d.FullName 'Editor\Data\PlaybackEngines\AndroidPlayer\SDK')) }
	}
	foreach ($c in $cands) { if (Test-AndroidSdk $c) { return $c } }
	return $null
}

Step 'Ищу Android SDK'
$AndroidSdk = Find-AndroidSdk
if (-not $AndroidSdk) {
	Warn 'Android SDK не найден — без него AIR не соберёт APK.'
	Warn 'Проще всего поставить Android Studio: при первом запуске она сама скачает SDK.'
	if ((Get-Command winget.exe -ErrorAction SilentlyContinue) -and (Ask 'Установить Android Studio через winget?')) {
		& winget.exe install --id Google.AndroidStudio -e --source winget
		Write-Host ''
		Write-Host 'Запустите Android Studio, пройдите мастер первого запуска (Standard),' -ForegroundColor Yellow
		Write-Host 'дождитесь загрузки SDK и запустите make-apk.bat ещё раз.' -ForegroundColor Yellow
		exit 1
	}
	$picked = Select-Folder 'Папка Android SDK (в ней есть platforms и build-tools)'
	if ($picked -and (Test-AndroidSdk $picked)) { $AndroidSdk = $picked }
	if (-not $AndroidSdk) { Fail 'Android SDK не найден.' }
}
Info "Android SDK: $AndroidSdk"
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk

$platforms = Get-ChildItem -LiteralPath (Join-Path $AndroidSdk 'platforms') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
Info ("Платформы: " + ($platforms -join ', '))
# ADT понимает только папки вида platforms\android-NN (новые android-37.0 и т.п. не видит)
$numeric = @($platforms | Where-Object { $_ -match '^android-\d+$' })
$buildTools = @(Get-ChildItem -LiteralPath (Join-Path $AndroidSdk 'build-tools') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
Info ("Build-Tools: " + ($buildTools -join ', '))
$hasBt34 = @($buildTools | Where-Object { $_ -match '^3[4-9]\.' }).Count -gt 0
if (-not ($platforms -contains 'android-34') -or -not $hasBt34) {
	$sdkmanager = Get-ChildItem -Path (Join-Path $AndroidSdk 'cmdline-tools') -Filter 'sdkmanager.bat' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
	Warn 'Для AIR нужны Android SDK Platform 34 (Android 14) и Build-Tools 34.'
	if ($sdkmanager -and (Ask 'Доустановить их через sdkmanager?')) {
		& $sdkmanager.FullName 'platforms;android-34' 'build-tools;34.0.0' 'platform-tools'
		$platforms = Get-ChildItem -LiteralPath (Join-Path $AndroidSdk 'platforms') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
		$numeric = @($platforms | Where-Object { $_ -match '^android-\d+$' })
	}
}
if ($numeric.Count -eq 0) {
	Write-Host ''
	Write-Host 'Не хватает Android SDK Platform 34 — без неё ADT не соберёт APK.' -ForegroundColor Yellow
	Write-Host 'Поставьте в Android Studio: Settings → Languages & Frameworks → Android SDK:'
	Write-Host '  1) вкладка SDK Platforms: галочка «Android 14.0 (UpsideDownCake)» — API 34;'
	Write-Host '  2) вкладка SDK Tools: включите «Show Package Details», в Android SDK Build-Tools'
	Write-Host '     отметьте 34.0.0, и ещё отметьте «Android SDK Command-line Tools (latest)»;'
	Write-Host '  3) Apply → OK, дождитесь загрузки и запустите make-apk.bat ещё раз.'
	exit 1
}

# прописываем путь к SDK для ADT (~/.airsdk/adt.cfg)
New-Item -ItemType Directory -Force -Path $AdtCfgDir | Out-Null
$cfgLines = @()
if (Test-Path $AdtCfg) { $cfgLines = @(Get-Content -LiteralPath $AdtCfg | Where-Object { $_ -notmatch '^\s*AndroidPlatformSDK\s*=' }) }
$cfgLines += 'AndroidPlatformSDK=' + $AndroidSdk.Replace('\', '/')
Set-Content -LiteralPath $AdtCfg -Value $cfgLines -Encoding ASCII

# ===========================================================================
# 4. Нативное расширение (share, выбор файла, доступ к файлам)
# ===========================================================================

Step 'Собираю нативное расширение'
$Build = Join-Path $Root 'build'
$AneDir = Join-Path $Build 'ane'
$ExtDir = Join-Path $Build 'ext'
Remove-Item -LiteralPath $AneDir, $ExtDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$AneDir\android-arm", "$AneDir\android-arm64", "$AneDir\default", $ExtDir | Out-Null

$Swc = Join-Path $Build 'fpnative.swc'
& $Acompc '-source-path' 'native\as3' '-include-classes' 'com.vibefoxcodding.fpnative.FPNative' '-output' $Swc
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Swc)) { Fail 'Не удалось скомпилировать AS3-часть расширения (см. текст выше).' }

$zipCopy = Join-Path $Build 'fpnative-swc.zip'
Copy-Item -LiteralPath $Swc -Destination $zipCopy -Force
$swcOut = Join-Path $Build 'swc'
Remove-Item -LiteralPath $swcOut -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $zipCopy -DestinationPath $swcOut -Force
Copy-Item (Join-Path $swcOut 'library.swf') "$AneDir\default\library.swf"
foreach ($pd in @('android-arm', 'android-arm64')) {
	Copy-Item (Join-Path $swcOut 'library.swf') "$AneDir\$pd\library.swf"
	Copy-Item 'native\build\fpnative.jar' "$AneDir\$pd\fpnative.jar"
}
# нативный Ruffle (Rust): build-ruffle-native.bat кладёт его в native\build\ruffle-libs
$RuffleLibs = Join-Path $Root 'native\build\ruffle-libs'
$ruffleNative = $true
foreach ($pair in @(@('android-arm', 'armeabi-v7a'), @('android-arm64', 'arm64-v8a'))) {
	$src = Join-Path $RuffleLibs $pair[1]
	if (Test-Path (Join-Path $src 'libruffle_android.so')) {
		$dst = Join-Path $AneDir "$($pair[0])\libs\$($pair[1])"
		New-Item -ItemType Directory -Force -Path $dst | Out-Null
		Copy-Item (Join-Path $src '*.so') $dst
	} else { $ruffleNative = $false }
}
if ($ruffleNative) { Info 'Нативный Ruffle: есть (Android 5+, без WebView)' }
else { Warn 'Нативного Ruffle нет (native\build\ruffle-libs) — Ruffle будет только в WebView. Соберите его: build-ruffle-native.bat' }

$Ane = Join-Path $ExtDir "$ExtId.ane"
& $Adt -package -target ane $Ane 'native\extension.xml' -swc $Swc `
	-platform Android-ARM -C "$AneDir\android-arm" . `
	-platform Android-ARM64 -C "$AneDir\android-arm64" . `
	-platform default -C "$AneDir\default" .
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Ane)) { Fail 'Не удалось упаковать расширение (.ane).' }
Info "Расширение: build\ext\$ExtId.ane"

# ===========================================================================
# 5. Компиляция приложения
# ===========================================================================

Step 'Компилирую FlashPlayer.swf'
$Bin = Join-Path $Root 'bin'
Remove-Item -LiteralPath $Bin -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Bin | Out-Null
& $Amxmlc '+configname=airmobile' '-source-path+=src' '-external-library-path+=build\fpnative.swc' '-output' 'bin\FlashPlayer.swf' 'src\Main.as'
if ($LASTEXITCODE -ne 0 -or -not (Test-Path 'bin\FlashPlayer.swf')) {
	Fail 'Компиляция не удалась. Скопируйте текст ошибки выше и пришлите его — поправлю.'
}

New-Item -ItemType Directory -Force -Path "$Bin\icons" | Out-Null
Remove-Item -Recurse -Force "$Bin\web", "$Bin\ruffle" -ErrorAction SilentlyContinue
Copy-Item 'icons\icon*.png' "$Bin\icons\" -Exclude 'icon512.png'
# Ruffle (web build + our host page): only when there's no native Ruffle (build-ruffle-native.bat)
New-Item -ItemType Directory -Force -Path "$Bin\ruffle" | Out-Null
if ($ruffleNative) {
	# Ruffle version for the About screen: from native\ruffle-rs\Cargo.lock (ruffle_core)
	$rv = 'native'
	try {
		$lock = Get-Content -LiteralPath 'native\ruffle-rs\Cargo.lock' -Raw
		$m = [regex]::Match($lock, 'name = "ruffle_core"\s+version = "([^"]+)"\s+source = "[^"#]*#([0-9a-f]{7})')
		if ($m.Success) { $rv = "$($m.Groups[1].Value) nightly ($($m.Groups[2].Value))" }
	} catch { }
	Set-Content -LiteralPath "$Bin\ruffle\native.txt" -Value $rv -Encoding ASCII
}
else { Copy-Item 'ruffle\*' "$Bin\ruffle\" -Exclude '*.map' }

# ===========================================================================
# 6. APK для arm64 и arm32
# ===========================================================================

if (-not (Test-Path 'cert.p12')) {
	Step 'Создаю ключ для подписи APK (один раз, храните cert.p12 — им подписываются обновления)'
	& $Adt -certificate -cn $AppName -validityPeriod 25 2048-RSA cert.p12 $StorePass
	if ($LASTEXITCODE -ne 0) { Fail 'Не удалось создать сертификат.' }
}

$Dist = Join-Path $Root 'dist'
New-Item -ItemType Directory -Force -Path $Dist | Out-Null
# arm32: Android 5.0+ (minSdk 21), target Android 11 (targetSdk 30)
# arm64: SDK defaults of the AIR SDK
$desc32 = Join-Path $Build 'application-arm32.xml'
$xml = Get-Content -LiteralPath 'application.xml' -Raw -Encoding UTF8
$xml = $xml.Replace('<manifest android:installLocation="auto">',
	"<manifest android:installLocation=`"auto`">`r`n`t<uses-sdk android:minSdkVersion=`"21`" android:targetSdkVersion=`"30`"/>")
[System.IO.File]::WriteAllText($desc32, $xml, (New-Object System.Text.UTF8Encoding($false)))

$targets = @(
	@{ arch = 'armv8'; file = "$AppName-arm64.apk"; label = 'arm64 (64-бит)'; desc = 'application.xml' },
	@{ arch = 'armv7'; file = "$AppName-arm32.apk"; label = 'arm32 (32-бит, Android 5+, target Android 11)'; desc = $desc32 }
)
$built = @()
foreach ($t in $targets) {
	Step "Собираю APK: $($t.label)"
	$out = Join-Path $Dist $t.file
	Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
	& $Adt -package -target apk-captive-runtime -arch $t.arch `
		-storetype pkcs12 -keystore cert.p12 -storepass $StorePass `
		$out $t.desc -platformsdk $AndroidSdk -extdir $ExtDir `
		-C bin FlashPlayer.swf icons ruffle
	if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) {
		Fail "Не удалось собрать $($t.file). Текст ошибки выше — пришлите его."
	}
	$built += $out
	Info "Готово: dist\$($t.file)"
}

# ===========================================================================
# 7. Установка на подключённый телефон (необязательно)
# ===========================================================================

$adb = Join-Path $AndroidSdk 'platform-tools\adb.exe'
if (Test-Path $adb) {
	$devices = (& $adb devices) | Where-Object { $_ -match "`tdevice$" }
	if ($devices) {
		$abi = ((& $adb shell getprop ro.product.cpu.abi) | Out-String).Trim()
		$apk = if ($abi -match 'arm64') { $built[0] } else { $built[1] }
		if (Ask "Найден телефон ($abi). Установить $(Split-Path -Leaf $apk)?" $false) {
			& $adb install -r $apk
		}
	}
}

Step 'Готово!'
Write-Host '    dist\BwekhPlayer-arm64.apk — для большинства современных телефонов'
Write-Host '    dist\BwekhPlayer-arm32.apk — для старых 32-битных устройств'
Start-Process explorer.exe $Dist
exit 0
