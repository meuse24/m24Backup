Option Explicit

Dim shell, command, scriptPath

scriptPath = "C:\install\Bibliothekssicherung-GUI.ps1"

Set shell = CreateObject("WScript.Shell")

If Not CreateObject("Scripting.FileSystemObject").FileExists(scriptPath) Then
    MsgBox "Das PowerShell-Skript wurde nicht gefunden:" & vbCrLf & scriptPath, vbCritical, "Bibliothekssicherung"
    WScript.Quit 1
End If

command = "powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """"
shell.Run command, 0, False

Set shell = Nothing
