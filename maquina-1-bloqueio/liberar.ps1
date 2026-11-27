# Roda NA PROPRIA MAQUINA, como administrador (CRJ-Admin). Nao depende da rede.
$ErrorActionPreference = 'Continue'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""; exit }
New-Item -ItemType Directory -Force 'C:\ProgramData\CRJ' | Out-Null
$r = & {
$pasta = 'C:\ProgramData\CRJ'
$sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$csp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
$antes = if (Test-Path "$pasta\defeito.json") { Get-Content "$pasta\defeito.json" -Raw | ConvertFrom-Json } else { $null }
$alunos = @(Get-LocalGroupMember -Group 'Alunos CRJ' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Split('\')[-1] }) + @($antes.alunos) | Where-Object { $_ } | Select-Object -Unique
foreach ($a in $alunos) { Enable-LocalUser -Name $a -ErrorAction SilentlyContinue }
# aviso antes do login: volta ao que era (normalmente nenhum)
if ($antes.caption) { Set-ItemProperty $sys -Name legalnoticecaption -Value $antes.caption } else { Set-ItemProperty $sys -Name legalnoticecaption -Value '' }
if ($antes.text) { Set-ItemProperty $sys -Name legalnoticetext -Value $antes.text } else { Set-ItemProperty $sys -Name legalnoticetext -Value '' }
# tela de bloqueio: volta para as imagens do CRJ (ou para a anterior)
Enable-ScheduledTask -TaskName 'CRJ - Tela de bloqueio' -ErrorAction SilentlyContinue | Out-Null
if (Test-Path "$pasta\telas\trocar.ps1") { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$pasta\telas\trocar.ps1" }
elseif ($antes.tela) { Set-ItemProperty $csp -Name LockScreenImagePath -Value $antes.tela; Set-ItemProperty $csp -Name LockScreenImageUrl -Value $antes.tela }
else { Set-ItemProperty $csp -Name LockScreenImageStatus -Value 0 -ErrorAction SilentlyContinue }
foreach ($f in 'defeito.txt', 'defeito.json') { if (Test-Path "$pasta\$f") { [IO.File]::Delete("$pasta\$f") } }
Unregister-ScheduledTask -TaskName 'CRJ - Desconectar (defeito)' -Confirm:$false -ErrorAction SilentlyContinue
[pscustomobject]@{ ok = $true; msg = "maquina liberada; conta(s) reativada(s): $($alunos -join ', ')" }
}
Write-Host ''; Write-Host "  $($r.msg)" -ForegroundColor Green; Read-Host '  Enter para fechar'
