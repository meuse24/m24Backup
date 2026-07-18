Option Explicit

Dim shell, command, scriptPath, fso, scriptDirectory, argument

Set fso = CreateObject("Scripting.FileSystemObject")
scriptDirectory = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(scriptDirectory, "Bibliothekssicherung-GUI.ps1")

Set shell = CreateObject("WScript.Shell")

If Not fso.FileExists(scriptPath) Then
    MsgBox "Das PowerShell-Skript wurde nicht gefunden:" & vbCrLf & scriptPath, vbCritical, "Bibliothekssicherung"
    WScript.Quit 1
End If

command = "powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """"
For Each argument In WScript.Arguments
    If LCase(argument) = "/silentstartup" Or LCase(argument) = "-silentstartup" Then
        command = command & " -SilentStartup"
    End If
Next
shell.Run command, 0, False

Set shell = Nothing
Set fso = Nothing
