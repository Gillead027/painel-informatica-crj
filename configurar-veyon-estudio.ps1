# Atualiza o Veyon do ESTUDIO: autenticacao por chave + lista de PCs (computadores.csv).
# Rodar como administrador sempre que adicionar PCs no computadores.csv. Nao apaga nada nos PCs.
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$cli  = 'C:\Program Files\Veyon\veyon-cli.exe'
Start-Transcript -Path (Join-Path $base 'relatorios\veyon-estudio-log.txt') -Force | Out-Null

& $cli config set Authentication/Method 1
& $cli networkobjects clear
& $cli networkobjects add location 'Informatica'
foreach ($pc in Import-Csv (Join-Path $base 'computadores.csv')) {
    & $cli networkobjects add computer $pc.Nome $pc.IP $pc.MAC 'Informatica'
}
& $cli networkobjects list
& $cli service restart

Stop-Transcript | Out-Null
Start-Sleep 3
