# Diagnóstico da placa de rede: rode NA PRÓPRIA MÁQUINA (como administrador). Não depende da rede.
# Não muda nada, a menos que você aceite a tentativa de correção no final.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""; exit }
$ErrorActionPreference = 'SilentlyContinue'
$rel = Join-Path $PSScriptRoot ("diagnostico-rede-{0}-{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
function L($t = '', $cor = 'Gray') { Write-Host $t -ForegroundColor $cor; Add-Content $rel $t -Encoding UTF8 }
function Teste($ip, $n, $tam) {
    $p = New-Object System.Net.NetworkInformation.Ping; $buf = New-Object byte[] $tam; $ok = 0; $t = @()
    for ($i = 0; $i -lt $n; $i++) { try { $r = $p.Send($ip, 1000, $buf); if ($r.Status -eq 'Success') { $ok++; $t += $r.RoundtripTime } } catch {} ; Start-Sleep -Milliseconds 100 }
    [pscustomobject]@{ ok = $ok; n = $n; perda = [math]::Round(100 * ($n - $ok) / $n); media = if ($t) { [int]($t | Measure-Object -Average).Average } else { '-' } }
}

L "DIAGNÓSTICO DE REDE · $env:COMPUTERNAME · $(Get-Date -Format 'dd/MM/yyyy HH:mm')" Yellow
L ('=' * 70)
$n = Get-NetAdapter -Physical | Where-Object { $_.MediaType -match '802.3' -or $_.InterfaceDescription -match 'Ethernet|Realtek|Intel|GbE|FE' } | Sort-Object Status -Descending | Select-Object -First 1
if (-not $n) { L 'NENHUMA PLACA DE REDE CABEADA ENCONTRADA. Verifique se a placa aparece no Gerenciador de Dispositivos.' Red; Read-Host 'Enter para fechar'; exit }
$drv = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -eq $n.InterfaceDescription } | Select-Object -First 1
L "`n[1] PLACA E DRIVER" Cyan
L "  Placa ........... $($n.InterfaceDescription)"
L "  Situação ........ $($n.Status)  (cabo: $($n.MediaConnectionState))"
L "  Velocidade ...... $($n.LinkSpeed)   Duplex completo: $($n.FullDuplex)"
L "  MAC ............. $($n.MacAddress)"
L "  Driver .......... $($drv.DriverVersion)  de $(if ($drv.DriverDate) { ([datetime]$drv.DriverDate).ToString('dd/MM/yyyy') })  ($($drv.DriverProviderName))"
$ip = (Get-NetIPAddress -InterfaceIndex $n.ifIndex -AddressFamily IPv4).IPAddress
$gw = (Get-NetRoute -InterfaceIndex $n.ifIndex -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1).NextHop
L "  IP .............. $ip   Roteador: $gw"

L "`n[2] CONFIGURAÇÕES AVANÇADAS DA PLACA" Cyan
Get-NetAdapterAdvancedProperty -Name $n.Name | Where-Object { $_.DisplayName -match 'Speed|Velocidade|Duplex|Green|Eficiente|Energy|EEE|Power|Energia|Wake|Flow|Fluxo|Offload|Jumbo' } |
    ForEach-Object { L ("  {0,-42} {1}" -f $_.DisplayName, $_.DisplayValue) }
$pm = Get-NetAdapterPowerManagement -Name $n.Name
L ("  {0,-42} {1}" -f 'Windows pode desligar a placa p/ economizar', $pm.AllowComputerToTurnOffDevice)

L "`n[3] TESTE DE PERDA (enquanto conta os erros da placa)" Cyan
$s1 = Get-NetAdapterStatistics -Name $n.Name
$alvos = [ordered]@{ 'Roteador (pacote pequeno)' = @($gw, 64); 'Roteador (pacote grande)' = @($gw, 1400); 'PC do estúdio (grande)' = @('192.168.10.124', 1400); 'Internet 8.8.8.8 (grande)' = @('8.8.8.8', 1400) }
$res = @{}
foreach ($k in $alvos.Keys) { Write-Host "  testando $k..." -ForegroundColor DarkGray; $r = Teste $alvos[$k][0] 100 $alvos[$k][1]; $res[$k] = $r
    L ("  {0,-28} {1,3} de {2} respostas · perda {3,3}% · média {4} ms" -f $k, $r.ok, $r.n, $r.perda, $r.media) $(if ($r.perda -ge 10) { 'Red' } elseif ($r.perda -gt 0) { 'Yellow' } else { 'Green' }) }
$s2 = Get-NetAdapterStatistics -Name $n.Name
$rx = $s2.ReceivedUnicastPackets - $s1.ReceivedUnicastPackets; $erx = $s2.ReceivedPacketErrors - $s1.ReceivedPacketErrors
$etx = $s2.OutboundPacketErrors - $s1.OutboundPacketErrors; $drx = $s2.ReceivedDiscardedPackets - $s1.ReceivedDiscardedPackets
L "  Durante o teste: $rx pacotes recebidos · $erx com ERRO · $drx descartados · $etx erros ao enviar"
L "  Desde que ligou: $($s2.ReceivedUnicastPackets) recebidos · $($s2.ReceivedPacketErrors) com erro · $($s2.OutboundPacketErrors) erros ao enviar"

