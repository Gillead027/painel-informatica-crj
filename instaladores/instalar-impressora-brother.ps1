# Instala a impressora da informatica (Brother DCP-7065DN, na rede) NESTE PC.
# Usa o nome de rede da impressora (BRN30055C38016E): continua funcionando mesmo se o roteador trocar o IP dela.
$ErrorActionPreference = 'Stop'
$base = Split-Path -Parent $PSCommandPath
$log = Join-Path $base 'instalar-impressora.log'
function L($t) { Add-Content $log "$(Get-Date -Format 'dd/MM HH:mm:ss') $t" -Encoding UTF8 }
Set-Content $log '' -Encoding UTF8
try {
    $driver = 'Brother Laser Type1 Class Driver'
    $nome = 'Brother DCP-7065DN (Informatica)'
    $host_ = 'BRN30055C38016E'
    if (-not (Get-PrinterDriver -Name $driver -ErrorAction SilentlyContinue)) {
        $r = pnputil.exe /add-driver (Join-Path $base 'drv-brother\prnbrcl1.inf') /install 2>&1 | Out-String
        L "pnputil: $($r.Trim() -replace '\s+', ' ')"
        Add-PrinterDriver -Name $driver
        L 'driver instalado'
    } else { L 'driver ja existia' }
    if (-not (Get-PrinterPort -Name $host_ -ErrorAction SilentlyContinue)) { Add-PrinterPort -Name $host_ -PrinterHostAddress $host_; L 'porta criada' }
    if (-not (Get-Printer -Name $nome -ErrorAction SilentlyContinue)) { Add-Printer -Name $nome -DriverName $driver -PortName $host_; L 'impressora criada' } else { L 'impressora ja existia' }
    L "OK: $((Get-Printer -Name $nome).PrinterStatus)"
} catch { L "ERRO: $($_.Exception.Message)" }

