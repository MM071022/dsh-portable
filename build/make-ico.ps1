# make-ico.ps1 — build a multi-size .ico from icon-256.png using GDI+.
Add-Type -AssemblyName System.Drawing

$src = "C:\Users\manji\Desktop\dsh\build\icon-256.png"
$out = "C:\Users\manji\Desktop\dsh\build\app.ico"
$sizes = @(16, 24, 32, 48, 64, 128, 256)

$master = [System.Drawing.Image]::FromFile($src)

# Render each size to PNG bytes.
$frames = @()   # @{ size = 256; png = [byte[]] }
foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($master, 0, 0, $s, $s)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $frames += @{ size = $s; png = $ms.ToArray() }
    $bmp.Dispose()
    $ms.Dispose()
}
$master.Dispose()

# Build the ICO container.
$count = $frames.Count
$msOut = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($msOut)

# ICONDIR (6 bytes)
$bw.Write([UInt16]0)      # reserved
$bw.Write([UInt16]1)      # type: icon
$bw.Write([UInt16]$count) # count

# Compute image data offset.
$offset = 6 + (16 * $count)
$entries = @()
foreach ($f in $frames) {
    $size = $f.size
    $w = if ($size -ge 256) { 0 } else { $size }   # 0 encodes 256
    $h = if ($size -ge 256) { 0 } else { $size }
    $entries += @{ w = $w; h = $h; bytes = $f.png.Length; offset = $offset }
    $offset += $f.png.Length
}

# ICONDIRENTRY (16 bytes each)
foreach ($e in $entries) {
    $bw.Write([Byte]$e.w)
    $bw.Write([Byte]$e.h)
    $bw.Write([Byte]0)      # color count
    $bw.Write([Byte]0)      # reserved
    $bw.Write([UInt16]1)    # planes
    $bw.Write([UInt16]32)   # bit count
    $bw.Write([UInt32]$e.bytes)
    $bw.Write([UInt32]$e.offset)
}

# Image data (PNG for every size; Vista+ supports PNG-compressed entries).
foreach ($f in $frames) {
    $bw.Write($f.png)
}
$bw.Flush()
[System.IO.File]::WriteAllBytes($out, $msOut.ToArray())
$bw.Dispose()
$msOut.Dispose()

Write-Host ("wrote {0} ({1} bytes, {2} sizes)" -f $out, (Get-Item $out).Length, $count)
