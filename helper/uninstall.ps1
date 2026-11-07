<#
Removes the OpenRGB Bridge Helper: stops it, deletes the logon task and the
%LOCALAPPDATA%\OpenRGBBridgeHelper folder.
#>
$TaskName = 'OpenRGB Bridge Helper'
$InstallDir = Join-Path $env:LOCALAPPDATA 'OpenRGBBridgeHelper'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
	Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
	Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
	Write-Host "Removed logon task '$TaskName'"
}

$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'OpenRGB Bridge Helper.lnk'
if (Test-Path $StartupLink) {
	Remove-Item $StartupLink -Force
	Write-Host 'Removed Startup-folder shortcut'
}

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
	Where-Object { $_.CommandLine -like '*OpenRGBBridgeHelper.ps1*' } |
	ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if (Test-Path $InstallDir) {
	Start-Sleep -Milliseconds 500
	Remove-Item -Path $InstallDir -Recurse -Force
	Write-Host "Removed $InstallDir"
}
Write-Host 'OpenRGB Bridge Helper uninstalled.'
