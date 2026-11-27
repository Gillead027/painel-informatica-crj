# CRJ Flexal - manutencao automatica semanal (roda em cada PC da sala, como SISTEMA).
# O PC acorda sozinho (despertador), limpa, verifica virus, atualiza e volta a hibernar se a sala estiver fechada.
param([switch]$PosReinicio, [switch]$Verificar)
$P = 'C:\ProgramData\CRJ'
$LOG = "$P\manutencao-semanal.log"
function L($m) { Add-Content $LOG "[$(Get-Date -Format 'dd/MM HH:mm:ss')] $m" -Encoding UTF8 }
if ((Test-Path $LOG) -and (Get-Item $LOG).Length -gt 300KB) { Set-Content $LOG '' -Encoding UTF8 }
function Avisar($titulo, $msg, $prio = 4) {
    # manda direto para o celular do educador (ntfy), sem depender do PC do estudio. Topico em avisos.json (so SISTEMA/admin leem).
    try {
        if (-not (Test-Path "$P\avisos.json")) { return }
        $a = Get-Content "$P\avisos.json" -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $a.ativo -or -not $a.topico -or -not $a.falha) { return }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $nome = if ($a.nome) { $a.nome } else { $env:COMPUTERNAME }
        $corpo = @{ topic = $a.topico; title = "${nome}: $titulo"; message = $msg; priority = $prio; tags = @('computer') } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri $a.servidor -Body ([Text.Encoding]::UTF8.GetBytes($corpo)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 | Out-Null
        L "Aviso enviado ao celular: $titulo"
    } catch { L "Aviso NAO enviado: $($_.Exception.Message)" }
}

function SalaFechadaAgora {
    # usa o horario de funcionamento programado nesta maquina (tarefas "CRJ - Abertura" e "CRJ - Fechamento").
    # Logo depois de acordar da hibernacao o agendador pode demorar a responder: tenta varias vezes e,
    # se nao conseguir, decide pelo dia/hora (fim de semana, antes das 13h ou depois das 19h = fechada). Na duvida, FECHADA.
    $agora = Get-Date
    $hoje = [int][Math]::Pow(2, [int]$agora.DayOfWeek)   # dom=1, seg=2, ter=4...
    $fecha = $null; $abre = $null
    for ($i = 1; $i -le 6; $i++) {
        try {
            $tf = Get-ScheduledTask -TaskName 'CRJ - Fechamento' -ErrorAction Stop
            $gf = @($tf.Triggers | Where-Object { ([int]$_.DaysOfWeek -band $hoje) -ne 0 })
            if (-not $gf) { L 'Decisao: hoje a sala nao abre (sem fechamento programado para hoje).'; return $true }
            $ta = Get-ScheduledTask -TaskName 'CRJ - Abertura' -ErrorAction Stop
            $ga = @($ta.Triggers | Where-Object { ([int]$_.DaysOfWeek -band $hoje) -ne 0 })
            $fecha = ([datetime]$gf[0].StartBoundary).TimeOfDay
            $abre = if ($ga) { ([datetime]$ga[0].StartBoundary).TimeOfDay } else { [timespan]'13:00' }
            break
        } catch { L "Agendador ainda nao respondeu (tentativa $i): $($_.Exception.Message)"; Start-Sleep 15 }
    }
    if ($null -eq $fecha) {
        $fds = $agora.DayOfWeek -in [DayOfWeek]::Saturday, [DayOfWeek]::Sunday
        $r = $fds -or $agora.Hour -lt 13 -or $agora.Hour -ge 19
        L "Decisao sem o horario da maquina: fim de semana=$fds, hora=$($agora.ToString('HH:mm')) -> fechada=$r"
        return $r
    }
    $r = ($agora.TimeOfDay -lt $abre -or $agora.TimeOfDay -ge $fecha)
    L ("Decisao: hoje abre {0:hh\:mm} e fecha {1:hh\:mm}; agora {2:HH:mm} -> fechada={3}" -f $abre, $fecha, $agora, $r)
    return $r
}
function Finalizar {
    $estado = Get-Content "$P\estado.txt" -ErrorAction SilentlyContinue
    $pausado = [bool]($estado | Where-Object { $_ -like 'PAUSADO*' })
    if ($pausado) { L 'Maquina em modo manutencao (PAUSADO): continua ligada.'; return }
    if (SalaFechadaAgora) { L 'Sala fechada: voltando a hibernar.'; Start-Sleep 20; shutdown.exe /h }
    else { L 'Sala aberta (ou em manutencao): a maquina continua ligada.' }
}

