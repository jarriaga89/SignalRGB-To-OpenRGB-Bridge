# OpenRGB Bridge Helper

On SignalRGB 2.5.86, devices created by an addon cannot open network sockets, so the
OpenRGB Bridge device cannot reach OpenRGB's SDK server itself. It can still make HTTP
requests, so it sends each changed frame to this helper on `http://localhost:6748`, and
the helper forwards the colours to OpenRGB over one SDK connection.

The add-on still handles discovery, device registration and the LED layout; only the
colour data goes through the helper.

## Install (once, no admin rights)

In PowerShell:

```powershell
irm https://raw.githubusercontent.com/jarriaga89/SignalRGB-To-OpenRGB-Bridge/main/helper/install.ps1 | iex
```

This copies `OpenRGBBridgeHelper.ps1` to `%LOCALAPPDATA%\OpenRGBBridgeHelper`, registers
a Task Scheduler task **OpenRGB Bridge Helper** that starts it hidden at logon (or a
Startup-folder shortcut if Windows refuses the task), starts it, and checks
`http://localhost:6748/ping`.

## Remove

```powershell
irm https://raw.githubusercontent.com/jarriaga89/SignalRGB-To-OpenRGB-Bridge/main/helper/uninstall.ps1 | iex
```

## Log

`%LOCALAPPDATA%\OpenRGBBridgeHelper\helper.log` (rotated at 1 MB).
