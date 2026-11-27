# Preparacao do PC do ESTUDIO (192.168.10.124) - rodar UMA vez, como administrador.
# Nao apaga nada. So instala o Veyon Master, cria as chaves e libera o servidor de preparacao.
$ErrorActionPreference = 'Continue'
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
Start-Transcript -Path (Join-Path $base 'relatorios\estudio-log.txt') -Force | Out-Null

Write-Host '== 1. Firewall: liberar servidor de preparacao (porta 8000, so rede 192.168.10.x)'
$py = 'C:\Python314\python.exe'
if (-not (Get-NetFirewallRule -DisplayName 'CRJ - Servidor de preparacao' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'CRJ - Servidor de preparacao' -Direction Inbound -Action Allow `
        -Program $py -Protocol TCP -LocalPort 8000 -RemoteAddress 192.168.10.0/24 -Profile Any | Out-Null
}

Write-Host '== 2. WinRM (cliente) para comandar os PCs da sala'
Set-Service WinRM -StartupType Manual
Start-Service WinRM
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '192.168.10.*' -Force

Write-Host '== 3. Instalar Veyon (Master + Service)'
$veyonCli = 'C:\Program Files\Veyon\veyon-cli.exe'
if (-not (Test-Path $veyonCli)) {
    Start-Process (Join-Path $base 'instaladores\veyon-setup.exe') -ArgumentList '/S' -Wait
}

Write-Host '== 4. Chaves de autenticacao do Veyon'
& $veyonCli authkeys list
if (-not ((& $veyonCli authkeys list) -match 'crj/private')) {
    & $veyonCli authkeys create crj
}
$usuarios = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
& $veyonCli authkeys setaccessgroup crj/private $usuarios
& $veyonCli authkeys export crj/public (Join-Path $base 'chaves\crj_public_key.pem')

Write-Host '== 5. Informacoes de configuracao (para conferencia)'
& $veyonCli authkeys list
& $veyonCli config list
& $veyonCli networkobjects help

Stop-Transcript | Out-Null
Write-Host ''
Write-Host 'PRONTO. Pode fechar esta janela.' -ForegroundColor Green
Start-Sleep 5
