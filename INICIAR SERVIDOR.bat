@echo off
title Servidor de preparacao - CRJ Informatica
cd /d "%~dp0"
echo Deixe esta janela ABERTA enquanto prepara os PCs da sala.
echo Nos PCs, rode (PowerShell como administrador):
echo     irm http://192.168.10.124:8000/preparar-pc.ps1 ^| iex
echo.
C:\Python314\python.exe -u servidor.py
pause
