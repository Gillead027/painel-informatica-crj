# ======================================================================
#  CRJ Flexal - Controle Informatica - preparacao de um PC da sala
#  Rodar no PC do aluno, em PowerShell COMO ADMINISTRADOR:
#     irm http://192.168.10.124:8000/preparar-pc.ps1 | iex
#
#  NAO APAGA NADA. Apenas restringe:
#   - cria a conta CRJ-Admin (senha digitada na hora)
#   - tira a conta do aluno do grupo Administradores
#   - politicas do Chrome/Edge (extensoes, anonima, historico, busca segura...)
#   - bloqueia executar programas baixados (Downloads/Area de Trabalho/Temp)
#   - instala Veyon (ver a tela) e libera WinRM, so para o estudio
# ======================================================================

function Invoke-CrjPreparacao {
    $ErrorActionPreference = 'Continue'
    $ProgressPreference    = 'SilentlyContinue'
    $ESTUDIO   = '192.168.10.124'
    $SERVIDOR  = "http://$($ESTUDIO):8000"
    $ADMIN     = 'CRJ-Admin'
    $SID_ADMS  = 'S-1-5-32-544'
    $SID_USERS = 'S-1-5-32-545'
    $pasta     = 'C:\ProgramData\CRJ'
    $rel       = New-Object System.Collections.Generic.List[string]

    function Log($txt, $cor = 'Gray') { Write-Host $txt -ForegroundColor $cor; $rel.Add($txt) }
    function Etapa($txt) { Log ''; Log "=== $txt" 'Cyan' }
    function SetReg($caminho, $nome, $valor, $tipo = 'DWord') {
        if (-not (Test-Path $caminho)) { New-Item -Path $caminho -Force | Out-Null }
        New-ItemProperty -Path $caminho -Name $nome -Value $valor -PropertyType $tipo -Force | Out-Null
    }
    function SetLista($caminho, $itens) {
        # lista de politica (1,2,3...). So escreve; nao remove valores existentes.
        if (-not (Test-Path $caminho)) { New-Item -Path $caminho -Force | Out-Null }
        $i = 1; foreach ($x in $itens) { New-ItemProperty -Path $caminho -Name "$i" -Value $x -PropertyType String -Force | Out-Null; $i++ }
    }

    # ---------- 0. Conferencias ----------
    $ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $ehAdmin) {
        Write-Host 'ERRO: abra o PowerShell como ADMINISTRADOR (botao direito > Executar como administrador) e rode de novo.' -ForegroundColor Red
        return
    }
    New-Item -ItemType Directory -Force $pasta | Out-Null

    $os      = Get-CimInstance Win32_OperatingSystem
    $cs      = Get-CimInstance Win32_ComputerSystem
    $bios    = Get-CimInstance Win32_BIOS
    $placa   = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
    $ip      = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $placa.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    $logado  = $cs.UserName                       # ex.: MAQUINA10\CRJ MAQUINA 10
    $aluno   = if ($logado) { $logado.Split('\')[-1] } else { $env:USERNAME }

    Etapa '0. Identificacao do PC'
    Log "Data:        $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
    Log "Nome do PC:  $env:COMPUTERNAME"
    Log "Windows:     $($os.Caption) (build $($os.BuildNumber))"
    Log "IP:          $ip"
    Log "MAC:         $($placa.MacAddress)  (placa: $($placa.InterfaceDescription))"
    Log "Num. serie:  $($bios.SerialNumber)"
    Log "Modelo:      $($cs.Manufacturer) $($cs.Model)"
    Log "Conta aluno: $aluno"

    # ---------- 1. Inventario (estado ANTES) ----------
    Etapa '1. Inventario do estado atual (nada sera apagado)'
    $grpAdm = (New-Object Security.Principal.SecurityIdentifier $SID_ADMS).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    Log "Contas locais:"
    Get-LocalUser | ForEach-Object { Log ("   - {0}  (ativa={1}, senha obrigatoria={2})" -f $_.Name, $_.Enabled, $_.PasswordRequired) }
    Log "Membros do grupo $($grpAdm):"
    Get-LocalGroupMember -SID $SID_ADMS | ForEach-Object { Log "   - $($_.Name)" }

    Log 'Extensoes de navegador instaladas:'
    $raizes = @(
        @{ Nav = 'Chrome'; Dir = 'AppData\Local\Google\Chrome\User Data' },
        @{ Nav = 'Edge';   Dir = 'AppData\Local\Microsoft\Edge\User Data' }
    )
    foreach ($u in Get-ChildItem C:\Users -Directory -ErrorAction SilentlyContinue) {
        foreach ($r in $raizes) {
            $ud = Join-Path $u.FullName $r.Dir
            if (-not (Test-Path $ud)) { continue }
            foreach ($perfil in Get-ChildItem $ud -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'Extensions') }) {
                foreach ($ext in Get-ChildItem (Join-Path $perfil.FullName 'Extensions') -Directory -ErrorAction SilentlyContinue) {
                    if ($ext.Name -eq 'Temp') { continue }
                    $nome = '?'
                    $man = Get-ChildItem $ext.FullName -Recurse -Filter manifest.json -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($man) { try { $nome = (Get-Content $man.FullName -Raw | ConvertFrom-Json).name } catch {} }
                    Log ("   - [{0}] {1} / {2} / {3}  nome: {4}" -f $r.Nav, $u.Name, $perfil.Name, $ext.Name, $nome)
                }
            }
        }
    }

    Log 'Politicas de navegador ja existentes (atencao a ExtensionInstallForcelist):'
    foreach ($k in 'HKLM:\SOFTWARE\Policies\Google\Chrome', 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKCU:\SOFTWARE\Policies\Google\Chrome', 'HKCU:\SOFTWARE\Policies\Microsoft\Edge') {
        if (Test-Path $k) {
            Get-ChildItem $k -Recurse -ErrorAction SilentlyContinue | ForEach-Object { Log "   - $($_.Name)" }
            (Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { Log "   - $k : $($_.Name) = $($_.Value)" }
        }
    }
    foreach ($k in 'HKLM:\SOFTWARE\Google\Chrome\Extensions', 'HKLM:\SOFTWARE\WOW6432Node\Google\Chrome\Extensions') {
        if (Test-Path $k) { Get-ChildItem $k | ForEach-Object { Log "   - extensao externa registrada: $($_.PSChildName)" } }
    }

    Log 'Outros navegadores encontrados:'
    $outros = @('C:\Program Files\Mozilla Firefox\firefox.exe', 'C:\Program Files (x86)\Mozilla Firefox\firefox.exe')
    $outros += Get-ChildItem C:\Users -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        "$($_.FullName)\AppData\Local\Programs\Opera\opera.exe", "$($_.FullName)\AppData\Local\Programs\Opera GX\opera.exe",
        "$($_.FullName)\AppData\Local\BraveSoftware\Brave-Browser\Application\brave.exe", "$($_.FullName)\AppData\Local\Mozilla Firefox\firefox.exe"
    }
    $outros += 'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe'
    $achou = $false; foreach ($o in $outros) { if (Test-Path $o) { Log "   - $o"; $achou = $true } }
    if (-not $achou) { Log '   (nenhum)' }

    Log 'Programas instalados:'
    $chaves = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $chaves -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
        Sort-Object DisplayName -Unique | ForEach-Object { Log "   - $($_.DisplayName) $($_.DisplayVersion)" }

    # ---------- 2. Ponto de restauracao (seguro) ----------
    Etapa '2. Ponto de restauracao (seguranca - nao sera usado sem autorizacao)'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        SetReg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
        Checkpoint-Computer -Description 'CRJ - antes do controle da informatica' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Log 'Ponto de restauracao criado.' 'Green'
    } catch { Log "AVISO: nao foi possivel criar ponto de restauracao: $($_.Exception.Message)" 'Yellow' }

    # ---------- 3. Conta CRJ-Admin ----------
    Etapa "3. Conta de administrador '$ADMIN'"
    $existe = Get-LocalUser -Name $ADMIN -ErrorAction SilentlyContinue
    if ($existe) {
        Log "A conta $ADMIN ja existe - mantida como esta (senha nao alterada)." 'Yellow'
    } else {
        while ($true) {
            $s1 = Read-Host -AsSecureString "Digite a senha para $ADMIN (minimo 6 caracteres)"
            $s2 = Read-Host -AsSecureString 'Digite a senha novamente'
            $p1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1))
            $p2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2))
            if ($p1.Length -lt 6) { Write-Host 'Senha muito curta.' -ForegroundColor Yellow; continue }
            if ($p1 -cne $p2)     { Write-Host 'As senhas nao conferem. Tente de novo.' -ForegroundColor Yellow; continue }
            $p1 = $null; $p2 = $null
            break
        }
        try {
            New-LocalUser -Name $ADMIN -Password $s1 -FullName 'Administrador CRJ' -Description 'Admin da informatica (estudio)' -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop | Out-Null
            Log "Conta $ADMIN criada." 'Green'
        } catch { Log "ERRO ao criar $($ADMIN): $($_.Exception.Message)" 'Red' }
    }
    $admAtivo = Get-LocalUser -Name $ADMIN -ErrorAction SilentlyContinue
    if ($admAtivo -and -not $admAtivo.Enabled) { Enable-LocalUser -Name $ADMIN }
    if ($admAtivo -and -not (Get-LocalGroupMember -SID $SID_ADMS | Where-Object { $_.Name -like "*\$ADMIN" })) {
        Add-LocalGroupMember -SID $SID_ADMS -Member $ADMIN
    }
    $adminOk = [bool](Get-LocalGroupMember -SID $SID_ADMS | Where-Object { $_.Name -like "*\$ADMIN" })
    Log "$ADMIN e administrador: $adminOk"

    # ---------- 4. Aluno vira usuario padrao ----------
    Etapa "4. Conta do aluno '$aluno' -> usuario padrao"
    if (-not $adminOk) {
        Log "PULADO por seguranca: $ADMIN nao esta como administrador. O aluno continua admin." 'Red'
    } elseif ($aluno -eq $ADMIN) {
        Log 'PULADO: o script esta rodando na propria conta CRJ-Admin.' 'Yellow'
    } else {
        if (-not (Get-LocalGroupMember -SID $SID_USERS | Where-Object { $_.Name -like "*\$aluno" })) {
            Add-LocalGroupMember -SID $SID_USERS -Member $aluno -ErrorAction SilentlyContinue
        }
        if (Get-LocalGroupMember -SID $SID_ADMS | Where-Object { $_.Name -like "*\$aluno" }) {
            Remove-LocalGroupMember -SID $SID_ADMS -Member $aluno
            Log "'$aluno' removido do grupo $grpAdm (continua no grupo Usuarios, sem senha, com os mesmos arquivos)." 'Green'
        } else { Log "'$aluno' ja nao era administrador." }
        $outrosAdm = Get-LocalGroupMember -SID $SID_ADMS | Where-Object { $_.Name -notlike "*\$ADMIN" -and $_.Name -notlike '*\Administrador' -and $_.Name -notlike '*\Administrator' }
        foreach ($o in $outrosAdm) { Log "ATENCAO: outra conta ainda e administradora: $($o.Name) (nao mexi)" 'Yellow' }
    }

    # ---------- 5. Politicas do Chrome e Edge ----------
    Etapa '5/6. Restricoes: Chrome/Edge + bloqueio de programas (AppLocker) + aviso + modo manutencao'
    try {
        Invoke-WebRequest "$SERVIDOR/restricoes.ps1" -OutFile "$pasta\restricoes.ps1" -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest "$SERVIDOR/aviso.vbs" -OutFile "$pasta\aviso.vbs" -UseBasicParsing -ErrorAction Stop
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$pasta\restricoes.ps1" -Modo Instalar -Aluno $aluno 2>&1
        $saida | ForEach-Object { Log "   $_" }
        Log 'Restricoes instaladas. Atalhos em: menu Iniciar > CRJ Informatica.' 'Green'
    } catch { Log "ERRO nas restricoes: $($_.Exception.Message)" 'Red' }

    # ---------- 7. Acesso do estudio: Veyon + WinRM ----------
    Etapa "7. Acesso do estudio ($ESTUDIO)"
    # WinRM
    try {
        Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop | Out-Null
        SetReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'LocalAccountTokenFilterPolicy' 1
        Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue | Set-NetFirewallRule -RemoteAddress LocalSubnet
        Log "WinRM ligado (porta 5985 aceita so a rede da sala, com senha do CRJ-Admin)." 'Green'
    } catch { Log "ERRO WinRM: $($_.Exception.Message)" 'Red' }
    if (-not (Get-NetFirewallRule -DisplayName 'CRJ - Ping do estudio' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'CRJ - Ping do estudio' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null
    }

    # Veyon
    $veyonCli = 'C:\Program Files\Veyon\veyon-cli.exe'
    try {
        if (-not (Test-Path $veyonCli)) {
            Log 'Baixando Veyon do estudio...'
            Invoke-WebRequest "$SERVIDOR/veyon-setup.exe" -OutFile "$pasta\veyon-setup.exe" -UseBasicParsing -ErrorAction Stop
            $sig = Get-AuthenticodeSignature "$pasta\veyon-setup.exe"
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*Veyon*') { throw 'assinatura do instalador do Veyon invalida' }
            Start-Process "$pasta\veyon-setup.exe" -ArgumentList '/S', '/NoMaster' -Wait
        }
        Invoke-WebRequest "$SERVIDOR/crj_public_key.pem" -OutFile "$pasta\crj_public_key.pem" -UseBasicParsing -ErrorAction Stop
        if (-not ((& $veyonCli authkeys list) -match 'crj/public')) { & $veyonCli authkeys import crj/public "$pasta\crj_public_key.pem" | Out-Null }
        & $veyonCli config set Authentication/Method 1 | Out-Null
        & $veyonCli service restart | Out-Null
        Start-Sleep 3
        # firewall do Veyon: so o estudio (o instalador silencioso nao cria regra)
        if (-not (Get-NetFirewallRule -DisplayName 'CRJ - Veyon do estudio' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName 'CRJ - Veyon do estudio' -Direction Inbound -Protocol TCP -LocalPort 11100 -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null
        }
        Log "Veyon instalado e com chave do estudio (porta 11100 aceita so a rede da sala, com a chave do estudio)." 'Green'
    } catch { Log "ERRO Veyon: $($_.Exception.Message)" 'Red' }

    # ---------- 8. Resumo e envio ----------
    Etapa '8. Resumo'
    Log "Admins agora: $((Get-LocalGroupMember -SID $SID_ADMS | ForEach-Object Name) -join ', ')"
    Log "Servico Veyon: $((Get-Service VeyonService -ErrorAction SilentlyContinue).Status)"
    Log "Servico WinRM: $((Get-Service WinRM).Status)"
    Log ''
    Log 'PROXIMO PASSO: REINICIE o PC (ou saia e entre de novo na conta do aluno) para valer tudo.' 'Yellow'

    $texto = $rel -join "`r`n"
    $arq = "$pasta\relatorio-$(Get-Date -Format 'yyyy-MM-dd_HH-mm').txt"
    Set-Content -Path $arq -Value $texto -Encoding UTF8
    try {
        Invoke-RestMethod -Method Post -Uri "$SERVIDOR/relatorio?pc=$env:COMPUTERNAME" -Body ([Text.Encoding]::UTF8.GetBytes($texto)) -ContentType 'text/plain; charset=utf-8' -ErrorAction Stop | Out-Null
        Write-Host 'Relatorio enviado para o estudio.' -ForegroundColor Green
    } catch { Write-Host "Relatorio salvo so localmente em $arq" -ForegroundColor Yellow }
}

Invoke-CrjPreparacao
