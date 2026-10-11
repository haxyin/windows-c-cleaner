#Requires -Version 5.1
<#
    Build CleanC.ico from a Material Design Icons webfont glyph.

    Draws the glyph (white, ink-bounds centred) on a rounded square with a
    blue gradient, rasterises it at every size Explorer asks for, and packs
    the lot into a multi-size .ico (uncompressed 32bpp DIB entries, so csc
    /win32icon and ps2exe both accept it).

    Usage:
        powershell -File make-icon.ps1 -Glyph broom
        powershell -File make-icon.ps1 -Glyph broom -Preview     # also dump PNGs
#>
param(
    [string]$Glyph = 'broom',
    [string]$Out   = 'D:\Claude\C盘清理工具\src\CleanC.ico',
    [switch]$Preview
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'D:\Claude\C盘清理工具\icon' }

$ttf = Join-Path $here 'mdi\package\fonts\materialdesignicons-webfont.ttf'
if (-not (Test-Path $ttf)) { throw "font not found: $ttf" }

# ---- codepoints we might use (MDI 7.4.47; all above U+FFFF) ----
$map = @{
    'broom'            = 0xF00E2
    'delete-sweep'     = 0xF05E9
    'delete-empty'     = 0xF06CC
    'delete-variant'   = 0xF01B3
    'auto-fix'         = 0xF0068
    'vacuum'           = 0xF19A1
    'spray-bottle'     = 0xF0AE0
    'eraser-variant'   = 0xF0642
    'recycle-variant'  = 0xF139D
    'shimmer'          = 0xF1545
    'refresh'          = 0xF0450
    'magic-staff'      = 0xF1844
}
if (-not $map.ContainsKey($Glyph)) { throw ("unknown glyph '{0}'. known: {1}" -f $Glyph, (($map.Keys | Sort-Object) -join ', ')) }
$codepoint = $map[$Glyph]
$ch = [char]::ConvertFromUtf32($codepoint)

$pfc = New-Object System.Drawing.Text.PrivateFontCollection
$pfc.AddFontFile($ttf)
$family = $pfc.Families[0]

# ---- palette: bright sky blue -> deep blue ----
$colTop = [System.Drawing.Color]::FromArgb(255, 56, 182, 255)
$colBot = [System.Drawing.Color]::FromArgb(255, 13, 90, 200)
$colGlyph = [System.Drawing.Color]::White

function New-Tile([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

    # glyph outline, in font units
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $sfmt = New-Object System.Drawing.StringFormat
    $gp.AddString($ch, $family, [int][System.Drawing.FontStyle]::Regular, 100.0,
                  (New-Object System.Drawing.PointF 0, 0), $sfmt)
    $b = $gp.GetBounds()

    # scale so the ink box fits 62% of the tile, then centre it
    $target = $size * 0.62
    $s = $target / [Math]::Max($b.Width, $b.Height)
    $m = New-Object System.Drawing.Drawing2D.Matrix
    $m.Translate(-($b.X * $s) - ($b.Width * $s / 2) + ($size / 2),
                 -($b.Y * $s) - ($b.Height * $s / 2) + ($size / 2))
    $m.Scale($s, $s)
    $gp.Transform($m)

    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)

    # rounded square background
    $r = [double]$size * 0.20
    $d = $r * 2
    $bg = New-Object System.Drawing.Drawing2D.GraphicsPath
    $bg.AddArc(0, 0, $d, $d, 180, 90)
    $bg.AddArc($size - $d, 0, $d, $d, 270, 90)
    $bg.AddArc($size - $d, $size - $d, $d, $d, 0, 90)
    $bg.AddArc(0, $size - $d, $d, $d, 90, 90)
    $bg.CloseFigure()

    $rect = New-Object System.Drawing.RectangleF 0, 0, $size, $size
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, $colTop, $colBot, 60.0
    $g.FillPath($brush, $bg)
    $brush.Dispose()

    # glass highlight across the top third
    $g.SetClip($bg)
    $hi = New-Object System.Drawing.RectangleF 0, (-0.55 * $size), $size, (1.0 * $size)
    $hColors = @(
        [System.Drawing.Color]::FromArgb(70, 255, 255, 255),
        [System.Drawing.Color]::FromArgb(0, 255, 255, 255))
    $hStops = @(0.0, 1.0)
    $hb = New-Object System.Drawing.Drawing2D.LinearGradientBrush $hi, ([System.Drawing.Color]::White), ([System.Drawing.Color]::Transparent), 90.0
    $blend = New-Object System.Drawing.Drawing2D.ColorBlend 2
    $blend.Colors = $hColors
    $blend.Positions = $hStops
    $hb.InterpolationColors = $blend
    $g.FillRectangle($hb, $hi)
    $hb.Dispose()
    $g.ResetClip()

    # glyph
    $gb = New-Object System.Drawing.SolidBrush $colGlyph
    $g.FillPath($gb, $gp)
    $gb.Dispose()

    # hairline white rim, only visible at >= 32 px
    if ($size -ge 32) {
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(48, 255, 255, 255)), ([single]([Math]::Max(1, $size / 128)))
        $g.DrawPath($pen, $bg)
        $pen.Dispose()
    }

    $g.Dispose(); $gp.Dispose(); $bg.Dispose(); $sfmt.Dispose()
    return $bmp
}

