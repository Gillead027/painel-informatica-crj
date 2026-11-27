# CRJ Flexal - slides da TELA DE BLOQUEIO (roda escondido na conta do aluno).
# Troca a imagem da tela de bloqueio da conta no intervalo escolhido no painel. Atualiza na hora, mesmo com a tela bloqueada.
$p = 'C:\ProgramData\CRJ\telas'
$mutex = New-Object System.Threading.Mutex($false, 'Local\CRJSlidesBloqueio')
if (-not $mutex.WaitOne(0)) { exit }   # ja existe uma copia rodando nesta sessao
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$ops = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
$opT = ($ops | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$actT = ($ops | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
[void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime]
function Foto($caminho) {
    $t = $opT.MakeGenericMethod([Windows.Storage.StorageFile]).Invoke($null, @([Windows.Storage.StorageFile]::GetFileFromPathAsync($caminho))); [void]$t.Wait(30000)
    $a = $actT.Invoke($null, @([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($t.Result))); [void]$a.Wait(30000)
}
$i = -1; $ultimaCfg = ''
while ($true) {
    try {
        if (Test-Path 'C:\ProgramData\CRJ\defeito.txt') { Start-Sleep 30; continue }   # modo defeito: a imagem vermelha (forcada) manda
        $txt = Get-Content "$p\config.json" -Raw -ErrorAction Stop
        $c = $txt | ConvertFrom-Json
        if (-not $c.bloqueio) { exit }
        $imgs = @(Get-ChildItem $p -File | Where-Object { $_.Extension -match '^\.(jpe?g|png|bmp)$' } | Sort-Object Name)
        if (-not $imgs) { Start-Sleep 60; continue }
        $seg = [int]$c.intervaloSeg
        if ($txt -ne $ultimaCfg) { $i = -1; $ultimaCfg = $txt }   # configuracao mudou: recomeca
        $i = ($i + 1) % $imgs.Count
        Foto $imgs[$i].FullName
        if ($seg -le 0 -or $imgs.Count -eq 1) {
            # foto fixa: confere a cada 5 min se o painel mudou algo
            do { Start-Sleep 300 } while ((Get-Content "$p\config.json" -Raw -ErrorAction SilentlyContinue) -eq $ultimaCfg -and @(Get-ChildItem $p -File | Where-Object { $_.Extension -match '^\.(jpe?g|png|bmp)$' }).Count -eq $imgs.Count)
            $i = -1; continue
        }
        Start-Sleep ([math]::Max(5, $seg))
    } catch { Start-Sleep 30 }
}
