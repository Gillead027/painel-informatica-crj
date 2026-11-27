' Painel da Informatica - CRJ Flexal
' Abre o painel como programa: servidor escondido (sem janela preta) + janela propria do Chrome.
' Funciona de qualquer pasta (inclusive da pasta Inicializar do Windows).
Option Explicit
Dim sh, fso, desk, pasta, proj, i, url
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
url = "http://127.0.0.1:8080"

' 1) acha a pasta do projeto na Area de Trabalho
desk = sh.SpecialFolders("Desktop")
proj = ""
For Each pasta In fso.GetFolder(desk).SubFolders
  If UCase(Left(pasta.Name, 14)) = "CONTRLE INFORM" Then
    If fso.FileExists(pasta.Path & "\painel\painel.py") Then proj = pasta.Path
  End If
Next
If proj = "" Then
  MsgBox "Nao encontrei a pasta CONTRLE INFORMATICA na Area de Trabalho.", vbExclamation, "Painel da Informatica"
  WScript.Quit 1
End If

' 2) liga o servidor do painel (escondido), se ainda nao estiver rodando
If Not PainelNoAr() Then
  sh.CurrentDirectory = proj & "\painel"
  sh.Run """C:\Python314\pythonw.exe"" """ & proj & "\painel\painel.py""", 0, False
  For i = 1 To 40
    WScript.Sleep 500
    If PainelNoAr() Then Exit For
  Next
  If Not PainelNoAr() Then
    MsgBox "O painel nao conseguiu iniciar. Veja o arquivo painel\painel.log ou abra o PAINEL.bat para ver o erro.", vbExclamation, "Painel da Informatica"
    WScript.Quit 1
  End If
End If

' 3) abre a janela do programa (Chrome em modo aplicativo)
sh.Run """C:\Program Files\Google\Chrome\Application\chrome.exe"" --app=" & url & " --start-maximized", 1, False

Function PainelNoAr()
  Dim http
  PainelNoAr = False
  On Error Resume Next
  Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
  http.setTimeouts 1000, 1000, 2000, 2000
  http.Open "GET", url & "/api/estado", False
  http.Send
  If Err.Number = 0 Then If http.Status = 200 Then PainelNoAr = True
  On Error GoTo 0
End Function