if ($Verificar) {
    # rede de seguranca: 1h30 depois da manutencao. Se a maquina ainda esta ligada com a sala fechada, hiberna e avisa.
    $estado = Get-Content "$P\estado.txt" -ErrorAction SilentlyContinue
    if ([bool]($estado | Where-Object { $_ -like 'PAUSADO*' })) { L 'Verificacao: em modo manutencao, continua ligada.'; return }
    if (SalaFechadaAgora) {
        L 'Verificacao: a maquina ainda estava ligada com a sala fechada. Hibernando.'
        Avisar 'ainda estava ligada depois da manutencao' 'Hibernei agora (rede de seguranca da propria maquina).' 4
        Start-Sleep 20; shutdown.exe /h
    } else { L 'Verificacao: sala aberta, nada a fazer.' }
    return
}

if ($PosReinicio) {
    if (-not (Test-Path "$P\manutencao-reiniciou.txt")) { return }
    [IO.File]::Delete("$P\manutencao-reiniciou.txt")
    L 'Voltou do reinicio da manutencao; aguardando 5 min para o Windows terminar as atualizacoes.'
    Start-Sleep 300; Finalizar; return
}

L '===== inicio da manutencao semanal ====='
$resumo = @()
# 1) temporarios
$antes = 0; $depois = 0; $lim = (Get-Date).AddDays(-1)
$pastas = @("$env:WINDIR\Temp") + (Get-ChildItem C:\Users -Directory -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)\AppData\Local\Temp" })
foreach ($p in $pastas | Where-Object { Test-Path $_ }) {
    $antes += (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $lim } | ForEach-Object { try { [IO.File]::Delete($_.FullName) } catch {} }
    $depois += (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
}
$mb = [int](($antes - $depois) / 1MB); L "Temporarios: $mb MB liberados"; $resumo += "$mb MB limpos"
# 2) antivirus
try { Update-MpSignature -ErrorAction Stop; L 'Antivirus atualizado' } catch { L "Antivirus: $($_.Exception.Message)" }
try { Start-MpScan -ScanType QuickScan -ErrorAction Stop; $amea = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddHours(-2) }).Count
      L "Verificacao rapida concluida: $amea ameaca(s) encontrada(s)"; $resumo += "antivirus ok ($amea ameaca)" } catch { L "Verificacao: $($_.Exception.Message)"; $resumo += 'antivirus com erro' }
# 3) Windows Update (atualizacoes e drivers)
$reiniciar = $false
try {
    $s = New-Object -ComObject Microsoft.Update.Session; $r = $s.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")
    if ($r.Updates.Count) {
        $col = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $r.Updates) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$col.Add($u); L "  atualizacao: $($u.Title)" }
        $d = $s.CreateUpdateDownloader(); $d.Updates = $col; [void]$d.Download()
        $i = $s.CreateUpdateInstaller(); $i.Updates = $col; $res = $i.Install()
        $reiniciar = $res.RebootRequired; L "Windows Update: codigo $($res.ResultCode), reiniciar=$reiniciar"; $resumo += "$($col.Count) atualizacao(oes)"
    } else { L 'Windows Update: nada pendente'; $resumo += 'Windows em dia' }
} catch { L "Windows Update: $($_.Exception.Message)"; $resumo += 'Windows Update com erro' }
Set-Content "$P\manutencao-ultima.txt" "$(Get-Date -Format 'dd/MM HH:mm') | $($resumo -join ' | ')" -Encoding UTF8
if ($amea -gt 0) { Avisar "antivirus encontrou $amea ameaca(s)" ($resumo -join ' | ') 5 }
elseif (($resumo -join ' ') -match 'erro') { Avisar 'manutencao com problema' ($resumo -join ' | ') 4 }
L '===== fim ====='
if ($reiniciar) { Set-Content "$P\manutencao-reiniciou.txt" 'sim'; L 'Reiniciando para concluir as atualizacoes...'; shutdown.exe /r /t 60 /c 'Manutencao semanal do CRJ: reiniciando para concluir atualizacoes.' }
else { Finalizar }
