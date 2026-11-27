# CRJ Flexal - roda UMA VEZ em cada maquina da sala (pelo pendrive).
# Faz a maquina aceitar o painel do estudio em QUALQUER IP da rede da sala (antes: so 192.168.10.124).
# Continua exigindo a senha do CRJ-Admin (comandos) e a chave do estudio (Veyon).
# NAO mexe na rede, no IP, nos programas nem nos arquivos desta maquina: so em 3 regras do firewall.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""; exit }
$ErrorActionPreference = 'Continue'
$rel = Join-Path $PSScriptRoot 'resultado.txt'
function L($t, $c = 'Gray') { Write-Host "  $t" -ForegroundColor $c; Add-Content $rel "$(Get-Date -Format 'dd/MM HH:mm') $env:COMPUTERNAME  $t" -Encoding UTF8 }

Write-Host ''; Write-Host "  LIBERAR O PAINEL DO ESTUDIO NESTA MAQUINA ($env:COMPUTERNAME)" -ForegroundColor Yellow; Write-Host ''
$n = 0
foreach ($r in @(Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue) + @(Get-NetFirewallRule -DisplayName 'CRJ - Veyon do estudio', 'CRJ - Ping do estudio' -ErrorAction SilentlyContinue)) {
    $antes = ($r | Get-NetFirewallAddressFilter).RemoteAddress -join ','
    $r | Set-NetFirewallRule -RemoteAddress LocalSubnet
    L ("{0}: {1} -> rede da sala" -f $r.DisplayName, $antes) 'Green'; $n++
}
if (-not (Get-NetFirewallRule -DisplayName 'CRJ - Veyon do estudio' -ErrorAction SilentlyContinue) -and (Test-Path 'C:\Program Files\Veyon\veyon-service.exe')) {
    New-NetFirewallRule -DisplayName 'CRJ - Veyon do estudio' -Direction Inbound -Protocol TCP -LocalPort 11100 -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null; L 'Regra do Veyon criada (rede da sala).' 'Green'; $n++ }
if (-not (Get-NetFirewallRule -DisplayName 'CRJ - Ping do estudio' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'CRJ - Ping do estudio' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null; L 'Regra do ping criada (rede da sala).' 'Green'; $n++ }
if ($n) { L "Pronto: $n regra(s). O painel do estudio ja consegue falar com esta maquina." 'Cyan' } else { L 'Nenhuma regra do CRJ encontrada: esta maquina foi preparada?' 'Red' }
Write-Host ''; Read-Host '  Enter para fechar'
