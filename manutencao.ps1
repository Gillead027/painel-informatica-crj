# Controle dos PCs da sala a partir do ESTUDIO.
# Exemplos:
#   .\manutencao.ps1 -PC "Maquina 10" -Acao Status
#   .\manutencao.ps1 -PC "Maquina 10" -Acao Pausar -Horas 2
#   .\manutencao.ps1 -PC "Maquina 10" -Acao Aplicar
#   .\manutencao.ps1 -PC todos -Acao Status
#   .\manutencao.ps1 -PC "Maquina 10" -Acao Instalar     (envia/atualiza restricoes.ps1 e aviso.vbs)
param(
    [Parameter(Mandatory)][string[]]$PC,
    [ValidateSet('Status', 'Pausar', 'Aplicar', 'Instalar')][string]$Acao = 'Status',
    [int]$Horas = 3
)
$base  = Split-Path -Parent $MyInvocation.MyCommand.Path
$lista = Import-Csv (Join-Path $base 'computadores.csv')
$alvos = if ($PC -contains 'todos') { $lista } else { $lista | Where-Object { $PC -contains $_.Nome -or $PC -contains $_.IP } }
if (-not $alvos) { Write-Host "PC nao encontrado em computadores.csv: $PC" -ForegroundColor Red; return }
$senha = (Import-Clixml (Join-Path $base 'chaves\crj-admin.cred')).Password

foreach ($m in $alvos) {
    Write-Host "`n=== $($m.Nome) ($($m.IP))" -ForegroundColor Cyan
    try {
        $cred = New-Object PSCredential("$($m.IP)\CRJ-Admin", $senha)
        $s = New-PSSession -ComputerName $m.IP -Credential $cred -ErrorAction Stop
        if ($Acao -eq 'Instalar') {
            Invoke-Command -Session $s { New-Item -ItemType Directory -Force C:\ProgramData\CRJ | Out-Null }
            Copy-Item (Join-Path $base 'restricoes.ps1'), (Join-Path $base 'aviso.vbs') -Destination 'C:\ProgramData\CRJ\' -ToSession $s -Force
        }
        Invoke-Command -Session $s -ArgumentList $Acao, $Horas {
            param($acao, $horas)
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\CRJ\restricoes.ps1 -Modo $acao -Horas $horas
        }
        Remove-PSSession $s
    } catch { Write-Host "Sem conexao: $($_.Exception.Message)" -ForegroundColor Red }
}
