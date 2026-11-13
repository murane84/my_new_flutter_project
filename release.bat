@echo off
REM ---------------------------------------------------------------------------
REM release.bat - one command for a new Aluta release:
REM   1. raises the version in pubspec.yaml (patch by default)
REM   2. builds Android (arm64 + universal APK) and Windows (zipped)
REM   3. puts the files in dist\ with clear names
REM   4. commits the version and runs deploy_web.bat (web + server)
REM   5. waits for the new server, then publishes the files to
REM      aluta.ozilane.com/admin/release (if the key is set)
REM
REM Usage:   release.bat            1.0.2+3 -> 1.0.3+4
REM          release.bat minor      1.0.2+3 -> 1.1.0+4
REM          release.bat major      1.0.2+3 -> 2.0.0+4
REM          release.bat build      1.0.2+3 -> 1.0.2+4
REM          release.bat publish    no build: publish what's in dist\ now
REM                                 (e.g. after a failed upload)
REM          release.bat required   (with any of the above, e.g.
REM                                 "release.bat minor required") makes it a
REM                                 REQUIRED update: older builds are blocked
REM                                 until they install it. Asks to confirm.
REM                                 Only for a real breaking change.
REM
REM What's new: write it in RELEASE_NOTES.txt (one change per line) first.
REM
REM Auto-publish: set your publish key ONCE on this PC (it stays private):
REM          setx ALUTA_RELEASE_KEY "your-UPLOAD_KEY-value"
REM   then open a NEW cmd window. Without it, the uploader page opens instead.
REM ---------------------------------------------------------------------------
setlocal
cd /d %~dp0
set URL=https://aluta.ozilane.com
set DEFINE=--dart-define=PROD_URL=%URL%

del /f /q ".git\HEAD.lock" ".git\index.lock" ".git\refs\heads\main.lock" 2>nul

set KIND=%1
set REQ=
if /i "%1"=="required" (set REQ=1& set KIND=%2)
if /i "%2"=="required" set REQ=1
if /i "%KIND%"=="publish" goto :publish_only

copy /y pubspec.yaml pubspec.yaml.bak >nul
for /f "delims=" %%v in ('node tools\bump_version.js %KIND%') do set VER=%%v
if "%VER%"=="" goto :err
call :split_version
echo.
echo ==== Aluta %NAME% (build %BUILD%) ====

call flutter pub get || goto :err
echo == Android: arm64 APK ==
call flutter build apk --release --split-per-abi --no-pub %DEFINE% || goto :err
echo == Android: universal APK ==
call flutter build apk --release --no-pub %DEFINE% || goto :err
echo == Windows ==
REM A running Aluta locks Aluta.exe (LNK1104 "cannot open file") - close it.
taskkill /IM Aluta.exe /F >nul 2>&1
call flutter build windows --release --no-pub %DEFINE% || goto :err

if not exist dist mkdir dist
del /f /q dist\* 2>nul
copy /y build\app\outputs\flutter-apk\app-arm64-v8a-release.apk dist\aluta-%NAME%-arm64.apk >nul || goto :err
copy /y build\app\outputs\flutter-apk\app-release.apk dist\aluta-%NAME%-universal.apk >nul || goto :err
REM Zip with Windows' own zipper: tar's "./" entries made Explorer show the
REM zip as EMPTY (and an odd archive looks more suspicious to scanners).
powershell -NoProfile -Command "Compress-Archive -Path 'build\windows\x64\runner\Release\*' -DestinationPath 'dist\aluta-%NAME%-windows.zip' -Force" || goto :err
del /f /q pubspec.yaml.bak 2>nul
echo == Files in dist\ ==
dir /b dist

if not exist RELEASE_NOTES.txt echo Improvements and fixes> RELEASE_NOTES.txt

echo == committing the version ==
git add pubspec.yaml RELEASE_NOTES.txt
git commit -q -m "Release %NAME% (build %BUILD%)"

REM Publish to the server that's live NOW, then deploy. (Deploying first
REM raced Railway's switch-over: the old server still answered, took the
REM upload, and was stopped mid-way - phones kept seeing the old build.)
set DEPLOY=1
goto :publish_all

:publish_only
for /f "delims=" %%v in ('node tools\bump_version.js show') do set VER=%%v
call :split_version
if not exist dist\aluta-%NAME%-arm64.apk (
  echo dist\ has no build of %NAME% - run release.bat to build it.
  exit /b 1
)
echo ==== publishing Aluta %NAME% (build %BUILD%) from dist\ ====

:publish_all
set MINF=
if not "%REQ%"=="1" goto :req_done
echo.
echo  ************************************************************
echo   REQUIRED UPDATE: every Aluta older than build %BUILD% will be
echo   blocked until it installs %NAME%. Use only for a real breaking
echo   change (e.g. an incompatible server change).
echo  ************************************************************
set /p OKREQ=Type YES to make it required (anything else = normal update): 
if /i "%OKREQ%"=="YES" (set MINF=-F "min_build=%BUILD%") else (set REQ=& echo Publishing as a normal update.)
:req_done
if "%ALUTA_RELEASE_KEY%"=="" (
  echo.
  echo No ALUTA_RELEASE_KEY in this window - opening the uploader page.
  echo Version %NAME%, build %BUILD%. Files are in dist\
  if "%DEPLOY%"=="1" call deploy_web.bat
  start "" "%URL%/admin/release"
  exit /b 0
)
REM Universal first: the arm64 publish is what announces the update, and
REM older phones must find their file already there when they look.
call :publish android-universal aluta-%NAME%-universal.apk || goto :pubfail
call :publish android aluta-%NAME%-arm64.apk || goto :pubfail
call :publish windows aluta-%NAME%-windows.zip || goto :pubfail
echo == what phones see now ==
curl.exe -s "%URL%/app/latest?platform=android"
echo.
if "%DEPLOY%"=="1" (
  echo == web + server ==
  call deploy_web.bat || goto :err
)

:done
echo.
echo ============================================================
echo  Aluta %NAME% (build %BUILD%) is out.
echo  Open apps get an "is ready" toast now; closed phones get a
echo  notification; anyone else sees it at next open.
echo  Check: %URL%/app/latest?platform=android shows build %BUILD%
if "%REQ%"=="1" echo  REQUIRED: older builds are blocked until they update.
echo ============================================================
goto :eof

:pubfail
echo.
echo *** Publishing failed - the build is safe in dist\.
echo     Fix the cause above, then run:  release.bat publish
exit /b 1

:split_version
for /f "tokens=1,2 delims=+" %%a in ("%VER%") do (
  set NAME=%%a
  set BUILD=%%b
)
exit /b 0

:publish
echo == publishing %1 ==
curl.exe -sS --fail-with-body -X POST "%URL%/admin/release" ^
  -H "X-Release-Key: %ALUTA_RELEASE_KEY%" ^
  -F "key=%ALUTA_RELEASE_KEY%" -F "platform=%1" -F "version=%NAME%" ^
  -F "build=%BUILD%" -F "notes=<RELEASE_NOTES.txt" %MINF% -F "file=@dist\%2" || exit /b 1
echo.
exit /b 0

:err
echo.
echo *** RELEASE FAILED - see the error above. ***
if exist pubspec.yaml.bak (
  copy /y pubspec.yaml.bak pubspec.yaml >nul
  del /f /q pubspec.yaml.bak
  echo The version in pubspec.yaml was put back.
)
exit /b 1