# ---- assemble a multi-size .ico (uncompressed 32bpp DIB entries) ----
function Get-DibBytes([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width; $h = $bmp.Height
    $bd = $bmp.LockBits((New-Object System.Drawing.Rectangle 0, 0, $w, $h),
                        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $bd.Stride
    $raw = New-Object byte[] ($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $raw, 0, $raw.Length)
    $bmp.UnlockBits($bd)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    # BITMAPINFOHEADER, biHeight doubled to cover the AND mask
    $bw.Write([int]40); $bw.Write([int]$w); $bw.Write([int]($h * 2))
    $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int]0); $bw.Write([int]($stride * $h))
    $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    # XOR bitmap, bottom-up
    for ($y = $h - 1; $y -ge 0; $y--) { $bw.Write($raw, ($y * $stride), $stride) }
    # AND mask: all zero (alpha channel does the work), rows padded to 4 bytes
    $maskStride = [int]([Math]::Ceiling($w / 32.0) * 4)
    $bw.Write((New-Object byte[] ($maskStride * $h)))
    $bw.Flush()
    $out = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    return $out
}

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$images = @()
foreach ($sz in $sizes) {
    $b = New-Tile $sz
    # NB: cast matters. Get-DibBytes returns Object[]; BinaryWriter.Write() binds
    # the wrong overload for that and silently writes 1 byte per image, producing
    # a 159-byte .ico that System.Drawing.Icon refuses to load.
    $dib = [byte[]](Get-DibBytes $b)
    $images += , @{ Size = $sz; Data = $dib }
    if ($Preview) {
        $dir = Join-Path $here 'preview'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $b.Save((Join-Path $dir ("{0}-{1}.png" -f $Glyph, $sz)), [System.Drawing.Imaging.ImageFormat]::Png)
    }
    $b.Dispose()
}

$fs = [System.IO.File]::Create($Out)
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$images.Count)
$offset = 6 + (16 * $images.Count)
foreach ($img in $images) {
    $sz = $img.Size
    $bw.Write([byte]$(if ($sz -ge 256) { 0 } else { $sz }))
    $bw.Write([byte]$(if ($sz -ge 256) { 0 } else { $sz }))
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int]$img.Data.Length)
    $bw.Write([int]$offset)
    $offset += $img.Data.Length
}
foreach ($img in $images) { $bw.Write($img.Data) }
$bw.Flush(); $bw.Dispose(); $fs.Dispose()

$fi = Get-Item $Out
Write-Host ("icon: {0}  ({1:N0} bytes, {2} sizes, glyph '{3}')" -f $fi.FullName, $fi.Length, $sizes.Count, $Glyph)

# sanity: can .NET read it back as an Icon?
try {
    $test = New-Object System.Drawing.Icon $Out
    Write-Host ("  verified: System.Drawing.Icon loaded {0}x{1}" -f $test.Width, $test.Height)
    $test.Dispose()
} catch {
    throw ("icon is not loadable: {0}" -f $_.Exception.Message)
}
