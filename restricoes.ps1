# ======================================================================
#  CRJ Flexal - Controle Informática - restrições de um PC da sala
#  Fica instalado em C:\ProgramData\CRJ\restricoes.ps1 (só administradores alteram).
#
#  Modos:
#    -Modo Instalar   instala atalhos, aviso de bloqueio e aplica as restrições
#    -Modo Aplicar    liga todas as restrições
#    -Modo Pausar     modo manutenção: desliga as restrições por -Horas (padrão 3) e reativa sozinho
#    -Modo Status     mostra o estado atual
#  -Aluno "NOME"      conta do aluno (entra no grupo "Alunos CRJ")
#  -Interativo        mostra janelas de confirmação (usado pelos atalhos)
# ======================================================================
param(
    [ValidateSet('Instalar', 'Aplicar', 'Pausar', 'Status')][string]$Modo = 'Status',
    [int]$Horas = 3,
    [string]$Aluno = '',
    [switch]$Interativo
)
$ErrorActionPreference = 'Continue'
$PASTA       = 'C:\ProgramData\CRJ'
$SCRIPT      = Join-Path $PASTA 'restricoes.ps1'
$ESTADO      = Join-Path $PASTA 'estado.txt'
$GRUPO       = 'Alunos CRJ'
$TAREFA_VOLTA = 'CRJ - Reativar restricoes'
$TAREFA_AVISO = 'CRJ - Aviso de bloqueio'
$ADMIN       = 'CRJ-Admin'
$DOH         = 'https://family.cloudflare-dns.com/dns-query'

function Msg($texto, $icone = 'Information') {
    Write-Host $texto
    if ($Interativo) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($texto, 'CRJ Flexal - Informática', 'OK', $icone) | Out-Null
    }
}

# ---------------- Políticas dos navegadores ----------------
# [caminho, nome, valor, tipo]  (listas: subchave com valor "1")
$POLITICAS = @(
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'ExtensionDeveloperModeSettings', 1, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'IncognitoModeAvailability', 1, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'AllowDeletingBrowserHistory', 0, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'BrowserGuestModeEnabled', 0, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'BrowserAddPersonEnabled', 0, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'ForceGoogleSafeSearch', 1, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'ForceYouTubeRestrict', 1, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'SafeBrowsingProtectionLevel', 1, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'DownloadRestrictions', 1, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'DefaultNotificationsSetting', 2, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'DnsOverHttpsMode', 'secure', 'String'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome', 'DnsOverHttpsTemplates', $DOH, 'String'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallBlocklist', '1', '*', 'String'),
    @('HKLM:\SOFTWARE\Policies\Google\Chrome\NotificationsBlockedForUrls', '1', '*', 'String'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'InPrivateModeAvailability', 1, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'AllowDeletingBrowserHistory', 0, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'BrowserGuestModeEnabled', 0, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'BrowserAddProfileEnabled', 0, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'ForceGoogleSafeSearch', 1, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'ForceBingSafeSearch', 2, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'ForceYouTubeRestrict', 1, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'SmartScreenEnabled', 1, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'PreventSmartScreenPromptOverride', 1, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'DownloadRestrictions', 1, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'DefaultNotificationsSetting', 2, 'DWord'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'DnsOverHttpsMode', 'secure', 'String'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'DnsOverHttpsTemplates', $DOH, 'String'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallBlocklist', '1', '*', 'String'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge\NotificationsBlockedForUrls', '1', '*', 'String')
)

function Set-Navegadores {
    foreach ($p in $POLITICAS) {
        if (-not (Test-Path $p[0])) { New-Item -Path $p[0] -Force | Out-Null }
        New-ItemProperty -Path $p[0] -Name $p[1] -Value $p[2] -PropertyType $p[3] -Force | Out-Null
    }
}
function Clear-Navegadores {
    # remove só os valores que nós criamos
    foreach ($p in $POLITICAS) {
        if (Test-Path $p[0]) { Remove-ItemProperty -Path $p[0] -Name $p[1] -ErrorAction SilentlyContinue }
    }
}

