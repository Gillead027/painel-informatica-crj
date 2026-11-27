' Vigia do Painel da Informatica - CRJ Flexal
' Roda escondido a cada 5 min (tarefa "CRJ - Painel (vigia)"): se o painel caiu, liga de novo. Nao abre janela.
Option Explicit
Dim sh, fso, pasta, url
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
url = "http://127.0.0.1:8080/api/estado"
pasta = fso.GetParentFolderName(WScript.ScriptFullName)

If Not PainelNoAr() Then
  WScript.Sleep 15000                 ' pode estar so iniciando (ex.: logo depois de ligar o PC)
  If Not PainelNoAr() Then
    sh.CurrentDirectory = pasta
    sh.Run """C:\Python314\pythonw.exe"" """ & pasta & "\painel.py""", 0, False
  End If
End If

Function PainelNoAr()
  Dim http
  PainelNoAr = False
  On Error Resume Next
  Set http = CreateObject("MSXML2.ServerXMLHTTP.6.0")
  http.setTimeouts 2000, 2000, 5000, 5000
  http.Open "GET", url, False
  http.Send
  If Err.Number = 0 Then If http.Status = 200 Then PainelNoAr = True
  On Error GoTo 0
End Function
