# Guarda a senha do CRJ-Admin criptografada (DPAPI): so a conta "CRJ FLEXAL" neste PC consegue ler.
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host 'Digite a senha do CRJ-Admin (a mesma usada na Maquina 10).' -ForegroundColor Cyan
$sec = Read-Host -AsSecureString 'Senha do CRJ-Admin'
New-Object PSCredential('CRJ-Admin', $sec) | Export-Clixml (Join-Path $base 'chaves\crj-admin.cred')
Write-Host 'Senha guardada com seguranca. Pode fechar.' -ForegroundColor Green
Start-Sleep 3
