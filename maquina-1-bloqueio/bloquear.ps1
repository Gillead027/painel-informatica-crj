# Roda NA PROPRIA MAQUINA, como administrador (CRJ-Admin). Nao depende da rede.
$ErrorActionPreference = 'Continue'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""; exit }
New-Item -ItemType Directory -Force 'C:\ProgramData\CRJ' | Out-Null
Write-Host ''; Write-Host '  BLOQUEAR PARA MANUTENCAO (modo defeito)' -ForegroundColor Yellow
Write-Host '  Alunos nao vao conseguir entrar. Quem estiver logado (inclusive voce) sai em 20 segundos.'
Write-Host ''; if ((Read-Host '  Digite S para confirmar') -notmatch '^[sS]') { exit }
$imgB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'defeito.jpg')))
$r = & {
# bloqueia TUDO para alunos: aviso antes do login, imagem na tela de bloqueio, conta do aluno desativada
$pasta = 'C:\ProgramData\CRJ'
$titulo = 'MÁQUINA COM DEFEITO'
$texto = 'Estamos trabalhando nela. Acesse outra máquina ou procure o educador Gillead.'
$alunos = @(Get-LocalGroupMember -Group 'Alunos CRJ' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Split('\')[-1] })
# guarda o estado anterior (para liberar depois)
$sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$csp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
if (-not (Test-Path "$pasta\defeito.json")) {
    $antes = [pscustomobject]@{
        caption = (Get-ItemProperty $sys -ErrorAction SilentlyContinue).legalnoticecaption
        text    = (Get-ItemProperty $sys -ErrorAction SilentlyContinue).legalnoticetext
        tela    = (Get-ItemProperty $csp -ErrorAction SilentlyContinue).LockScreenImagePath
        alunos  = $alunos
    }
    $antes | ConvertTo-Json | Set-Content "$pasta\defeito.json" -Encoding UTF8
}
# 1) imagem de defeito na tela de bloqueio
[IO.File]::WriteAllBytes("$pasta\defeito.jpg", [Convert]::FromBase64String($imgB64))
if (-not (Test-Path $csp)) { New-Item $csp -Force | Out-Null }
New-ItemProperty $csp -Name LockScreenImagePath -Value "$pasta\defeito.jpg" -PropertyType String -Force | Out-Null
New-ItemProperty $csp -Name LockScreenImageUrl -Value "$pasta\defeito.jpg" -PropertyType String -Force | Out-Null
New-ItemProperty $csp -Name LockScreenImageStatus -Value 1 -PropertyType DWord -Force | Out-Null
Disable-ScheduledTask -TaskName 'CRJ - Tela de bloqueio' -ErrorAction SilentlyContinue | Out-Null   # nao trocar a imagem enquanto estiver com defeito
# 2) aviso antes de qualquer login
New-ItemProperty $sys -Name legalnoticecaption -Value $titulo -PropertyType String -Force | Out-Null
New-ItemProperty $sys -Name legalnoticetext -Value $texto -PropertyType String -Force | Out-Null
# 3) avisa quem estiver usando e desconecta em 20 s
$sessoes = @(quser 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -replace '^>', ' ').Trim() -split '\s{2,}' } )
if ((Get-CimInstance Win32_ComputerSystem).UserName) {
    msg.exe * /TIME:20 "$titulo`n`n$texto`n`nVocê será desconectado em 20 segundos."
}
# 4) conta do aluno desativada (so o CRJ-Admin entra)
foreach ($a in $alunos) { Disable-LocalUser -Name $a -ErrorAction SilentlyContinue }
Set-Content "$pasta\defeito.txt" "DEFEITO desde $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
$sair = "Start-Sleep 20; quser 2>`$null | Select-Object -Skip 1 | ForEach-Object { `$id = (`$_ -replace '^>', ' ').Trim() -split '\s+' | Where-Object { `$_ -match '^\d+$' } | Select-Object -First 1; if (`$id) { logoff `$id } }"
$acao = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -WindowStyle Hidden -Command `"$sair`""
Register-ScheduledTask -TaskName 'CRJ - Desconectar (defeito)' -Action $acao -User SYSTEM -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'CRJ - Desconectar (defeito)'
[pscustomobject]@{ ok = $true; msg = "modo defeito ligado; conta(s) desativada(s): $($alunos -join ', ')" }
}
Write-Host ''; Write-Host "  $($r.msg)" -ForegroundColor Green; Write-Host '  Pronto. Para liberar depois: LIBERAR.cmd (ou "Liberar maquina" no painel).'; Start-Sleep 12
