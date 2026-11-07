<#
OpenRGB Bridge Helper

Why this exists: on SignalRGB 2.5.86, an addon-created device cannot open TCP or UDP
sockets, so the OpenRGB Bridge device cannot talk to OpenRGB's SDK server itself. It
can still make HTTP requests. This helper receives those requests on localhost and
forwards the colours to OpenRGB over one persistent SDK connection.

What it does, and nothing else:
  - Listens on http://localhost:<ListenPort>/ (local machine only).
  - GET /ping                          -> "ok"
  - GET /frame?h=HOST&p=PORT&i=INDEX&c=RRGGBB[RRGGBB...]
        Switches OpenRGB controller INDEX to custom mode (once per connection) and
        sends its LED colours (OpenRGB SDK commands 1100 SETCUSTOMMODE / 1050 UPDATELEDS).
  - Writes a small log to %LOCALAPPDATA%\OpenRGBBridgeHelper\helper.log (rotated at 1 MB).

Runs in Windows PowerShell 5.1; nothing to install.
#>
param(
	[int]$ListenPort = 6748,
	[string]$LogDir = (Join-Path $env:LOCALAPPDATA 'OpenRGBBridgeHelper')
)

$ErrorActionPreference = 'Stop'

# One instance per user session.
$createdNew = $false
# [ref] arguments do not round-trip through New-Object, so use ::new().
$mutex = [System.Threading.Mutex]::new($true, 'Local\OpenRGBBridgeHelper', [ref]$createdNew)
if (-not $createdNew) {
	exit 0
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$script:LogFile = Join-Path $LogDir 'helper.log'

function Write-Log([string]$Message) {
	try {
		if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 1MB)) {
			Move-Item -Path $script:LogFile -Destination "$($script:LogFile).old" -Force
		}
		Add-Content -Path $script:LogFile -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
	} catch {
	}
}

# ---- OpenRGB SDK connection -------------------------------------------------------

$script:Client = $null
$script:Stream = $null
$script:Target = ''
$script:CustomMode = @{}
$script:NextConnect = [datetime]::MinValue
$script:FramesSent = 0

function New-Packet([uint32]$DeviceIndex, [uint32]$Command, [byte[]]$Payload) {
	if ($null -eq $Payload) {
		$Payload = New-Object byte[] 0
	}
	$memory = New-Object System.IO.MemoryStream
	$writer = New-Object System.IO.BinaryWriter($memory)   # little-endian
	$writer.Write([System.Text.Encoding]::ASCII.GetBytes('ORGB'))
	$writer.Write([uint32]$DeviceIndex)
	$writer.Write([uint32]$Command)
	$writer.Write([uint32]$Payload.Length)
	$writer.Write($Payload)
	$writer.Flush()
	return ,$memory.ToArray()
}

function Send-Packet([uint32]$DeviceIndex, [uint32]$Command, [byte[]]$Payload) {
	$bytes = New-Packet $DeviceIndex $Command $Payload
	$script:Stream.Write($bytes, 0, $bytes.Length)
}

function Clear-Incoming {
	# OpenRGB may push notifications (e.g. device list updated); discard them.
	while ($script:Client -and $script:Client.Available -gt 0) {
		$buffer = New-Object byte[] ([Math]::Min($script:Client.Available, 65536))
		[void]$script:Stream.Read($buffer, 0, $buffer.Length)
	}
}

function Disconnect-OpenRgb {
	if ($script:Client) {
		try { $script:Client.Close() } catch { }
	}
	$script:Client = $null
	$script:Stream = $null
	$script:Target = ''
	$script:CustomMode = @{}
}

function Connect-OpenRgb([string]$HostName, [int]$Port) {
	Disconnect-OpenRgb
	if ([datetime]::UtcNow -lt $script:NextConnect) {
		return $false
	}
	try {
		$tcp = New-Object System.Net.Sockets.TcpClient
		$pending = $tcp.BeginConnect($HostName, $Port, $null, $null)
		if (-not $pending.AsyncWaitHandle.WaitOne(2000)) {
			$tcp.Close()
			throw 'connection timed out'
		}
		$tcp.EndConnect($pending)
		$tcp.NoDelay = $true
		$script:Client = $tcp
		$script:Stream = $tcp.GetStream()
		$script:Target = "${HostName}:$Port"
		Send-Packet 0 50 ([System.Text.Encoding]::ASCII.GetBytes("SignalRGB OpenRGB Bridge Helper`0"))   # SET_CLIENT_NAME
		Write-Log "Connected to OpenRGB at ${HostName}:$Port"
		return $true
	} catch {
		$script:NextConnect = [datetime]::UtcNow.AddSeconds(3)
		Write-Log "Could not connect to OpenRGB at ${HostName}:${Port}: $($_.Exception.Message)"
		Disconnect-OpenRgb
		return $false
	}
}