# ---------------- AppLocker (bloqueio de programas baixados) ----------------
# Tudo liberado para todos, EXCETO para o grupo "Alunos CRJ" nestas pastas do perfil de cada aluno.
# Importante: o "*" do AppLocker atravessa subpastas, então usamos o caminho EXATO do perfil
# (ex.: C:\Users\CRJ MAQUINA 10\Downloads\*) e nunca "Users\*\Downloads".
# AppData fica LIBERADO: é onde ficam programas já instalados pelo usuário (Roblox, jogos...)
# e seus atualizadores (que rodam da pasta Temp). Bloqueamos só onde caem arquivos novos.
$SUBPASTAS_ALUNO = @(
    'Downloads\*', 'Desktop\*', 'Documents\*', 'Music\*', 'Pictures\*', 'Videos\*', 'OneDrive\*',
    # programas abertos de dentro de .zip/.7z/.rar (o Windows extrai para a Temp)
    'AppData\Local\Temp\Temp*', 'AppData\Local\Temp\7z*', 'AppData\Local\Temp\Rar$*'
)
function Get-PastasBloqueadas {
    $lista = @('%REMOVABLE%\*', '%HOT%\*')
    foreach ($m in Get-LocalGroupMember -Group $GRUPO -ErrorAction SilentlyContinue) {
        $perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$($m.SID.Value)'" -ErrorAction SilentlyContinue).LocalPath
        if (-not $perfil) { $perfil = "C:\Users\$($m.Name.Split('\')[-1])" }
        foreach ($s in $SUBPASTAS_ALUNO) { $lista += "$perfil\$s" }
    }
    return $lista
}
function Get-GrupoAlunos {
    $g = Get-LocalGroup -Name $GRUPO -ErrorAction SilentlyContinue
    if (-not $g) { $g = New-LocalGroup -Name $GRUPO -Description 'Contas de alunos da informatica (restritas)' }
    return $g
}
function Get-PoliticaAppLocker([string]$modoAplicacao, [string]$sidAlunos) {
    $pastas = Get-PastasBloqueadas
    $colecoes = foreach ($tipo in 'Exe', 'Msi', 'Script') {
        $regras = @("<FilePathRule Id=`"$([guid]::NewGuid())`" Name=`"CRJ - liberado para todos`" Description=`"`" UserOrGroupSid=`"S-1-1-0`" Action=`"Allow`"><Conditions><FilePathCondition Path=`"*`" /></Conditions></FilePathRule>")
        foreach ($caminho in $pastas) {
            $c = [Security.SecurityElement]::Escape($caminho)
            $regras += "<FilePathRule Id=`"$([guid]::NewGuid())`" Name=`"CRJ - alunos bloqueados: $c`" Description=`"`" UserOrGroupSid=`"$sidAlunos`" Action=`"Deny`"><Conditions><FilePathCondition Path=`"$c`" /></Conditions></FilePathRule>"
        }
        "<RuleCollection Type=`"$tipo`" EnforcementMode=`"$modoAplicacao`">$($regras -join '')</RuleCollection>"
    }
    # Apps do próprio Windows / Microsoft Store (empacotados): sempre liberados para todos.
    $colecoes += "<RuleCollection Type=`"Appx`" EnforcementMode=`"$modoAplicacao`"><FilePublisherRule Id=`"$([guid]::NewGuid())`" Name=`"CRJ - apps do Windows liberados`" Description=`"`" UserOrGroupSid=`"S-1-1-0`" Action=`"Allow`"><Conditions><FilePublisherCondition PublisherName=`"*`" ProductName=`"*`" BinaryName=`"*`"><BinaryVersionRange LowSection=`"0.0.0.0`" HighSection=`"*`" /></FilePublisherCondition></Conditions></FilePublisherRule></RuleCollection>"
    return "<AppLockerPolicy Version=`"1`">$($colecoes -join '')</AppLockerPolicy>"
}
function Set-AppLocker([string]$modoAplicacao) {
    $sid = (Get-GrupoAlunos).SID.Value
    $xml = Join-Path $env:TEMP 'crj-applocker.xml'
    Set-Content -Path $xml -Value (Get-PoliticaAppLocker $modoAplicacao $sid) -Encoding UTF8
    Set-AppLockerPolicy -XmlPolicy $xml
    Remove-Item $xml -Force -ErrorAction SilentlyContinue
    # serviço que aplica o AppLocker: automático e ligado
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc' -Name Start -Value 2
    Start-Service AppIDSvc -ErrorAction SilentlyContinue
}

# ---------------- Aviso de bloqueio (mensagem com o nome do educador) ----------------
function Install-Aviso {
    $consulta = @"
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-AppLocker/EXE and DLL"><Select Path="Microsoft-Windows-AppLocker/EXE and DLL">*[System[(EventID=8004)]]</Select></Query>
  <Query Id="1" Path="Microsoft-Windows-AppLocker/MSI and Script"><Select Path="Microsoft-Windows-AppLocker/MSI and Script">*[System[(EventID=8007)]]</Select></Query>
</QueryList>
"@
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Mostra aviso quando um programa e bloqueado para o aluno.</Description></RegistrationInfo>
  <Triggers><EventTrigger><Enabled>true</Enabled><Subscription>$([Security.SecurityElement]::Escape($consulta))</Subscription></EventTrigger></Triggers>
  <Principals><Principal id="Author"><GroupId>S-1-5-32-545</GroupId><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Hidden>true</Hidden>
  </Settings>
  <Actions Context="Author"><Exec><Command>wscript.exe</Command><Arguments>"$PASTA\aviso.vbs"</Arguments></Exec></Actions>
</Task>
"@
    Register-ScheduledTask -TaskName $TAREFA_AVISO -Xml $xml -Force | Out-Null
}

# ---------------- Atalhos (menu Iniciar > CRJ Informatica) ----------------
function Install-Atalhos {
    $dir = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\CRJ Informatica'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $sh = New-Object -ComObject WScript.Shell
    $itens = @(
        @{ Nome = 'Modo manutencao (pausar restricoes por 3h)'; Args = "-Modo Pausar -Horas 3 -Interativo"; Icone = 'imageres.dll,73' },
        @{ Nome = 'Reativar restricoes';                         Args = "-Modo Aplicar -Interativo";        Icone = 'imageres.dll,101' },
        @{ Nome = 'Ver estado das restricoes';                   Args = "-Modo Status -Interativo";         Icone = 'imageres.dll,76' }
    )
    foreach ($i in $itens) {
        $lnk = Join-Path $dir "$($i.Nome).lnk"
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        $s.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SCRIPT`" $($i.Args)"
        $s.IconLocation = "$env:WINDIR\System32\$($i.Icone)"
        $s.Save()
        # marcar "Executar como administrador" (pede a senha do CRJ-Admin)
        $b = [IO.File]::ReadAllBytes($lnk); $b[0x15] = $b[0x15] -bor 0x20; [IO.File]::WriteAllBytes($lnk, $b)
    }
}

