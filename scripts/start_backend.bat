@echo off
REM 启动管理端 Backend（Windows）
cd /d "%~dp0.."
if "%PORT%"=="" set PORT=8310
echo Services-Deployment backend -^> http://localhost:%PORT% (docs: /docs)
python -m uvicorn backend.main:app --host 0.0.0.0 --port %PORT%
pause
