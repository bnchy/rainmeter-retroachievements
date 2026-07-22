@echo off
REM Deletes the downloaded badge art. The skin re-fetches whatever it
REM needs on the next refresh, so this is always safe to run.
del /q "%~dp0..\DownloadFile\*.png" >nul 2>&1
