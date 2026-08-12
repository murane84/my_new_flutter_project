@echo off
REM ---------------------------------------------------------------------------
REM deploy_web.bat — build the Flutter web app and PUBLISH it so the live site
REM (https://aluta.ozilane.com) actually updates.
REM
REM Why this exists: `flutter build web` writes to build\web, but the backend
REM only serves my_aluta_api\webapp. If the fresh build isn't copied there and
REM pushed, Railway keeps serving the OLD bundle — the "web stuck on old
REM version" problem. This does build -> replace webapp -> commit -> push in one
REM step so the two can never drift again.
REM
REM Usage:  double-click, or from a terminal:  deploy_web.bat
REM ---------------------------------------------------------------------------
setlocal
cd /d %~dp0

REM Clear any stale git locks left by cloud-side commits on this folder — they
REM can block the commit below with "cannot lock ref 'HEAD': ...HEAD.lock exists".
REM Harmless if the files aren't there (2>nul swallows "not found").
del /f /q ".git\HEAD.lock" ".git\index.lock" ".git\refs\heads\main.lock" 2>nul

echo == flutter pub get ==
call flutter pub get || goto :err

echo == building web (release) ==
call flutter build web --release --dart-define=PROD_URL=https://aluta.ozilane.com || goto :err

echo == replacing my_aluta_api\webapp with the fresh build ==
if exist my_aluta_api\webapp rmdir /s /q my_aluta_api\webapp
xcopy build\web my_aluta_api\webapp /E /I /Y || goto :err

echo == committing + pushing (Railway auto-deploys) ==
git add -A my_aluta_api\webapp
git commit -m "Deploy latest web build"
git push origin main || goto :err

echo.
echo ============================================================
echo  Done. Railway will redeploy in ~1-2 min.
echo  Then hard-refresh the site once (Ctrl+Shift+R) to bypass
echo  the browser's cached service worker.
echo ============================================================
goto :eof

:err
echo.
echo *** BUILD/DEPLOY FAILED - see the error above. ***
exit /b 1
