param(
    [string]$InputDir = "png",
    [string]$OutputDir = "src\assets",
    # basenames stored as RGB323 (8-bit) instead of RGB565 (16-bit)
    [string[]]$Sprites8bit = @("survivor", "bullet"),
    # PNGs kept in png/ but not converted. Add a basename here if you want to
    # keep the art around without it becoming a .mem file.
    [string[]]$SkipBases = @(),
    # Sprites packed (RGB323) back-to-back into one atlas ROM, in this order.
    # The enemy sprites share a ROM so they cost ONE block of RAM instead of two
    # (only one spare block is left). obj_layer picks the half with the top
    # address bit: 0 = zombie, 1 = boss.
    [string[]]$ObjAtlas = @("zombie", "boss"),
    [string]$ObjAtlasFile = "obj_atlas.mem",
    # Target sprite box size (N x N) is taken from the trailing "_<N>" in the
    # base name (e.g. obj_plus1_16 -> 16, player_right_32 -> 32); any-size source
    # art is scaled to fit (aspect-preserved, transparent pad). This map is an
    # override for bases that have no size suffix.
    # The boss is 3x a normal 32x32 zombie, so 96x96 on screen. It is stored at
    # 24x24 and drawn at QUADRUPLE size, because 96/24 = 4 is a power of two and
    # obj_layer can scale it by throwing away 2 address bits -- free. Storing it
    # at 32x32 would need a divide by 3, which costs real logic we do not have.
    # It still lives in the zombie's 32-wide atlas slot, so the ROM stays 2048
    # deep = one block of RAM.
    [hashtable]$FitSize = @{ "survivor" = 32; "bullet" = 16; "zombie" = 32; "boss" = 24 },
    # Big-image mode: bases here are STRETCHED to exactly W x H (aspect ratio NOT
    # preserved, no transparent pad). Used for the full-screen background tile.
    [hashtable]$StretchSize = @{ "daylight" = @(80, 50) },
    # Rows trimmed off the TOP of the source before anything is stretched or
    # fitted. We use it on the background to control how much sky the map shows.
    # daylight.png is 1536x1024, so dropping the first 260 rows leaves 764 that
    # get squeezed down into the 80x50 tile.
    #
    # If you change this number the rubble line moves, and GROUND_TOP in
    # src/game/game_defs.vh has to be re-measured to match, or the characters
    # will float above the ground or sink into it.
    [hashtable]$CropTop = @{ "daylight" = 260 }
)

Add-Type -AssemblyName System.Drawing

$ROOT = Split-Path -Parent $PSScriptRoot

function Resolve-LocalPath {
    param([string]$PathValue)
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }
    return Join-Path $ROOT $PathValue
}

$InputPath = Resolve-LocalPath $InputDir
$OutputPath = Resolve-LocalPath $OutputDir

if (!(Test-Path $InputPath -PathType Container)) {
    throw "Input folder not found: $InputPath"
}

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$pngFiles = Get-ChildItem -Path $InputPath -Filter "*.png" -File | Sort-Object Name

if ($pngFiles.Count -eq 0) {
    throw "No .png files found in: $InputPath"
}

