@echo off
chcp 65001 >nul
setlocal
rem ============================================================
rem  PageArk 一键真机验证：构建 debug → 安装 → 启动 → 按键截屏
rem  截图回收到 vtest\（已被 .gitignore 忽略，不进库）
rem  用法：双击运行；设备上操作到待验证界面后，在本窗口按任意键
rem        截一张，可连续截多张；直接关闭窗口结束。
rem ============================================================
set "DEVECO=D:\Software\DevEco Studio"
set "JAVA_HOME=%DEVECO%\jbr"
set "DEVECO_SDK_HOME=%DEVECO%\sdk"
set "PATH=%DEVECO%\tools\node;%JAVA_HOME%\bin;%PATH%"
set "HDC=%DEVECO_SDK_HOME%\default\openharmony\toolchains\hdc.exe"
set "HAP=entry\build\default\outputs\default\entry-default-signed.hap"
set "OUT=vtest"

cd /d %~dp0
if not exist "%OUT%" mkdir "%OUT%"

"%HDC%" list targets | findstr /r /c:"." >nul
if errorlevel 1 (
  echo [错误] 未检测到已连接的设备/模拟器（hdc list targets 为空）
  exit /b 1
)

echo [1/4] 构建 debug HAP ...
call "%DEVECO%\tools\hvigor\bin\hvigorw.bat" --mode module -p product=default -p buildMode=debug assembleHap --no-daemon
if errorlevel 1 (
  echo [错误] 构建失败
  exit /b 1
)

echo [2/4] 安装到设备 ...
"%HDC%" install -r "%HAP%"
if errorlevel 1 (
  echo [错误] 安装失败
  exit /b 1
)

echo [3/4] 启动应用 ...
"%HDC%" shell aa start -b com.example.pageark -a EntryAbility

echo [4/4] 进入截屏循环：设备上操作到目标界面后，在本窗口按任意键截一张；关闭本窗口结束
set /a N=1
:shot
pause >nul
"%HDC%" shell snapshot_display -f /data/local/tmp/pa_verify.jpeg >nul 2>&1
"%HDC%" file recv /data/local/tmp/pa_verify.jpeg "%OUT%\shot-%N%.jpeg" >nul 2>&1
if errorlevel 1 (
  echo [错误] 第 %N% 张截图失败
) else (
  echo       已保存 %OUT%\shot-%N%.jpeg
)
set /a N+=1
goto shot