L "`n[4] QUEDAS DO CABO NOS ÚLTIMOS 7 DIAS (registro do Windows)" Cyan
$ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 20000 |
    Where-Object { $_.ProviderName -match 'rt640|rtl|Realtek|e1|NDIS|Tcpip|netr' -or $_.Message -match 'desconect|disconnect|link is down|link down|conexão de rede' } |
    Where-Object { $_.ProviderName -notmatch 'Kernel-Power|Power-Troubleshooter' -and $_.Message -match 'desconect|disconnect|down|perd|reset|redefin' }
L "  Eventos de queda/reinício da placa: $(@($ev).Count)"
$ev | Select-Object -First 8 | ForEach-Object { L ("   {0:dd/MM HH:mm}  {1}  {2}" -f $_.TimeCreated, $_.ProviderName, ($_.Message -split "`n")[0].Trim()) DarkGray }

L "`n[5] CONCLUSÃO" Yellow
$grande = $res['Roteador (pacote grande)'].perda; $peq = $res['Roteador (pacote pequeno)'].perda
$taxa = if ($rx -gt 0) { [math]::Round(100 * $erx / ($rx + $erx)) } else { 0 }
if ($n.Status -ne 'Up') { L '  O cabo/porta está SEM SINAL. Teste outra porta do roteador e outro cabo.' Red }
elseif ($grande -ge 10 -or $taxa -ge 5) {
    L "  PROBLEMA CONFIRMADO: perda de $grande% em pacotes grandes ($peq% nos pequenos), $taxa% dos pacotes com erro." Red
    if ($erx -gt 0) { L '  Os erros são de RECEPÇÃO na placa: o sinal chega corrompido. Como o cabo já foi trocado,' Red
                      L '  sobram: a PORTA do roteador ou a PLACA DE REDE da máquina.' Red }
    L '  Próximo teste (sem custo): ligue o cabo da Máquina 1 numa porta do roteador que funciona' White
    L '  com outra máquina e rode este diagnóstico de novo.' White
    L '   · Continuou ruim na porta boa  -> defeito na PLACA (placa USB/PCI de rede resolve, ~R$ 30-60).' White
    L '   · Melhorou                     -> defeito na PORTA do roteador (use outra porta).' White
} elseif ($grande -gt 0 -or $erx -gt 0) { L "  Problema leve: perda de $grande% e $erx erros. Vale rodar de novo daqui a pouco para comparar." Yellow }
else { L '  Rede OK neste momento: sem perda e sem erros. Se o problema é intermitente, rode de novo quando cair.' Green }

L "`nRelatório salvo em: $rel" DarkGray
Write-Host ''
if ((Read-Host 'Quer TENTAR CORRIGIR pelo driver (fixar 100 Mbps Full, desligar economia de energia) e testar de novo? S/N') -match '^[sS]') {
    L "`n[6] TENTATIVA DE CORREÇÃO" Cyan
    $antes = Get-NetAdapterAdvancedProperty -Name $n.Name | Where-Object RegistryKeyword -in '*SpeedDuplex', '*EEE', 'EnableGreenEthernet', 'PowerSavingMode', 'AdvancedEEE', 'EnableEnergyEfficientEthernet'
    $antes | ForEach-Object { L ("  antes: {0} = {1} ({2})" -f $_.RegistryKeyword, $_.DisplayValue, ($_.RegistryValue -join ',')) DarkGray }
    Set-NetAdapterAdvancedProperty -Name $n.Name -RegistryKeyword '*SpeedDuplex' -RegistryValue 4 -NoRestart     # 100 Mbps Full Duplex
    foreach ($k in '*EEE', 'EnableGreenEthernet', 'PowerSavingMode', 'AdvancedEEE', 'EnableEnergyEfficientEthernet') { Set-NetAdapterAdvancedProperty -Name $n.Name -RegistryKeyword $k -RegistryValue 0 -NoRestart }
    Set-NetAdapterPowerManagement -Name $n.Name -AllowComputerToTurnOffDevice Disabled
    L '  Reiniciando a placa (a rede cai por alguns segundos)...'
    Restart-NetAdapter -Name $n.Name; Start-Sleep 15
    $s1 = Get-NetAdapterStatistics -Name $n.Name; $r = Teste $gw 100 1400; $s2 = Get-NetAdapterStatistics -Name $n.Name
    L ("  Depois: roteador (grande) {0} de 100 · perda {1}% · {2} erros de recepção" -f $r.ok, $r.perda, ($s2.ReceivedPacketErrors - $s1.ReceivedPacketErrors)) $(if ($r.perda -lt $grande) { 'Green' } else { 'Red' })
    if ($r.perda -lt $grande) { L '  MELHOROU: era configuração/driver. Pode deixar assim (100 Mbps é o máximo desta placa).' Green }
    else { L '  Não melhorou: é físico (placa ou porta). Para voltar ao automático: Gerenciador de Dispositivos >' Red
           L '  placa de rede > Avançado > Velocidade e Duplex = Negociação automática.' Red }
}
Read-Host "`nEnter para fechar"
