Add-Type -AssemblyName System.Drawing

$size = 256
$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

# скруглённый квадрат с градиентом
$r = 56
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddArc(0, 0, $r, $r, 180, 90)
$path.AddArc($size - $r, 0, $r, $r, 270, 90)
$path.AddArc($size - $r, $size - $r, $r, $r, 0, 90)
$path.AddArc(0, $size - $r, $r, $r, 90, 90)
$path.CloseFigure()

$rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
$c1 = [System.Drawing.Color]::FromArgb(0x5E, 0x8B, 0xFF)
$c2 = [System.Drawing.Color]::FromArgb(0x7C, 0x5C, 0xFF)
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 70.0)
$g.FillPath($brush, $path)

# две стрелки (переключение раскладки)
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 17)
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$g.DrawLine($pen, 64, 96, 186, 96)
$g.DrawLine($pen, 186, 96, 148, 60)
$g.DrawLine($pen, 186, 96, 148, 132)
$g.DrawLine($pen, 192, 160, 70, 160)
$g.DrawLine($pen, 70, 160, 108, 124)
$g.DrawLine($pen, 70, 160, 108, 196)

$g.Dispose()

# PNG -> ICO (одна 256px PNG-запись, поддерживается с Vista)
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
$bytes = $ms.ToArray()
$ms.Dispose()

$out = Join-Path $PSScriptRoot "app.ico"
$fs = [System.IO.File]::Create($out)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([uint16]0)     # reserved
$bw.Write([uint16]1)     # type: icon
$bw.Write([uint16]1)     # count
$bw.Write([byte]0)       # width 256
$bw.Write([byte]0)       # height 256
$bw.Write([byte]0)       # palette
$bw.Write([byte]0)       # reserved
$bw.Write([uint16]1)     # planes
$bw.Write([uint16]32)    # bpp
$bw.Write([uint32]$bytes.Length)
$bw.Write([uint32]22)    # offset
$bw.Write($bytes)
$bw.Close()
Write-Host "icon written: $out"
