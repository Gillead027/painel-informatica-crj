﻿# CRJ Flexal - cria o VIGIA do painel no PC do estudio.
# A cada 5 min, se o painel caiu, liga de novo (tarefa "CRJ - Painel (vigia)", na conta de quem usa o estudio).
# NAO mexe em rede, IP, seguranca nem programas.
param([string]$Usuario = "$env:USERDOMAIN\$env:USERNAME")
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Usuario `"$env:USERDOMAIN\$env:USERNAME`""; exit }
$base = Split-Path -Parent $PSCommandPath
$v = Join-Path $base 'painel\vigia-painel.vbs'
Write-Host ''; Write-Host '  VIGIA DO PAINEL (nao mexe na rede)' -ForegroundColor Yellow
try {
    $a = New-ScheduledTaskAction -Execute wscript.exe -Argument "`"$v`""
    $t1 = New-ScheduledTaskTrigger -AtLogOn -User $Usuario
    $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $p = New-ScheduledTaskPrincipal -UserId $Usuario -LogonType Interactive -RunLevel Limited
    $s = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName 'CRJ - Painel (vigia)' -Action $a -Trigger $t1, $t2 -Principal $p -Settings $s -Force | Out-Null
    Write-Host '  Vigia criado: confere o painel a cada 5 minutos.' -ForegroundColor Green
} catch { Write-Host "  Erro: $($_.Exception.Message)" -ForegroundColor Red }
Read-Host '  Enter para fechar'