function Send-Frame([string]$HostName, [int]$Port, [uint32]$Index, [string]$Hex) {
	$target = "${HostName}:$Port"
	if (-not $script:Client -or -not $script:Client.Connected -or $script:Target -ne $target) {
		if (-not (Connect-OpenRgb $HostName $Port)) {
			return $false
		}
	}

	$count = [int]($Hex.Length / 6)
	$memory = New-Object System.IO.MemoryStream
	$writer = New-Object System.IO.BinaryWriter($memory)
	$writer.Write([uint32](4 + 2 + 4 * $count))   # data size
	$writer.Write([uint16]$count)
	for ($i = 0; $i -lt $count; $i++) {
		$writer.Write([byte][Convert]::ToInt32($Hex.Substring($i * 6, 2), 16))
		$writer.Write([byte][Convert]::ToInt32($Hex.Substring($i * 6 + 2, 2), 16))
		$writer.Write([byte][Convert]::ToInt32($Hex.Substring($i * 6 + 4, 2), 16))
		$writer.Write([byte]0)
	}
	$writer.Flush()
	$payload = $memory.ToArray()

	try {
		$key = [string]$Index
		if (-not $script:CustomMode.ContainsKey($key)) {
			Send-Packet $Index 1100 $null   # SETCUSTOMMODE
			$script:CustomMode[$key] = $true
			Write-Log "Switched OpenRGB controller $Index to custom mode"
		}
		Send-Packet $Index 1050 $payload   # UPDATELEDS
		Clear-Incoming
		$script:FramesSent++
		if ($script:FramesSent -eq 1) {
			Write-Log "First frame sent to OpenRGB controller $Index ($count LEDs)"
		}
		return $true
	} catch {
		Write-Log "Sending to OpenRGB failed: $($_.Exception.Message)"
		Disconnect-OpenRgb
		return $false
	}
}

# ---- HTTP listener ----------------------------------------------------------------

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$ListenPort/")
try {
	$listener.Start()
} catch {
	Write-Log "Could not listen on http://localhost:${ListenPort}/: $($_.Exception.Message)"
	exit 1
}
Write-Log "Listening on http://localhost:${ListenPort}/"

try {
	while ($listener.IsListening) {
		$context = $listener.GetContext()
		$request = $context.Request
		$response = $context.Response
		$status = 200
		$body = 'ok'

		try {
			switch ($request.Url.AbsolutePath) {
				'/ping' {
					$body = 'ok'
				}
				'/frame' {
					$query = $request.QueryString
					$hostName = if ($query['h']) { [string]$query['h'] } else { '127.0.0.1' }
					$port = if ($query['p']) { [int]$query['p'] } else { 6742 }
					$colors = [string]$query['c']
					if ($null -eq $query['i'] -or $colors -notmatch '^([0-9a-fA-F]{6})+$') {
						$status = 400
						$body = 'expected i=<index>&c=<RRGGBB...>'
					} elseif (-not (Send-Frame $hostName $port ([uint32]$query['i']) $colors)) {
						$status = 503
						$body = 'OpenRGB unavailable'
					}
				}
				default {
					$status = 404
					$body = 'not found'
				}
			}
		} catch {
			$status = 500
			$body = $_.Exception.Message
		}

		try {
			$bytes = [System.Text.Encoding]::ASCII.GetBytes($body)
			$response.StatusCode = $status
			$response.ContentType = 'text/plain'
			$response.ContentLength64 = $bytes.Length
			$response.OutputStream.Write($bytes, 0, $bytes.Length)
			$response.Close()
		} catch {
		}
	}
} finally {
	Write-Log 'Stopping'
	try { $listener.Stop() } catch { }
	Disconnect-OpenRgb
	$mutex.ReleaseMutex()
}
