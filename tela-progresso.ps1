# CRJ Flexal - janela de progresso mostrada na tela do aluno durante a manutencao.
# Le C:\ProgramData\CRJ\progresso.log (escrito pela manutencao remota) e mostra cada passo.
$log = 'C:\ProgramData\CRJ\progresso.log'
$n = 0
Clear-Host
Write-Host ''
Write-Host '   ==============================================================' -ForegroundColor Cyan
Write-Host '      CRJ Flexal  -  Manutenção da informática em andamento' -ForegroundColor White
Write-Host '      Pode continuar usando. Não desligue este computador.' -ForegroundColor Gray
Write-Host '   ==============================================================' -ForegroundColor Cyan
Write-Host ''
$fimEm = $null
while ($true) {
    $linhas = @(Get-Content $log -Encoding UTF8 -ErrorAction SilentlyContinue)
    while ($n -lt $linhas.Count) {
        $p = $linhas[$n].Split('|', 3)
        $n++
        if ($p.Count -lt 3) { continue }
        if ($p[2] -eq 'FIM') {
            Write-Host ''
            Write-Host '   ==============================================================' -ForegroundColor Green
            Write-Host '      Concluído! Esta janela fecha sozinha em 20 segundos.' -ForegroundColor Green
            Write-Host '   ==============================================================' -ForegroundColor Green
            Start-Sleep 20
            exit
        }
        $cor = $p[0]; if ($cor -notin 'White', 'Gray', 'Green', 'Yellow', 'Cyan', 'Red', 'Magenta') { $cor = 'White' }
        Write-Host ('   [' + $p[1] + ']  ' + $p[2]) -ForegroundColor $cor
    }
    Start-Sleep -Milliseconds 700
    if (-not $fimEm) { $fimEm = (Get-Date).AddHours(3) } elseif ((Get-Date) -gt $fimEm) { exit }
}