# Scale a bitmap to fit an N x N box, keeping aspect ratio, centered, with a
# transparent background (32bpp ARGB, high-quality downscale).
function Fit-Bitmap {
    param($src, [int]$n)
    $dst = New-Object System.Drawing.Bitmap($n, $n, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $scale = [Math]::Min($n / $src.Width, $n / $src.Height)
    $w = [int][Math]::Round($src.Width * $scale)
    $h = [int][Math]::Round($src.Height * $scale)
    if ($w -lt 1) { $w = 1 }
    if ($h -lt 1) { $h = 1 }
    $ox = [int](($n - $w) / 2)
    $oy = [int](($n - $h) / 2)
    $g.DrawImage($src, $ox, $oy, $w, $h)
    $g.Dispose()
    return $dst
}

# Stretch a bitmap to exactly W x H, ignoring aspect ratio (accepts distortion).
function Stretch-Bitmap {
    param($src, [int]$w, [int]$h)
    $dst = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($src, 0, 0, $w, $h)
    $g.Dispose()
    return $dst
}

# Find the box that holds every non-transparent pixel: @(minX, minY, maxX, maxY).
# Uses LockBits instead of GetPixel because GetPixel on a 1024x1024 image is slow.
function Get-ContentBox {
    param($bmp)
    $rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
    $data = $bmp.LockBits($rect,
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $bytes = New-Object byte[] ($stride * $bmp.Height)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $bmp.UnlockBits($data)

    $minX = $bmp.Width; $maxX = -1
    $minY = $bmp.Height; $maxY = -1
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        $row = $y * $stride
        for ($x = 0; $x -lt $bmp.Width; $x++) {
            if ($bytes[$row + $x * 4 + 3] -gt 8) {      # alpha byte of BGRA
                if ($x -lt $minX) { $minX = $x }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    return @($minX, $minY, $maxX, $maxY)
}

# Cut away the empty border around a drawing so the drawing itself fills the
# sprite box. Without this, art sitting in the middle of a big canvas comes out
# tiny: a 165x233 zombie on a 666x375 canvas would shrink to about 8x11.
function Trim-Transparent {
    param($src)
    $box = Get-ContentBox $src
    $minX = $box[0]; $minY = $box[1]; $maxX = $box[2]; $maxY = $box[3]
    if ($maxX -lt 0) { return $src }                     # nothing visible at all
    $w = $maxX - $minX + 1
    $h = $maxY - $minY + 1
    if ($w -eq $src.Width -and $h -eq $src.Height) { return $src }

    $dst = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.DrawImage(
        $src,
        (New-Object System.Drawing.Rectangle 0, 0, $w, $h),
        (New-Object System.Drawing.Rectangle $minX, $minY, $w, $h),
        [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    return $dst
}

# Cut $top rows off the top of a bitmap, keeping the full width and the rest of
# the height. Returns the original bitmap when there is nothing to cut.
function Crop-TopRows {
    param($src, [int]$top)
    if ($top -le 0 -or $top -ge $src.Height) { return $src }
    $h = $src.Height - $top
    $dst = New-Object System.Drawing.Bitmap($src.Width, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.DrawImage(
        $src,
        (New-Object System.Drawing.Rectangle 0, 0, $src.Width, $h),
        (New-Object System.Drawing.Rectangle 0, $top, $src.Width, $h),
        [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    return $dst
}

# Target N x N box for a base: explicit override, else trailing "_<N>", else 0 (none).
function Get-TargetSize {
    param([string]$base)
    if ($FitSize.ContainsKey($base)) { return [int]$FitSize[$base] }
    if ($base -match '_(\d+)$') { return [int]$Matches[1] }
    return 0
}

# Load a sprite bitmap for the given base: stretch to W x H if listed in
# $StretchSize, else fit (aspect-preserved) to its N x N target box if any.
function Load-Sprite {
    param([string]$path, [string]$base)
    $bmp = [System.Drawing.Bitmap]::new($path)
    if ($CropTop.ContainsKey($base)) {
        $cropped = Crop-TopRows $bmp ([int]$CropTop[$base])
        if (-not [object]::ReferenceEquals($cropped, $bmp)) {
            $bmp.Dispose()
            $bmp = $cropped
        }
    }
    if ($StretchSize.ContainsKey($base)) {
        $wh = $StretchSize[$base]
        $w = [int]$wh[0]; $h = [int]$wh[1]
        if ($bmp.Width -ne $w -or $bmp.Height -ne $h) {
            $stretched = Stretch-Bitmap $bmp $w $h
            $bmp.Dispose()
            return $stretched
        }
        return $bmp
    }
    $n = Get-TargetSize $base
    if ($n -gt 0) {
        # Trim the empty border first so the drawing fills the sprite box.
        $trimmed = Trim-Transparent $bmp
        if (-not [object]::ReferenceEquals($trimmed, $bmp)) {
            $bmp.Dispose()
            $bmp = $trimmed
        }
        if ($bmp.Width -ne $n -or $bmp.Height -ne $n) {
            $fitted = Fit-Bitmap $bmp $n
            $bmp.Dispose()
            return $fitted
        }
    }
    return $bmp
}

# Write one bitmap's pixels (row-major) to an open StreamWriter.
function Write-Pixels {
    param($bmp, $writer, [bool]$use8bit)
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
            $color = $bmp.GetPixel($x, $y)
            if ($use8bit) {
                # RGB323: transparency comes ONLY from PNG alpha; an opaque pixel
                # never emits the 0x00 sentinel (near-black is bumped to 0x01).
                if ([int]$color.A -eq 0) {
                    $writer.WriteLine("00")
                }
                else {
                    $r = [int]$color.R; $g = [int]$color.G; $b = [int]$color.B
                    $val8 = (($r -shr 5) -shl 5) -bor (($g -shr 6) -shl 3) -bor ($b -shr 5)
                    if ($val8 -eq 0) { $val8 = 1 }
                    $writer.WriteLine("{0:X2}" -f $val8)
                }
            }
            else {
                # RGB565 has no alpha channel: transparency comes from PNG alpha
                # (A==0 -> 0x0000). Only the opaque background layer uses this format.
                $r = [int]$color.R; $g = [int]$color.G; $b = [int]$color.B
                if ([int]$color.A -eq 0) { $r = 0; $g = 0; $b = 0 }
                $val16 = (($r -shr 3) -shl 11) -bor (($g -shr 2) -shl 5) -bor ($b -shr 3)
                $writer.WriteLine("{0:X4}" -f $val16)
            }
        }
    }
}

# Classify: "<base>.<N>" is frame N of animation group <base>; else standalone.
$groups = @{}
$singles = @()
foreach ($png in $pngFiles) {
    if ($png.BaseName -match '^(.+)\.(\d+)$') {
        $base = $Matches[1]
        $idx = [int]$Matches[2]
        if (-not $groups.ContainsKey($base)) { $groups[$base] = @() }
        $groups[$base] += [pscustomobject]@{ Idx = $idx; File = $png }
    }
    else {
        $singles += $png
    }
}

$convertedCount = 0

foreach ($png in $singles) {
    $base = $png.BaseName
    if ($SkipBases -contains $base) { continue }  # deliberately not converted
    if ($ObjAtlas -contains $base) { continue }   # packed into the atlas below, not emitted singly
    $use8bit = $Sprites8bit -contains $base
    if ($use8bit) { $fmt = "RGB323" } else { $fmt = "RGB565" }
    $memPath = Join-Path $OutputPath ($base + ".mem")
    $bmp = Load-Sprite $png.FullName $base
    $w = $bmp.Width; $h = $bmp.Height
    $writer = [System.IO.StreamWriter]::new($memPath, $false, [System.Text.Encoding]::ASCII)
    try {
        Write-Pixels $bmp $writer $use8bit
    }
    finally {
        $writer.Dispose()
        $bmp.Dispose()
    }
    $convertedCount++
    Write-Host "$($png.Name) -> $base.mem ($w x $h, $fmt)"
}

foreach ($base in ($groups.Keys | Sort-Object)) {
    $frames = $groups[$base] | Sort-Object Idx
    $use8bit = $Sprites8bit -contains $base
    if ($use8bit) { $fmt = "RGB323" } else { $fmt = "RGB565" }
    $memPath = Join-Path $OutputPath ($base + ".mem")
    $writer = [System.IO.StreamWriter]::new($memPath, $false, [System.Text.Encoding]::ASCII)
    try {
        foreach ($fr in $frames) {
            $bmp = Load-Sprite $fr.File.FullName $base
            try { Write-Pixels $bmp $writer $use8bit }
            finally { $bmp.Dispose() }
        }
    }
    finally {
        $writer.Dispose()
    }
    $convertedCount++
    Write-Host "$base.{$(($frames | ForEach-Object { $_.Idx }) -join ',')} -> $base.mem ($($frames.Count) frames, $fmt)"
}

# Object atlas: concatenate the object sprites (RGB323) in type order 0..6 into a
# single .mem so obj_layer can read them from one ROM addressed by {type, y, x}.
if ($ObjAtlas.Count -gt 0) {
    $atlasPath = Join-Path $OutputPath $ObjAtlasFile
    $writer = [System.IO.StreamWriter]::new($atlasPath, $false, [System.Text.Encoding]::ASCII)
    try {
        # Every slot in the atlas is the same 32x32 size, so obj_layer can find a
        # sprite by just gluing address bits together ({is_boss, y, x}) instead of
        # multiplying by a row width. Art smaller than the slot (the boss is 24x24)
        # goes in the top-left corner and the rest of the slot stays transparent;
        # obj_layer never reads those spare rows and columns.
        $slotSize = 32
        foreach ($base in $ObjAtlas) {
            $png = $singles | Where-Object { $_.BaseName -eq $base } | Select-Object -First 1
            if (-not $png) { throw "Atlas member PNG not found in ${InputPath}: $base.png" }
            $bmp = Load-Sprite $png.FullName $base
            if ($bmp.Width -ne $slotSize -or $bmp.Height -ne $slotSize) {
                $slot = New-Object System.Drawing.Bitmap($slotSize, $slotSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $g = [System.Drawing.Graphics]::FromImage($slot)
                $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                $g.Clear([System.Drawing.Color]::Transparent)
                $g.DrawImageUnscaled($bmp, 0, 0)
                $g.Dispose()
                $bmp.Dispose()
                $bmp = $slot
            }
            try { Write-Pixels $bmp $writer $true } finally { $bmp.Dispose() }
        }
    }
    finally {
        $writer.Dispose()
    }
    $convertedCount++
    Write-Host "$($ObjAtlas -join ',') -> $ObjAtlasFile ($($ObjAtlas.Count) sprites, RGB323 atlas)"
}

Write-Host "Converted $convertedCount item(s)."
Write-Host "Input dir : $InputPath"
Write-Host "Output dir: $OutputPath"
