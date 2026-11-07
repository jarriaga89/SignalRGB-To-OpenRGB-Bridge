<#
Installs the OpenRGB Bridge Helper for the current user:
  1. Copies OpenRGBBridgeHelper.ps1 to %LOCALAPPDATA%\OpenRGBBridgeHelper
     (from this folder, or downloads it from the fork if run via irm | iex).
  2. Registers a Task Scheduler task "OpenRGB Bridge Helper" that starts it hidden at logon.
  3. Starts it now and checks that it answers on http://localhost:6748/ping.
No administrator rights needed. Remove everything with uninstall.ps1.
#>
$ErrorActionPreference = 'Stop'

$TaskName = 'OpenRGB Bridge Helper'
$InstallDir = Join-Path $env:LOCALAPPDATA 'OpenRGBBridgeHelper'
$Target = Join-Path $InstallDir 'OpenRGBBridgeHelper.ps1'
$SourceUrl = 'https://raw.githubusercontent.com/jarriaga89/SignalRGB-To-OpenRGB-Bridge/main/helper/OpenRGBBridgeHelper.ps1'
$Port = 6748

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# Stop a running copy so the file can be replaced.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
	Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
	Where-Object { $_.CommandLine -like '*OpenRGBBridgeHelper.ps1*' } |
	ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$localCopy = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'OpenRGBBridgeHelper.ps1' } else { $null }
if ($localCopy -and (Test-Path $localCopy)) {
	Copy-Item -Path $localCopy -Destination $Target -Force
	Write-Host "Copied helper from $localCopy"
} else {
	Invoke-WebRequest -Uri $SourceUrl -OutFile $Target -UseBasicParsing
	Write-Host "Downloaded helper from $SourceUrl"
}
Unblock-File -Path $Target -ErrorAction SilentlyContinue

# powershell.exe -WindowStyle Hidden still shows a console when started by Task
# Scheduler, and closing that window stops the helper. A Windows Script Host launcher
# starts it with no window at all.
$Launcher = Join-Path $InstallDir 'start-helper.vbs'
$psCommand = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$Target"""
Set-Content -Path $Launcher -Encoding ASCII -Value @(
	'Set shell = CreateObject("WScript.Shell")',
	('shell.Run "' + $psCommand.Replace('"', '""') + '", 0, False')
)
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$Launcher`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
	-ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'OpenRGB Bridge Helper.lnk'
$arguments = "`"$Launcher`""
$useTask = $true
try {
	Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
		-Description 'Forwards SignalRGB colours from the OpenRGB Bridge addon to OpenRGB (localhost only).' -Force | Out-Null
	Write-Host "Registered logon task '$TaskName'"
	if (Test-Path $StartupLink) { Remove-Item $StartupLink -Force }
} catch {
	# Some systems refuse logon tasks without admin rights; a Startup-folder shortcut needs none.
	$useTask = $false
	$shell = New-Object -ComObject WScript.Shell
	$link = $shell.CreateShortcut($StartupLink)
	$link.TargetPath = 'wscript.exe'
	$link.Arguments = $arguments
	$link.Description = 'OpenRGB Bridge Helper'
	$link.Save()
	Write-Host "Logon task refused ($($_.Exception.Message)); added a Startup-folder shortcut instead"
}

if ($useTask) {
	Start-ScheduledTask -TaskName $TaskName
} else {
	Start-Process -FilePath 'wscript.exe' -ArgumentList $arguments
}
$ok = $false
for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
	Start-Sleep -Milliseconds 500
	try {
		$ok = (Invoke-WebRequest -Uri "http://localhost:$Port/ping" -UseBasicParsing -TimeoutSec 2).Content -eq 'ok'
	} catch {
	}
}

if ($ok) {
	Write-Host "Helper is running on http://localhost:$Port/" -ForegroundColor Green
} else {
	Write-Host "Helper did not answer yet. Check $InstallDir\helper.log" -ForegroundColor Yellow
}
