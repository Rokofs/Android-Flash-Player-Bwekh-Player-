# Пересборка Java-части (native/build/fpnative.jar) из исходников native/android/src.
# Нужна, только если вы меняли Java-код: make-apk.bat берёт уже собранный jar.
# Запускается через build-native.bat в корне проекта.

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Step($t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Fail($t) { Write-Host ''; Write-Host "ОШИБКА: $t" -ForegroundColor Red; exit 1 }

# --- JDK (нужен javac и jar, не только java) -------------------------------
function Find-Jdk {
	$homes = New-Object System.Collections.ArrayList
	if ($env:JAVA_HOME) { [void]$homes.Add($env:JAVA_HOME) }
	foreach ($p in @("$env:ProgramFiles\Android\Android Studio\jbr", "$env:LOCALAPPDATA\Programs\Android Studio\jbr")) { [void]$homes.Add($p) }
	foreach ($base in @("$env:ProgramFiles\Microsoft", "$env:ProgramFiles\Java", "$env:ProgramFiles\Eclipse Adoptium",
	                    "$env:ProgramFiles\Zulu", "$env:ProgramFiles\BellSoft", "$env:ProgramFiles\Amazon Corretto")) {
		if (Test-Path $base) {
			Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
				ForEach-Object { [void]$homes.Add($_.FullName) }
		}
	}
	$onPath = Get-Command javac.exe -ErrorAction SilentlyContinue
	if ($onPath) { [void]$homes.Add((Split-Path -Parent (Split-Path -Parent $onPath.Source))) }
	foreach ($h in $homes) {
		if ((Test-Path (Join-Path $h 'bin\javac.exe')) -and (Test-Path (Join-Path $h 'bin\jar.exe'))) { return $h }
	}
	return $null
}

# --- android.jar из Android SDK ----------------------------------------------
function Find-AndroidJar {
	$sdks = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, "$env:LOCALAPPDATA\Android\Sdk") | Where-Object { $_ }
	foreach ($sdk in $sdks) {
		$plat = Join-Path $sdk 'platforms'
		if (-not (Test-Path $plat)) { continue }
		# любая платформа от android-30 и новее подойдёт; берём самую новую
		$jars = Get-ChildItem -LiteralPath $plat -Directory -ErrorAction SilentlyContinue |
			ForEach-Object { Join-Path $_.FullName 'android.jar' } | Where-Object { Test-Path $_ } | Sort-Object -Descending
		if ($jars) { return @($jars)[0] }
	}
	return $null
}

Step 'Ищу JDK'
$Jdk = Find-Jdk
if (-not $Jdk) { Fail 'Не найден JDK с javac (подойдёт Microsoft OpenJDK 17: winget install Microsoft.OpenJDK.17).' }
Write-Host "    JDK: $Jdk"

Step 'Ищу android.jar'
$AndroidJar = Find-AndroidJar
if (-not $AndroidJar) { Fail 'Не найден Android SDK (platforms\android-XX\android.jar). Установите Android Studio и одну платформу Android 11+.' }
Write-Host "    $AndroidJar"

$Javac = Join-Path $Jdk 'bin\javac.exe'
$JarExe = Join-Path $Jdk 'bin\jar.exe'
$Tmp = Join-Path $Root 'build\native-classes'
$Stubs = Join-Path $Root 'build\native-stubs'
foreach ($d in @($Tmp, $Stubs)) {
	if (Test-Path $d) { Remove-Item -Recurse -Force $d }
	New-Item -ItemType Directory -Force -Path $d | Out-Null
}

Step 'Компилирую заглушки AIR (com.adobe.fre)'
# Настоящие классы FRE даёт сам AIR на телефоне; здесь нужны только для компиляции
$stubSrc = Get-ChildItem -Recurse -Filter *.java (Join-Path $Root 'native\android\fre-stubs') | ForEach-Object { $_.FullName }
& $Javac --release 8 -encoding UTF-8 -nowarn -cp $AndroidJar -d $Stubs @stubSrc
if ($LASTEXITCODE -ne 0) { Fail 'Не удалось скомпилировать заглушки.' }

Step 'Компилирую расширение'
$src = Get-ChildItem -Recurse -Filter *.java (Join-Path $Root 'native\android\src') | ForEach-Object { $_.FullName }
& $Javac --release 8 -encoding UTF-8 -nowarn -cp "$AndroidJar;$Stubs" -d $Tmp @src
if ($LASTEXITCODE -ne 0) { Fail 'Ошибка компиляции Java (текст выше).' }

Step 'Собираю native\build\fpnative.jar'
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'native\build') | Out-Null
$Out = Join-Path $Root 'native\build\fpnative.jar'
if (Test-Path $Out) { Remove-Item -Force $Out }
& $JarExe cf $Out -C $Tmp .
if ($LASTEXITCODE -ne 0) { Fail 'Не удалось собрать jar.' }
Write-Host "    Готово: native\build\fpnative.jar" -ForegroundColor Green
Write-Host '    Теперь запустите make-apk.bat.'
