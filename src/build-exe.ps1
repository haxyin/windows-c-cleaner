#Requires -Version 5.1
<#
    Rebuild CleanC.exe from CleanC.ps1.

    Run this after editing CleanC.ps1. Two things it does that matter:

      1. Adds a UTF-8 BOM to the source. PowerShell 5.1 reads a BOM-less UTF-8
         .ps1 as ANSI and mangles every Chinese literal, which would turn the
         whole GUI into mojibake.
      2. Passes -STA to ps2exe. WinForms needs a single-threaded-apartment host;
         without it dialogs and the ListView misbehave.
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Paths are derived so the whole folder can be moved anywhere.
#   ...\C盘清理工具\src\  <- this script, CleanC.ps1, CleanC.ico
#   ...\C盘清理工具\      <- the built exe lands here
$toolRoot = Split-Path -Parent $PSScriptRoot
$src = Join-Path $PSScriptRoot 'CleanC.ps1'
$out = Join-Path $toolRoot   'C盘清理工具.exe'
$ico = Join-Path $PSScriptRoot 'CleanC.ico'

if (-not (Test-Path $src)) { throw "source not found: $src" }

# ---- 1. UTF-8 with BOM ----
$c = Get-Content -Raw -Encoding UTF8 $src
[System.IO.File]::WriteAllText($src, $c, (New-Object System.Text.UTF8Encoding $true))
Write-Host '  [1/4] source re-encoded as UTF-8 with BOM' -ForegroundColor Green

# ---- 2. icon ----
# CleanC.ico is a 9-size icon built by icons\make-icon.ps1 (Material Design
# Icons "broom" glyph, white on a blue gradient tile). If it is missing, try
# to regenerate it from the font; if that fails too, fall back to a plain
# blue disc so the build still produces something.
$iconGenerator = Join-Path $toolRoot 'icon\make-icon.ps1'
if (-not (Test-Path $ico) -and (Test-Path $iconGenerator)) {
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $iconGenerator -Glyph broom -Out $ico | Out-Null
    } catch { }
}

if (Test-Path $ico) {
    $icoSize = (Get-Item $ico).Length
    Write-Host ('  [2/4] icon: {0} ({1:N0} bytes)' -f $ico, $icoSize) -ForegroundColor Green
} else {
    try {
        Add-Type -AssemblyName System.Drawing
        $bmp = New-Object System.Drawing.Bitmap 64, 64
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)
        $blue = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0, 120, 212))
        $g.FillEllipse($blue, 2, 2, 60, 60)
        $font = New-Object System.Drawing.Font('Segoe UI', 34, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $g.DrawString('C', $font, $white, (New-Object System.Drawing.RectangleF 2, 3, 60, 60), $sf)
        $g.Dispose()
        $hicon = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($hicon)
        $fs = [System.IO.File]::Create($ico)
        $icon.Save($fs)
        $fs.Close()
        $icon.Dispose(); $bmp.Dispose()
        Write-Host '  [2/4] icon: fallback disc generated' -ForegroundColor DarkYellow
    } catch {
        Write-Host ("  [2/4] icon skipped ({0})" -f $_.Exception.Message.Split([char]10)[0]) -ForegroundColor DarkYellow
        $ico = $null
    }
}

# ---- 3. build ----
Import-Module ps2exe -ErrorAction Stop
$params = @{
    InputFile    = $src
    OutputFile   = $out
    Title        = 'C 盘清理工具'
    Description  = '扫描并清理 C 盘：按风险分级列出可清理项，只删你勾选的。'
    Product      = 'CleanC'
    Version      = '1.0.0.0'
    RequireAdmin = $true
    NoConsole    = $true
    STA          = $true
}
if ($ico -and (Test-Path $ico)) { $params.IconFile = $ico }

Write-Host '  [3/4] building...' -ForegroundColor Cyan
Invoke-PS2EXE @params

# ---- 4. verify ----
if (Test-Path $out) {
    $f = Get-Item $out
    Write-Host ('  [4/4] built: {0}' -f $f.FullName) -ForegroundColor Green
    Write-Host ('        {0:N0} KB    {1}' -f ($f.Length / 1KB), $f.LastWriteTime)
    # Explorer caches exe icons per path; without this the old icon keeps showing
    & ie4uinit.exe -show 2>$null
} else {
    throw 'build produced no output file'
}
