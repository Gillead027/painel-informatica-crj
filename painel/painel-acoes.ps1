# Motor do Painel da Informatica (roda no ESTUDIO, chamado pelo painel.py).
# Saida: JSON (uma lista de resultados por PC).
param(
    [Parameter(Mandatory)][ValidateSet('Status', 'Pausar', 'Aplicar', 'Hibernar', 'Reiniciar', 'Desligar', 'Mensagem', 'Horario', 'RemoverHorario', 'Historico', 'Energia', 'Otimizar', 'Programas', 'Desinstalar', 'Comando', 'TelaBloqueio', 'BloquearTela', 'Defeito', 'DefeitoFim', 'Semanal', 'NavegadorLivre')][string]$Acao,
    [Parameter(Mandatory)][string]$IPs,          # separados por virgula
    [int]$Horas = 3,
    [string]$Texto = '',
    [string]$Abre = '14:00',
    [string]$Fecha = '17:30',
    [string]$Dias = 'Monday,Tuesday,Wednesday,Thursday,Friday',
    [string]$Destino = '',                      # pasta local para o historico
    [int]$Limite = 0,                           # segundos (0 = padrao)
    [string]$Arquivo = ''                       # JSON com parametros (acoes de manutencao)
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$base = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$senha = (Import-Clixml (Join-Path $base 'chaves\crj-admin.cred')).Password
$cred = New-Object PSCredential('CRJ-Admin', $senha)
$opt = New-PSSessionOption -OpenTimeout 5000 -OperationTimeout 60000 -CancelTimeout 3000
$lista = $IPs.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }

function Saida($objs) { ConvertTo-Json -InputObject @($objs) -Depth 5 -Compress }

