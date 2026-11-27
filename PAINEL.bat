@echo off
title Painel da Informatica - CRJ (deixe esta janela aberta)
rem Funciona de qualquer lugar (inclusive da pasta Inicializar): procura a pasta do projeto na Area de Trabalho
for /d %%D in ("%USERPROFILE%\Desktop\CONTRLE INFORM*TICA") do set "PROJ=%%D"
if not defined PROJ (
  echo Pasta "CONTRLE INFORMATICA" nao encontrada na Area de Trabalho.
  pause
  exit /b 1
)
cd /d "%PROJ%\painel"
rem abre o CHROME 5 segundos depois, quando o painel ja estiver no ar
start "" /min cmd /c "timeout /t 5 /nobreak >nul & start "" "C:\Program Files\Google\Chrome\Application\chrome.exe" http://127.0.0.1:8080"
echo Painel rodando. Pode minimizar esta janela, mas NAO feche.
C:\Python314\python.exe -u painel.py
echo.
echo O painel parou. Se apareceu um erro acima, tire uma foto e mande.
pause
