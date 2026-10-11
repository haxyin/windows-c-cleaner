# One-shot helper: stop any running CleanC instance so the exe can be rebuilt.
# Temporary file - delete after use. ASCII only, so no BOM needed.

Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -like 'D:\Claude\*' } catch { $false }
} | ForEach-Object {
    Write-Host ('  stopping {0} (pid {1})' -f $_.ProcessName, $_.Id)
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*CleanC.ps1*'
} | ForEach-Object {
    Write-Host ('  stopping ps1 host (pid {0})' -f $_.ProcessId)
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds 3
$left = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -like 'D:\Claude\*' } catch { $false }
})
Write-Host ('  remaining instances: {0}' -f $left.Count)
Start-Sleep -Seconds 1
