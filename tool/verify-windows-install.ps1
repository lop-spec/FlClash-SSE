param([string]$PackageRoot = 'dist')
$ErrorActionPreference = 'Stop'
$registration = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\A06A5E0D-B8C9-4A3A-B89A-27274D0B708C_is1'
if (Test-Path $registration) { throw 'An existing SSE installation must not be replaced by this temporary acceptance fixture' }
$packages = @(Get-ChildItem $PackageRoot -Recurse -File -Filter '*setup*.exe')
if ($packages.Count -ne 1) { throw "Expected exactly one setup executable, found $($packages.Count)" }
$root = Join-Path $env:TEMP ('FlClashSSE-install-test-' + [guid]::NewGuid().ToString('N'))
$guard = Join-Path $root 'original-fixture'
$installed = Join-Path $root 'isolated'
New-Item $guard -ItemType Directory -Force | Out-Null
$sentinel = Join-Path $guard 'FlClash.exe'
Set-Content $sentinel 'Test fixture, not an executable or an existing user installation.'
$originalHash = (Get-FileHash $sentinel -Algorithm SHA256).Hash
$proxyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
function ProxyState {
    Get-ItemProperty $proxyPath | Select-Object ProxyEnable, ProxyServer, AutoConfigURL | ConvertTo-Json -Compress
}
$beforeProxy = ProxyState
function Install([string]$target, [string]$log) {
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/SP-', '/NORESTART', '/MERGETASKS=!desktopicon', "/DIR=`"$target`"", "/LOG=`"$log`"")
    $process = Start-Process -FilePath $packages[0].FullName -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    return $process.ExitCode
}
$guardLog = Join-Path $root 'guard.log'
$guardExit = Install $guard $guardLog
if ($guardExit -eq 0 -or (Test-Path (Join-Path $guard 'FlClashSSE.exe'))) { throw 'Installer failed to reject original FlClash directory' }
if ((Get-FileHash $sentinel -Algorithm SHA256).Hash -ne $originalHash) { throw 'Original fixture was changed' }
if ((Get-Content $guardLog -Raw) -notmatch 'will not overwrite original FlClash') { throw 'Installer rejection was not caused by the original-directory guard' }
$installLog = Join-Path $root 'install.log'
$installExit = Install $installed $installLog
if ($installExit -ne 0) { Get-Content $installLog -Tail 15; throw "Silent installation failed: $installExit" }
$app = Get-Item (Join-Path $installed 'FlClashSSE.exe')
if ($app.VersionInfo.ProductName -ne 'FlClashSSE' -or $app.VersionInfo.CompanyName -ne 'lop-spec') { throw 'Application data identity is not isolated' }
if (!(Test-Path (Join-Path $installed 'FlClashSSEHelperService.exe'))) { throw 'Isolated helper is absent from installation' }
if (!(Test-Path $registration)) { throw 'Expected per-user isolated uninstall registration' }
& node tool/sse-smoke.cjs (Join-Path $installed 'FlClashSSECore.exe')
if ($LASTEXITCODE -ne 0) { throw 'Installed core end-to-end smoke failed' }
if ((ProxyState) -ne $beforeProxy) { throw 'System proxy settings changed' }
$uninstaller = Join-Path $installed 'unins000.exe'
$uninstall = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -WindowStyle Hidden -Wait -PassThru
if ($uninstall.ExitCode -ne 0) { throw "Isolated uninstall failed: $($uninstall.ExitCode)" }
if ((Test-Path (Join-Path $installed 'FlClashSSE.exe')) -or (Test-Path $registration)) { throw 'Isolated installation was not removed' }
if ((Get-FileHash $sentinel -Algorithm SHA256).Hash -ne $originalHash -or (ProxyState) -ne $beforeProxy) { throw 'Uninstall changed unrelated state' }
Write-Output ('PASS: guarded original directory; per-user install/uninstall; isolated product/core/helper; live SSE/history; unchanged system proxy. Logs: ' + $root)
