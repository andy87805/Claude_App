@echo off
rem ===========================================================================
rem  Double-click this file to start the AD tool.
rem  - No need to change the PowerShell execution policy: -ExecutionPolicy Bypass
rem    applies only to this run and does not change any system setting.
rem  - Start-ADPermissionQuery.ps1 and the .psm1 files must be in the same folder.
rem  - Extra arguments are passed through to the script, e.g. -QueryOnly
rem ===========================================================================
setlocal
set "SCRIPT=%~dp0Start-ADPermissionQuery.ps1"
if not exist "%SCRIPT%" (
    echo.
    echo  [X] Cannot find Start-ADPermissionQuery.ps1 in this folder:
    echo      %~dp0
    echo      Please keep all downloaded files in the same folder.
    echo.
    pause
    exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
if errorlevel 1 (
    echo.
    pause
)
endlocal