$blocos = @{
    Status = {
        $os = Get-CimInstance Win32_OperatingSystem
        $estado = if (Test-Path C:\ProgramData\CRJ\estado.txt) { (Get-Content C:\ProgramData\CRJ\estado.txt -Raw).Trim() } else { '' }
        $modo = try { (([xml](Get-AppLockerPolicy -Effective -Xml)).AppLockerPolicy.RuleCollection | Where-Object Type -eq 'Exe').EnforcementMode } catch { '' }
        $fecha = Get-ScheduledTask -TaskName 'CRJ - Fechamento' -ErrorAction SilentlyContinue
        # nome de exibicao (o que aparece na tela de login), se existir
        $login = [string](Get-CimInstance Win32_ComputerSystem).UserName
        if ($login) { $u = Get-LocalUser -Name $login.Split('\')[-1] -ErrorAction SilentlyContinue; if ($u.FullName) { $login = $u.FullName } }
        [pscustomobject]@{
            ok = $true; nome = $env:COMPUTERNAME
            logado = $login
            estado = $estado; bloqueio = [string]$modo
            boot = $os.LastBootUpTime.ToString('dd/MM HH:mm')
            horario = [bool]$fecha
            defeito = Test-Path C:\ProgramData\CRJ\defeito.txt
            navegador = [string](Get-Content 'C:\ProgramData\CRJ\navegador.txt' -ErrorAction SilentlyContinue)
            manut = [string](Get-Content C:\ProgramData\CRJ\manutencao-ultima.txt -ErrorAction SilentlyContinue)
            semanal = [bool](Get-ScheduledTask -TaskName 'CRJ - Manutencao semanal' -ErrorAction SilentlyContinue)
            verificar = [bool](Get-ScheduledTask -TaskName 'CRJ - Verificar pos manutencao' -ErrorAction SilentlyContinue)
            avisos = (Test-Path 'C:\ProgramData\CRJ\avisos.json')
            telas_n = @(Get-ChildItem 'C:\ProgramData\CRJ\telas' -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(jpe?g|png|bmp)$' }).Count
            telas_cfg = [string](Get-Content 'C:\ProgramData\CRJ\telas\config.json' -Raw -ErrorAction SilentlyContinue)
        }
    }
    Pausar   = { param($h) & powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\CRJ\restricoes.ps1 -Modo Pausar -Horas $h | Out-Null; [pscustomobject]@{ ok = $true; msg = "pausado por $h h" } }
    Aplicar  = { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\CRJ\restricoes.ps1 -Modo Aplicar | Out-Null
        Unregister-ScheduledTask -TaskName 'CRJ - Reativar navegador' -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path 'C:\ProgramData\CRJ\navegador.txt') { [IO.File]::Delete('C:\ProgramData\CRJ\navegador.txt') }
        [pscustomobject]@{ ok = $true; msg = 'restricoes reativadas' } }
    NavegadorLivre = {
        # tira SO as regras do Chrome/Edge (anonimo/InPrivate, convidado, historico, extensoes, busca segura, downloads);
        # o bloqueio de instalacao de programas (AppLocker) continua ligado. $h = horas (0 = ate reativar pelo painel)
        param($h)
        $p = 'C:\ProgramData\CRJ'
        $chrome = 'ExtensionDeveloperModeSettings', 'IncognitoModeAvailability', 'AllowDeletingBrowserHistory', 'BrowserGuestModeEnabled', 'BrowserAddPersonEnabled', 'ForceGoogleSafeSearch', 'ForceYouTubeRestrict', 'SafeBrowsingProtectionLevel', 'DownloadRestrictions', 'DefaultNotificationsSetting', 'DnsOverHttpsMode', 'DnsOverHttpsTemplates'
        $edge = 'InPrivateModeAvailability', 'AllowDeletingBrowserHistory', 'BrowserGuestModeEnabled', 'BrowserAddProfileEnabled', 'ForceGoogleSafeSearch', 'ForceBingSafeSearch', 'ForceYouTubeRestrict', 'SmartScreenEnabled', 'PreventSmartScreenPromptOverride', 'DownloadRestrictions', 'DefaultNotificationsSetting', 'DnsOverHttpsMode', 'DnsOverHttpsTemplates'
        foreach ($n in $chrome) { Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Google\Chrome' -Name $n -ErrorAction SilentlyContinue }
        foreach ($n in $edge) { Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name $n -ErrorAction SilentlyContinue }
        foreach ($k in 'Google\Chrome', 'Microsoft\Edge') { foreach ($sub in 'ExtensionInstallBlocklist', 'NotificationsBlockedForUrls') { Remove-ItemProperty "HKLM:\SOFTWARE\Policies\$k\$sub" -Name '1' -ErrorAction SilentlyContinue } }
        Unregister-ScheduledTask -TaskName 'CRJ - Reativar navegador' -Confirm:$false -ErrorAction SilentlyContinue
        if ([int]$h -gt 0) {
            $volta = (Get-Date).AddHours([int]$h)
            $cmd = "& '$p\restricoes.ps1' -Modo Aplicar; if (Test-Path '$p\navegador.txt') { [IO.File]::Delete('$p\navegador.txt') }"
            $a = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$cmd`""
            Register-ScheduledTask -TaskName 'CRJ - Reativar navegador' -Action $a -Trigger (New-ScheduledTaskTrigger -Once -At $volta) -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries) -User SYSTEM -RunLevel Highest -Force | Out-Null
            Set-Content "$p\navegador.txt" ("LIVRE ate " + $volta.ToString('dd/MM HH:mm')) -Encoding UTF8
            $quando = "ate as " + $volta.ToString('HH:mm')
        } else { Set-Content "$p\navegador.txt" 'LIVRE ate reativar' -Encoding UTF8; $quando = 'ate reativar pelo painel' }
        [pscustomobject]@{ ok = $true; msg = "navegador liberado $quando (programas continuam bloqueados; feche e abra o Chrome)" }
    }
    Hibernar = {
        # tarefa como SISTEMA, com 5 s de folga para a resposta voltar ao estudio
        $a = New-ScheduledTaskAction -Execute cmd.exe -Argument '/c timeout /t 5 /nobreak >nul & shutdown.exe /h'
        Register-ScheduledTask -TaskName 'CRJ - Hibernar agora' -Action $a -User SYSTEM -RunLevel Highest -Force | Out-Null
        Start-ScheduledTask -TaskName 'CRJ - Hibernar agora'
        [pscustomobject]@{ ok = $true; msg = 'hibernando em 5 s' }
    }
    Reiniciar = { shutdown.exe /r /t 60 /c 'Este computador vai reiniciar em 1 minuto (CRJ Informatica). Salve o que estiver fazendo.'; [pscustomobject]@{ ok = $true; msg = 'reinicia em 1 min' } }
    Desligar  = { shutdown.exe /s /t 60 /c 'Este computador vai desligar em 1 minuto (CRJ Informatica). Salve o que estiver fazendo.'; [pscustomobject]@{ ok = $true; msg = 'desliga em 1 min' } }
    Mensagem  = { param($t) msg.exe * /TIME:600 $t; [pscustomobject]@{ ok = $true; msg = 'mensagem enviada' } }
    Horario   = {
        # agenda por dia: [{dia:'Monday', abre:'14:00', fecha:'17:30'}, ...]
        param($agendaJson)
        $agenda = @(($agendaJson | ConvertFrom-Json) | ForEach-Object { $_ })   # PS5: desembrulha a lista
        powercfg /hibernate on | Out-Null
        # nunca dormir sozinho por inatividade (senao some do painel/Veyon); quem desliga e o horario
        powercfg /change standby-timeout-ac 0 | Out-Null; powercfg /change hibernate-timeout-ac 0 | Out-Null
        powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 | Out-Null
        powercfg /setactive SCHEME_CURRENT | Out-Null
        $hora = { param($h, $delta) ([datetime]::ParseExact($h, 'HH:mm', $null)).AddMinutes($delta) }
        $tAviso = @(); $tFecha = @(); $tAbre = @()
        foreach ($d in $agenda) {
            $tAviso += New-ScheduledTaskTrigger -Weekly -DaysOfWeek $d.dia -At (& $hora $d.fecha -5)
            $tFecha += New-ScheduledTaskTrigger -Weekly -DaysOfWeek $d.dia -At (& $hora $d.fecha 0)
            $tAbre  += New-ScheduledTaskTrigger -Weekly -DaysOfWeek $d.dia -At (& $hora $d.abre -5)
        }
        $nomes = 'CRJ - Aviso de fechamento', 'CRJ - Fechamento', 'CRJ - Abertura'
        if (-not $agenda) { $nomes | ForEach-Object { Unregister-ScheduledTask -TaskName $_ -Confirm:$false -ErrorAction SilentlyContinue }; return [pscustomobject]@{ ok = $true; msg = 'nenhum dia ativo' } }
        $cfg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable:$false
        # 1) aviso 5 min antes
        $a1 = New-ScheduledTaskAction -Execute msg.exe -Argument '* /TIME:300 "A informatica fecha em 5 minutos. Salve seus trabalhos: o computador vai desligar (hibernar)."'
        Register-ScheduledTask -TaskName $nomes[0] -Action $a1 -Trigger $tAviso -Settings $cfg -User SYSTEM -RunLevel Highest -Force | Out-Null
        # 2) fechamento: hiberna (a nao ser que esteja em modo manutencao)
        $cmd = "if ((Get-Content C:\ProgramData\CRJ\estado.txt -ErrorAction SilentlyContinue) -notlike 'PAUSADO*') { shutdown.exe /h }"
        $a2 = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -WindowStyle Hidden -Command `"$cmd`""
        Register-ScheduledTask -TaskName $nomes[1] -Action $a2 -Trigger $tFecha -Settings $cfg -User SYSTEM -RunLevel Highest -Force | Out-Null
        # 3) abertura: o PC acorda sozinho 5 min antes (despertador interno)
        $cfg3 = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $a3 = New-ScheduledTaskAction -Execute cmd.exe -Argument '/c exit'
        Register-ScheduledTask -TaskName $nomes[2] -Action $a3 -Trigger $tAbre -Settings $cfg3 -User SYSTEM -RunLevel Highest -Force | Out-Null
        [pscustomobject]@{ ok = $true; msg = ($agenda | ForEach-Object { "$($_.dia.Substring(0,3)) $($_.abre)-$($_.fecha)" }) -join ', ' }
    }
    RemoverHorario = {
        'CRJ - Aviso de fechamento', 'CRJ - Fechamento', 'CRJ - Abertura' | ForEach-Object { Unregister-ScheduledTask -TaskName $_ -Confirm:$false -ErrorAction SilentlyContinue }
        [pscustomobject]@{ ok = $true; msg = 'horario removido' }
    }
    HistoricoPreparar = {
        # copia os arquivos de historico (Chrome/Edge) para uma pasta temporaria do admin
        $tmp = 'C:\ProgramData\CRJ\hist'
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $tmp | Out-Null
        $saida = @()
        foreach ($u in Get-ChildItem C:\Users -Directory | Where-Object { $_.Name -notin 'Public', 'Default', 'Default User', 'All Users', 'CRJ-Admin' }) {
            foreach ($nav in @(@{ n = 'Chrome'; p = 'AppData\Local\Google\Chrome\User Data' }, @{ n = 'Edge'; p = 'AppData\Local\Microsoft\Edge\User Data' })) {
                $ud = Join-Path $u.FullName $nav.p
                if (-not (Test-Path $ud)) { continue }
                foreach ($h in Get-ChildItem $ud -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'History') }) {
                    $nome = ('{0}__{1}__{2}.db' -f ($u.Name -replace '[^\w-]', '_'), $nav.n, ($h.Name -replace '[^\w-]', '_'))
                    $dst = Join-Path $tmp $nome
                    Copy-Item (Join-Path $h.FullName 'History') $dst -ErrorAction SilentlyContinue
                    if (-not (Test-Path $dst)) { esentutl.exe /y (Join-Path $h.FullName 'History') /vss /d $dst /o | Out-Null }
                    if (Test-Path $dst) { $saida += $nome }
                }
            }
        }
        $saida
    }
    # ---------------- manutencao em massa ----------------
    Energia = {
        param($tela, $semBloqueio)
        $msgs = @()
        powercfg /change standby-timeout-ac 0 | Out-Null       # nunca dormir por inatividade
        powercfg /change hibernate-timeout-ac 0 | Out-Null     # nunca hibernar por inatividade
        powercfg /change monitor-timeout-ac ([int]$tela) | Out-Null
        powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 | Out-Null   # mantem o despertador da abertura
        $msgs += 'nao dorme/hiberna sozinha'
        $msgs += $(if ([int]$tela -eq 0) { 'tela nunca apaga' } else { "tela apaga apos $tela min" })
        if ($semBloqueio) {
            powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 | Out-Null   # nao pede login ao voltar
            # protetor de tela desligado para as contas de aluno carregadas
            Get-ChildItem Registry::HKEY_USERS | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object {
                $k = "Registry::HKEY_USERS\$($_.PSChildName)\Control Panel\Desktop"
                if (Test-Path $k) { Set-ItemProperty $k -Name ScreenSaveActive -Value '0'; Set-ItemProperty $k -Name ScreenSaverIsSecure -Value '0' }
            }
            $msgs += 'sem tela de bloqueio/protetor'
        }
        powercfg /setactive SCHEME_CURRENT | Out-Null
        [pscustomobject]@{ ok = $true; msg = ($msgs -join ', ') }
    }
    Otimizar = {
        param($itens)
        $msgs = @()
        $usuarios = Get-ChildItem Registry::HKEY_USERS | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object PSChildName
        if ($itens -contains 'temp') {
            $pastas = @("$env:WINDIR\Temp") + (Get-ChildItem C:\Users -Directory -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)\AppData\Local\Temp" })
            $antes = 0; $depois = 0; $limite = (Get-Date).AddDays(-1)
            foreach ($p in $pastas | Where-Object { Test-Path $_ }) {
                $arqs = Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue
                $antes += ($arqs | Measure-Object Length -Sum).Sum
                $arqs | Where-Object { $_.LastWriteTime -lt $limite } | Remove-Item -Force -ErrorAction SilentlyContinue
                Get-ChildItem $p -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limite } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                $depois += (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            }
            $msgs += "temporarios: {0:N0} MB liberados" -f (($antes - $depois) / 1MB)
        }
        if ($itens -contains 'plano') {
            # Alto desempenho, mantendo as regras do painel (nao dormir, despertador da abertura, tela)
            $tela = [Convert]::ToInt32(((powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Select-Object -Last 3)[0] -split ':')[-1].Trim(), 16) / 60
            $alto = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
            if (-not (powercfg /list | Select-String $alto)) { powercfg -duplicatescheme $alto $alto | Out-Null }
            powercfg /setactive $alto | Out-Null
            powercfg /change standby-timeout-ac 0 | Out-Null; powercfg /change hibernate-timeout-ac 0 | Out-Null
            powercfg /change monitor-timeout-ac ([int]$tela) | Out-Null
            powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 | Out-Null
            powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE CONSOLELOCK 0 | Out-Null
            powercfg /setactive SCHEME_CURRENT | Out-Null
            $msgs += 'plano Alto desempenho'
        }
        if ($itens -contains 'dicas') {
            foreach ($sid in $usuarios) {
                $k = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
                if (-not (Test-Path $k)) { continue }
                foreach ($n in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-310093Enabled', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled') {
                    New-ItemProperty $k -Name $n -Value 0 -PropertyType DWord -Force | Out-Null
                }
                $adv = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
                if (Test-Path $adv) { New-ItemProperty $adv -Name ShowSyncProviderNotifications -Value 0 -PropertyType DWord -Force | Out-Null }
            }
            $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
            if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
            New-ItemProperty $k -Name DisableWindowsConsumerFeatures -Value 1 -PropertyType DWord -Force | Out-Null
            New-ItemProperty $k -Name DisableSoftLanding -Value 1 -PropertyType DWord -Force | Out-Null
            $msgs += 'sugestoes e anuncios desligados'
        }
        if ($itens -contains 'efeitos') {
            foreach ($sid in $usuarios) {
                $k = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
                if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
                New-ItemProperty $k -Name VisualFXSetting -Value 2 -PropertyType DWord -Force | Out-Null
                $p = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
                if (Test-Path $p) { New-ItemProperty $p -Name EnableTransparency -Value 0 -PropertyType DWord -Force | Out-Null }
            }
            $msgs += 'efeitos visuais leves (vale no proximo login)'
        }
        [pscustomobject]@{ ok = $true; msg = ($msgs -join ' | ') }
    }
    Programas = {
        $chaves = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
        $chaves += Get-ChildItem Registry::HKEY_USERS | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object { "Registry::HKEY_USERS\$($_.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall" }
        $lista = foreach ($c in $chaves | Where-Object { Test-Path $_ }) {
            foreach ($k in Get-ChildItem $c -ErrorAction SilentlyContinue) {
                $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                if (-not $p.DisplayName -or $p.SystemComponent -eq 1 -or $p.ParentKeyName -or $p.DisplayName -match '^(Security )?Update for|\(KB\d+\)') { continue }
                [pscustomobject]@{ nome = [string]$p.DisplayName; versao = [string]$p.DisplayVersion; editor = [string]$p.Publisher
                    escopo = $(if ($c -like 'Registry::HKEY_USERS*') { 'usuario' } else { 'maquina' })
                    silencioso = [bool]($p.QuietUninstallString -or $p.WindowsInstaller -eq 1 -or "$($p.UninstallString)" -match 'msiexec') }
            }
        }
        [pscustomobject]@{ ok = $true; programas = @($lista | Sort-Object nome -Unique) }
    }
    Desinstalar = {
        param($nome)
        $chaves = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
        $chaves += Get-ChildItem Registry::HKEY_USERS | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object { "Registry::HKEY_USERS\$($_.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall" }
        $achados = foreach ($c in $chaves | Where-Object { Test-Path $_ }) { Get-ChildItem $c -ErrorAction SilentlyContinue | Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName -eq $nome } }
        if (-not $achados) { return [pscustomobject]@{ ok = $true; msg = 'nao estava instalado' } }
        $msgs = @()
        foreach ($k in $achados) {
            $p = Get-ItemProperty $k.PSPath
            $cmd = $null; $arg = $null
            if ($p.WindowsInstaller -eq 1 -or "$($p.UninstallString)" -match 'msiexec') {
                $guid = if ($k.PSChildName -match '^\{.+\}$') { $k.PSChildName } else { ([regex]::Match("$($p.UninstallString)", '\{[0-9A-Fa-f-]+\}')).Value }
                $cmd = 'msiexec.exe'; $arg = "/x $guid /qn /norestart"
            } elseif ($p.QuietUninstallString) {
                $cmd = 'cmd.exe'; $arg = "/c `"$($p.QuietUninstallString)`""
            } elseif ($p.UninstallString) {
                # sem modo silencioso declarado: tenta as opcoes silenciosas mais comuns (NSIS / Inno Setup)
                $u = "$($p.UninstallString)"
                $flags = if ($u -match 'unins\d+\.exe') { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' } else { '/S' }
                $cmd = 'cmd.exe'; $arg = "/c `"$u $flags`""
            }
            if (-not $cmd) { $msgs += 'sem desinstalador registrado'; continue }
            $proc = Start-Process $cmd -ArgumentList $arg -PassThru -WindowStyle Hidden
            if (-not $proc.WaitForExit(300000)) { try { $proc.Kill() } catch {}; $msgs += 'desinstalador nao terminou em 5 min (pode pedir confirmacao na tela)'; continue }
            $msgs += "codigo $($proc.ExitCode)"
        }
        Start-Sleep 3
        $resta = foreach ($c in $chaves | Where-Object { Test-Path $_ }) { Get-ChildItem $c -ErrorAction SilentlyContinue | Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName -eq $nome } }
        if ($resta) { [pscustomobject]@{ ok = $false; msg = "continua instalado ($($msgs -join ', ')): desinstale manualmente nesta maquina" } }
        else { [pscustomobject]@{ ok = $true; msg = 'desinstalado' } }
    }
    BloquearTela = {
        # bloqueia a sessao do aluno (precisa rodar na sessao dele) para mostrar a tela de bloqueio
        $aluno = (Get-CimInstance Win32_ComputerSystem).UserName
        if (-not $aluno) { return [pscustomobject]@{ ok = $true; msg = 'ninguem logado (ja esta na tela de bloqueio)' } }
        $a = New-ScheduledTaskAction -Execute rundll32.exe -Argument 'user32.dll,LockWorkStation'
        $p = New-ScheduledTaskPrincipal -UserId $aluno -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName 'CRJ - Bloquear tela' -Action $a -Principal $p -Force | Out-Null
        Start-ScheduledTask -TaskName 'CRJ - Bloquear tela'; Start-Sleep 2
        Unregister-ScheduledTask -TaskName 'CRJ - Bloquear tela' -Confirm:$false
        [pscustomobject]@{ ok = $true; msg = 'tela bloqueada (aperte Enter para voltar)' }
    }
    Defeito = {
        # bloqueia TUDO para alunos: aviso antes do login, imagem na tela de bloqueio, conta do aluno desativada
        param($imgB64)
        $pasta = 'C:\ProgramData\CRJ'
        $titulo = 'MÁQUINA COM DEFEITO'
        $texto = 'Estamos trabalhando nela. Acesse outra máquina ou procure o educador Gillead.'
        $alunos = @(Get-LocalGroupMember -Group 'Alunos CRJ' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Split('\')[-1] })
        # guarda o estado anterior (para liberar depois)
        $sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $csp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
        if (-not (Test-Path "$pasta\defeito.json")) {
            $antes = [pscustomobject]@{
                caption = (Get-ItemProperty $sys -ErrorAction SilentlyContinue).legalnoticecaption
                text    = (Get-ItemProperty $sys -ErrorAction SilentlyContinue).legalnoticetext
                tela    = (Get-ItemProperty $csp -ErrorAction SilentlyContinue).LockScreenImagePath
                alunos  = $alunos
            }
            $antes | ConvertTo-Json | Set-Content "$pasta\defeito.json" -Encoding UTF8
        }
        # 1) imagem de defeito na tela de bloqueio
        [IO.File]::WriteAllBytes("$pasta\defeito.jpg", [Convert]::FromBase64String($imgB64))
        if (-not (Test-Path $csp)) { New-Item $csp -Force | Out-Null }
        New-ItemProperty $csp -Name LockScreenImagePath -Value "$pasta\defeito.jpg" -PropertyType String -Force | Out-Null
        New-ItemProperty $csp -Name LockScreenImageUrl -Value "$pasta\defeito.jpg" -PropertyType String -Force | Out-Null
        New-ItemProperty $csp -Name LockScreenImageStatus -Value 1 -PropertyType DWord -Force | Out-Null
        Disable-ScheduledTask -TaskName 'CRJ - Tela de bloqueio' -ErrorAction SilentlyContinue | Out-Null   # nao trocar a imagem enquanto estiver com defeito
        # 2) aviso antes de qualquer login
        New-ItemProperty $sys -Name legalnoticecaption -Value $titulo -PropertyType String -Force | Out-Null
        New-ItemProperty $sys -Name legalnoticetext -Value $texto -PropertyType String -Force | Out-Null
        # 3) avisa quem estiver usando e desconecta em 20 s
        $sessoes = @(quser 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -replace '^>', ' ').Trim() -split '\s{2,}' } )
        if ((Get-CimInstance Win32_ComputerSystem).UserName) {
            msg.exe * /TIME:20 "$titulo`n`n$texto`n`nVocê será desconectado em 20 segundos."
        }
        # 4) conta do aluno desativada (so o CRJ-Admin entra)
        foreach ($a in $alunos) { Disable-LocalUser -Name $a -ErrorAction SilentlyContinue }
        Set-Content "$pasta\defeito.txt" "DEFEITO desde $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
        $sair = "Start-Sleep 20; quser 2>`$null | Select-Object -Skip 1 | ForEach-Object { `$id = (`$_ -replace '^>', ' ').Trim() -split '\s+' | Where-Object { `$_ -match '^\d+$' } | Select-Object -First 1; if (`$id) { logoff `$id } }"
        $acao = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -WindowStyle Hidden -Command `"$sair`""
        Register-ScheduledTask -TaskName 'CRJ - Desconectar (defeito)' -Action $acao -User SYSTEM -RunLevel Highest -Force | Out-Null
        Start-ScheduledTask -TaskName 'CRJ - Desconectar (defeito)'
        [pscustomobject]@{ ok = $true; msg = "modo defeito ligado; conta(s) desativada(s): $($alunos -join ', ')" }
    }
    DefeitoFim = {
        $pasta = 'C:\ProgramData\CRJ'
        $sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $csp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
        $antes = if (Test-Path "$pasta\defeito.json") { Get-Content "$pasta\defeito.json" -Raw | ConvertFrom-Json } else { $null }
        $alunos = @(Get-LocalGroupMember -Group 'Alunos CRJ' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Split('\')[-1] }) + @($antes.alunos) | Where-Object { $_ } | Select-Object -Unique
        foreach ($a in $alunos) { Enable-LocalUser -Name $a -ErrorAction SilentlyContinue }
        # aviso antes do login: volta ao que era (normalmente nenhum)
        if ($antes.caption) { Set-ItemProperty $sys -Name legalnoticecaption -Value $antes.caption } else { Set-ItemProperty $sys -Name legalnoticecaption -Value '' }
        if ($antes.text) { Set-ItemProperty $sys -Name legalnoticetext -Value $antes.text } else { Set-ItemProperty $sys -Name legalnoticetext -Value '' }
        # tela de bloqueio: volta para as imagens do CRJ (ou para a anterior)
        Enable-ScheduledTask -TaskName 'CRJ - Tela de bloqueio' -ErrorAction SilentlyContinue | Out-Null
        if (Test-Path "$pasta\telas\trocar.ps1") { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$pasta\telas\trocar.ps1" }
        elseif ($antes.tela) { Set-ItemProperty $csp -Name LockScreenImagePath -Value $antes.tela; Set-ItemProperty $csp -Name LockScreenImageUrl -Value $antes.tela }
        else { Set-ItemProperty $csp -Name LockScreenImageStatus -Value 0 -ErrorAction SilentlyContinue }
        foreach ($f in 'defeito.txt', 'defeito.json') { if (Test-Path "$pasta\$f") { [IO.File]::Delete("$pasta\$f") } }
        Unregister-ScheduledTask -TaskName 'CRJ - Desconectar (defeito)' -Confirm:$false -ErrorAction SilentlyContinue
        [pscustomobject]@{ ok = $true; msg = "maquina liberada; conta(s) reativada(s): $($alunos -join ', ')" }
    }
    Semanal = {
        # instala/atualiza a manutencao automatica semanal (o PC acorda sozinho, faz a manutencao e volta a hibernar)
        param($conteudo, $dia, $hora, $agora)
        $arq = 'C:\ProgramData\CRJ\manutencao-semanal.ps1'
        [IO.File]::WriteAllText($arq, $conteudo, (New-Object Text.UTF8Encoding $true))
        icacls $arq /reset /Q | Out-Null
        powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 | Out-Null; powercfg /setactive SCHEME_CURRENT | Out-Null
        $cfg = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3)
        $a = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$arq`""
        $g = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $dia -At ([datetime]::ParseExact($hora, 'HH:mm', $null))
        Register-ScheduledTask -TaskName 'CRJ - Manutencao semanal' -Action $a -Trigger $g -Settings $cfg -User SYSTEM -RunLevel Highest -Force | Out-Null
        $a2 = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$arq`" -PosReinicio"
        Register-ScheduledTask -TaskName 'CRJ - Pos manutencao' -Action $a2 -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)) -User SYSTEM -RunLevel Highest -Force | Out-Null
        # rede de seguranca 1h30 depois: so roda se a maquina estiver ligada (nao acorda, nao roda atrasado)
        $a3 = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$arq`" -Verificar"
        $g3 = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $dia -At ([datetime]::ParseExact($hora, 'HH:mm', $null).AddMinutes(90))
        Register-ScheduledTask -TaskName 'CRJ - Verificar pos manutencao' -Action $a3 -Trigger $g3 -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)) -User SYSTEM -RunLevel Highest -Force | Out-Null
        if ($agora) { Start-ScheduledTask -TaskName 'CRJ - Manutencao semanal' }
        $prox = (Get-ScheduledTaskInfo -TaskName 'CRJ - Manutencao semanal').NextRunTime
        [pscustomobject]@{ ok = $true; msg = "proxima: $($prox.ToString('dd/MM HH:mm'))$(if ($agora) { ' | rodando agora' })" }
    }
    Comando = {
        param($codigo)
        $saida = try { & ([scriptblock]::Create($codigo)) *>&1 | Out-String -Width 160 } catch { "ERRO: $($_.Exception.Message)" }
        [pscustomobject]@{ ok = -not ($saida -like 'ERRO:*'); saida = "$saida".Trim() }
    }
}

$resultados = @()
switch ($Acao) {
    'Historico' {
        foreach ($ip in $lista) {
            try {
                $s = New-PSSession -ComputerName $ip -Credential $cred -SessionOption $opt -ErrorAction Stop
                $arqs = @(Invoke-Command -Session $s -ScriptBlock $blocos.HistoricoPreparar)
                $pasta = Join-Path $Destino ($ip -replace '\.', '_')
                Remove-Item $pasta -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $pasta | Out-Null
                foreach ($a in $arqs) { Copy-Item "C:\ProgramData\CRJ\hist\$a" -Destination $pasta -FromSession $s -ErrorAction SilentlyContinue }
                Invoke-Command -Session $s { Remove-Item C:\ProgramData\CRJ\hist -Recurse -Force -ErrorAction SilentlyContinue }
                Remove-PSSession $s
                $resultados += [pscustomobject]@{ ip = $ip; ok = $true; arquivos = $arqs.Count }
            } catch { $resultados += [pscustomobject]@{ ip = $ip; ok = $false; erro = $_.Exception.Message.Split("`n")[0] } }
        }
    }
    'TelaBloqueio' {
        # $cfg: { arquivos: [...], intervalo: minutos (0 = fixa, 1440 = 1x por dia), bloqueio: bool, fundo: bool }
        $cfgT = Get-Content $Arquivo -Raw -Encoding UTF8 | ConvertFrom-Json
        $arquivos = @($cfgT.arquivos | Where-Object { Test-Path $_ })
        $nomes = @($arquivos | ForEach-Object { Split-Path $_ -Leaf })
        $conf = [pscustomobject]@{ intervaloSeg = [int]$cfgT.intervaloSeg; bloqueio = [bool]$cfgT.bloqueio; fundo = [bool]$cfgT.fundo } | ConvertTo-Json -Compress
        $fundoLocal = Join-Path $base 'painel\fundo-slides.ps1'
        $jobs = @(foreach ($ip in $lista) {
            Start-Job -ArgumentList $ip, $cred, $arquivos, $nomes, $conf, $fundoLocal -ScriptBlock {
                param($ip, $cred, $arquivos, $nomes, $conf, $fundoLocal)
                try {
                    $s = New-PSSession -ComputerName $ip -Credential $cred -SessionOption (New-PSSessionOption -OpenTimeout 6000 -OperationTimeout 120000) -ErrorAction Stop
                    $la = Invoke-Command -Session $s -ArgumentList (, $nomes) {
                        param($nomes)
                        $p = 'C:\ProgramData\CRJ\telas'; New-Item -ItemType Directory -Force $p | Out-Null
                        Get-ChildItem $p -File | Where-Object { $_.Extension -match '^\.(jpe?g|png|bmp)$' -and $_.Name -notin $nomes } | ForEach-Object { [IO.File]::Delete($_.FullName) }
                        $m = @{}; Get-ChildItem $p -File | ForEach-Object { $m[$_.Name] = $_.Length }; $m   # o que ja esta la (nome -> tamanho)
                    }
                    # so copia o que falta ou mudou (mesmo nome e mesmo tamanho = ja esta la)
                    foreach ($a in $arquivos) { $fi = Get-Item $a; if ($la -and $la[$fi.Name] -eq $fi.Length) { continue }; Copy-Item $a -Destination 'C:\ProgramData\CRJ\telas\' -ToSession $s -Force }
                    Copy-Item $fundoLocal -Destination 'C:\ProgramData\CRJ\telas\fundo.ps1' -ToSession $s -Force
                    Copy-Item (Join-Path (Split-Path $fundoLocal) 'bloqueio-slides.ps1') -Destination 'C:\ProgramData\CRJ\telas\bloqueio.ps1' -ToSession $s -Force
                    $r = Invoke-Command -Session $s -ArgumentList $conf, $nomes.Count {
                        param($conf, $qtd)
                        $p = 'C:\ProgramData\CRJ\telas'; $LOG = 'C:\ProgramData\CRJ\progresso.log'
                        Set-Content "$p\config.json" $conf -Encoding UTF8
                        if (Test-Path "$p\alternar.txt") { [IO.File]::Delete("$p\alternar.txt") }
                        $indice = @'
function Indice($n, $seg) { if ($n -le 1 -or $seg -le 0) { return 0 }; $seg = [math]::Max(60, $seg); [int]([math]::Floor(((([datetime]::Now) - [datetime]'2026-01-01').TotalSeconds / $seg)) % $n) }
$p = 'C:\ProgramData\CRJ\telas'
$c = Get-Content "$p\config.json" -Raw | ConvertFrom-Json
$imgs = @(Get-ChildItem $p -File | Where-Object { $_.Extension -match '^\.(jpe?g|png|bmp)$' } | Sort-Object Name)
'@
                        # SISTEMA: libera a imagem "forcada" (usada so pelo modo defeito) para valer a tela de bloqueio da conta do aluno, que troca sozinha
                        $troca = @'
if (Test-Path 'C:\ProgramData\CRJ\defeito.txt') { exit }   # modo defeito tem prioridade
$k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
if (Test-Path $k) { Set-ItemProperty $k -Name LockScreenImageStatus -Value 0; foreach ($n in 'LockScreenImagePath', 'LockScreenImageUrl') { Remove-ItemProperty $k -Name $n -ErrorAction SilentlyContinue } }
'@
                        # papel de parede (roda na conta do aluno)

                        Set-Content "$p\trocar.ps1" $troca -Encoding UTF8
                        Set-Content "$p\fundo.vbs" 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\CRJ\telas\fundo.ps1", 0, False' -Encoding ASCII
                        Set-Content "$p\bloqueio.vbs" 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\CRJ\telas\bloqueio.ps1", 0, False' -Encoding ASCII
                        icacls $p /reset /T /Q | Out-Null
                        $cfgJ = $conf | ConvertFrom-Json
                        # tira as 'curiosidades' do Windows Spotlight de cima da imagem da tela de bloqueio
                        Get-ChildItem Registry::HKEY_USERS | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } | ForEach-Object { $k = "Registry::HKEY_USERS\$($_.PSChildName)\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; if (Test-Path $k) { foreach ($n in 'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled', 'SubscribedContent-338387Enabled') { New-ItemProperty $k -Name $n -Value 0 -PropertyType DWord -Force | Out-Null } } }
                        $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'; if (-not (Test-Path $pol)) { New-Item $pol -Force | Out-Null }; New-ItemProperty $pol -Name LockScreenOverlaysDisabled -Value 1 -PropertyType DWord -Force | Out-Null
                        # repeticao "presa" a um gatilho diario: recomeca todo dia (nao expira)
                        # tela de bloqueio: troca no minimo a cada 1 minuto (limite do Windows); papel de parede usa o slide nativo (segundos + esmaecer)
                        $minBloq = [math]::Max(1, [math]::Ceiling([int]$cfgJ.intervaloSeg / 60))
                        $rep = if ($cfgJ.intervaloSeg -gt 0 -and $minBloq -lt 1440) { (New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes $minBloq) -RepetitionDuration (New-TimeSpan -Hours 23 -Minutes 59)).Repetition } else { $null }
                        $d1 = New-ScheduledTaskTrigger -Daily -At '00:00'
                        $g1 = @($d1, (New-ScheduledTaskTrigger -AtStartup))
                        Register-ScheduledTask -TaskName 'CRJ - Tela de bloqueio' -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $p\trocar.ps1") -Trigger $g1 -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew) -User SYSTEM -RunLevel Highest -Force | Out-Null
                        $d2 = New-ScheduledTaskTrigger -Daily -At '00:01'
                        $g2 = @((New-ScheduledTaskTrigger -AtLogOn), $d2)
                        $pr = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
                        Register-ScheduledTask -TaskName 'CRJ - Papel de parede' -Action (New-ScheduledTaskAction -Execute wscript.exe -Argument "`"$p\fundo.vbs`"") -Trigger $g2 -Principal $pr -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew) -Force | Out-Null
                        # slides da tela de bloqueio: rotina continua na sessao do aluno (reinicia para pegar a configuracao nova)
                        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*telas\bloqueio.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                        $g3 = @((New-ScheduledTaskTrigger -AtLogOn), (New-ScheduledTaskTrigger -Daily -At '00:02'))
                        Register-ScheduledTask -TaskName 'CRJ - Tela de bloqueio (aluno)' -Action (New-ScheduledTaskAction -Execute wscript.exe -Argument "`"$p\bloqueio.vbs`"") -Trigger $g3 -Principal $pr -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)) -Force | Out-Null
                        if ($cfgJ.bloqueio -and (Get-CimInstance Win32_ComputerSystem).UserName) { Start-ScheduledTask -TaskName 'CRJ - Tela de bloqueio (aluno)' }
                        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$p\trocar.ps1"
                        if ($cfgJ.fundo -and (Get-CimInstance Win32_ComputerSystem).UserName) { Start-ScheduledTask -TaskName 'CRJ - Papel de parede' }
                        Add-Content -Path $LOG -Value ("Green|$(Get-Date -Format HH:mm:ss)|Imagens do CRJ atualizadas.") -Encoding UTF8 -ErrorAction SilentlyContinue
                        $onde = @(); if ($cfgJ.bloqueio) { $onde += 'tela de bloqueio' }; if ($cfgJ.fundo) { $onde += 'papel de parede' }
                        $sg = [int]$cfgJ.intervaloSeg; $troc = if ($qtd -gt 1 -and $sg -gt 0) { if ($sg -ge 86400) { ', troca 1x por dia' } elseif ($sg -lt 60) { ", troca a cada $sg s" } else { ", troca a cada $([int]($sg/60)) min" } } else { '' }
                        [pscustomobject]@{ ok = $true; msg = "$qtd imagem(ns) em: $($onde -join ' e ')$troc" }
                    }
                    Remove-PSSession $s
                    [pscustomobject]@{ ip = $ip; ok = $r.ok; msg = $r.msg }
                } catch { [pscustomobject]@{ ip = $ip; ok = $false; erro = $_.Exception.Message.Split("`n")[0] } }
            }
        })
        Wait-Job $jobs -Timeout 800 | Out-Null
        for ($n = 0; $n -lt $jobs.Count; $n++) {
            $x = Receive-Job $jobs[$n] -ErrorAction SilentlyContinue | Select-Object -Last 1
            if ($x) { $resultados += [pscustomobject]@{ ip = $x.ip; ok = $x.ok; msg = $x.msg; erro = $x.erro } }
            else { $resultados += [pscustomobject]@{ ip = $lista[$n]; ok = $false; erro = 'sem resposta em 800 s' } }
        }
        $jobs | Remove-Job -Force
    }
    default {
        $cfg = if ($Arquivo -and (Test-Path $Arquivo)) { Get-Content $Arquivo -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
        $args2 = switch ($Acao) { 'Pausar' { , $Horas } 'NavegadorLivre' { , $Horas } 'Mensagem' { , $Texto } 'Horario' { , [string]($cfg.agenda | ConvertTo-Json -Compress -Depth 3) } 'Energia' { [int]$cfg.tela, [bool]$cfg.semBloqueio } 'Otimizar' { , @($cfg.itens) } 'Desinstalar' { , [string]$cfg.nome } 'Comando' { , [string]$cfg.codigo } 'Semanal' { [IO.File]::ReadAllText((Join-Path $base 'painel\manutencao-semanal.ps1')), [string]$cfg.dia, [string]$cfg.hora, [bool]$cfg.agora } 'Defeito' { , [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $base 'painel\defeito.jpg'))) } default { @() } }
        # roda como "job" com limite de tempo: uma maquina travada (ex.: desligando no meio) nao segura as outras
        $padrao = @{ Status = 25; Semanal = 60; Programas = 120; Desinstalar = 600; Comando = 300; Otimizar = 300 }
        $limite = if ($Limite -gt 0) { $Limite } elseif ($padrao.ContainsKey($Acao)) { $padrao[$Acao] } else { 90 }
        $job = Invoke-Command -ComputerName $lista -Credential $cred -SessionOption $opt -ThrottleLimit 16 -ScriptBlock $blocos[$Acao] -ArgumentList $args2 -AsJob
        Wait-Job $job -Timeout $limite | Out-Null
        $r = @(Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable errs)
        foreach ($filho in $job.ChildJobs | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'NotStarted' }) {
            $resultados += [pscustomobject]@{ ip = $filho.Location; ok = $false; erro = "sem resposta em $limite s" }
        }
        Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue
        foreach ($x in $r) {
            $o = [ordered]@{ ip = $x.PSComputerName }
            foreach ($p in $x.PSObject.Properties | Where-Object { $_.Name -notin 'PSComputerName', 'RunspaceId', 'PSShowComputerName' }) { $o[$p.Name] = $p.Value }
            $resultados += [pscustomobject]$o
        }
        foreach ($e in $errs) {
            $alvo = if ($e.TargetObject) { [string]$e.TargetObject } else { [string]$e.OriginInfo.PSComputerName }
            if ($alvo -and -not ($resultados | Where-Object ip -eq $alvo)) { $resultados += [pscustomobject]@{ ip = $alvo; ok = $false; erro = $e.Exception.Message.Split("`n")[0] } }
        }
    }
}
Saida $resultados