function Lock-Pasta {
    # só SISTEMA e Administradores alteram; alunos só leem
    # 1) permissões da pasta (sem /T: as flags OI/CI não valem para arquivos)
    icacls $PASTA /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q | Out-Null
    # 2) arquivos e subpastas herdam da pasta
    icacls "$PASTA\*" /reset /T /C /Q | Out-Null
}

function Remove-SrpAntigo {
    # regras antigas (Restrição de Software) que o Windows 11 25H2 ignora - eram nossas
    $base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers\0\Paths'
    foreach ($n in 1..5) {
        $k = "$base\{6a1b2c3d-000$n-4c52-4a46-4c4558414c01}"
        if (Test-Path $k) { Remove-Item $k -Recurse -Force }
    }
}

function Add-Aluno([string]$nome) {
    if (-not $nome) {
        $logado = (Get-CimInstance Win32_ComputerSystem).UserName
        if ($logado) { $nome = $logado.Split('\')[-1] }
    }
    if ($nome -and $nome -ne $ADMIN -and (Get-LocalUser -Name $nome -ErrorAction SilentlyContinue)) {
        Get-GrupoAlunos | Out-Null
        if (-not (Get-LocalGroupMember -Group $GRUPO -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*\$nome" })) {
            Add-LocalGroupMember -Group $GRUPO -Member $nome
            Write-Host "Conta '$nome' adicionada ao grupo $GRUPO (vale no próximo login)."
        }
    }
}

# ---------------- Modos ----------------
function Invoke-Aplicar {
    Get-GrupoAlunos | Out-Null
    Set-Navegadores
    Set-AppLocker 'Enabled'
    Unregister-ScheduledTask -TaskName $TAREFA_VOLTA -Confirm:$false -ErrorAction SilentlyContinue
    Set-Content $ESTADO "ATIVO desde $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
}

function Invoke-Pausar {
    $volta = (Get-Date).AddHours($Horas)
    Clear-Navegadores
    Set-AppLocker 'AuditOnly'
    $acao = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SCRIPT`" -Modo Aplicar"
    $gat  = New-ScheduledTaskTrigger -Once -At $volta
    $cfg  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TAREFA_VOLTA -Action $acao -Trigger $gat -Settings $cfg -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Set-Content $ESTADO "PAUSADO (manutencao) ate $($volta.ToString('dd/MM/yyyy HH:mm'))"
    return $volta
}

function Get-Status {
    $estado = if (Test-Path $ESTADO) { Get-Content $ESTADO -Raw } else { 'desconhecido' }
    $ef = [xml](Get-AppLockerPolicy -Effective -Xml)
    $modos = ($ef.AppLockerPolicy.RuleCollection | ForEach-Object { "$($_.Type)=$($_.EnforcementMode)" }) -join ', '
    $chrome = if ((Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallBlocklist' -ErrorAction SilentlyContinue).'1' -eq '*') { 'ligadas' } else { 'desligadas' }
    $alunos = (Get-LocalGroupMember -Group $GRUPO -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', '
    return "PC: $env:COMPUTERNAME`nEstado: $($estado.Trim())`nBloqueio de programas (AppLocker): $modos`nRegras do Chrome/Edge: $chrome`nGrupo $($GRUPO): $alunos"
}

# ---------------- Execução ----------------
$ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ehAdmin) { Msg 'É preciso executar como administrador (CRJ-Admin).' 'Warning'; return }

switch ($Modo) {
    'Instalar' {
        New-Item -ItemType Directory -Force $PASTA | Out-Null
        Lock-Pasta
        Remove-SrpAntigo
        Add-Aluno $Aluno
        Install-Aviso
        Install-Atalhos
        Invoke-Aplicar
        Write-Host (Get-Status)
    }
    'Aplicar' {
        if ($Aluno) { Add-Aluno $Aluno }
        Invoke-Aplicar
        Msg "Restrições REATIVADAS neste computador.`n`n$(Get-Status)"
    }
    'Pausar' {
        $volta = Invoke-Pausar
        Msg "MODO MANUTENÇÃO ligado.`n`nAs restrições estão pausadas e voltam sozinhas às $($volta.ToString('HH:mm')) de $($volta.ToString('dd/MM')).`nPara reativar antes: menu Iniciar > CRJ Informatica > Reativar restricoes.`n`nObs.: o Chrome/Edge precisam ser fechados e abertos de novo." 'Warning'
    }
    'Status' { Msg (Get-Status) }
}
