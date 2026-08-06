param(
    [string]$InputDir = "bitmap",
    [string]$ResFile  = "src\assets\res_font.mem"
)

# Packs the 6x12 ASCII glyphs in bitmap/*.txt into a 1-bit font ROM.
# Each glyph row becomes a 6-bit word (MSB = leftmost column, i.e. bit 5 =
# column 0), so the .mem hex reads left-to-right like the glyph. Each glyph is
# padded from 12 to 16 rows so the Verilog address can be {glyph, src_y} with
# no multiply.
#
# Output: res_font.mem, 32 glyph slots = 512 lines, shared by ui_layer (the
# timer, LEVEL and the streak count) and res_overlay (the game-over panel):
#   index 0-9   = digits (from bitmap/0..9.txt)
#   index 10    = space (blank)
#   index 11-23 = B C E I M O P R S T U L V
#   index 24-31 = blank padding

$COLS = 6
$ROWS = 12
$PADDED_ROWS = 16

$ROOT = Split-Path -Parent $PSScriptRoot

function Resolve-LocalPath {
    param([string]$PathValue)
    if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }
    return Join-Path $ROOT $PathValue
}

$InputPath = Resolve-LocalPath $InputDir
if (!(Test-Path $InputPath -PathType Container)) {
    throw "Input folder not found: $InputPath"
}

# glyph index -> source basename in bitmap/, or $null for a blank glyph
$resGlyphs = New-Object object[] 32
for ($i = 0; $i -lt 32; $i++) { $resGlyphs[$i] = $null }
foreach ($d in 0..9) { $resGlyphs[$d] = "$d" }
# Appended, never reordered: res_overlay and ui_layer hard-code these indices.
$letters = @('B','C','E','I','M','O','P','R','S','T','U','L','V')  # indices 11..23
for ($i = 0; $i -lt $letters.Count; $i++) { $resGlyphs[11 + $i] = $letters[$i] }

# Return the 16 packed hex words for one glyph (blank if $basename is $null).
function Pack-Glyph {
    param([string]$basename)

    $lines = @()
    if ($basename) {
        $p = Join-Path $InputPath ("{0}.txt" -f $basename)
        if (!(Test-Path $p -PathType Leaf)) { throw "Missing glyph file: $p" }
        $lines = @(Get-Content -Path $p)
    }

    $words = New-Object string[] $PADDED_ROWS
    for ($r = 0; $r -lt $PADDED_ROWS; $r++) {
        $word = 0
        if ($r -lt $ROWS -and $r -lt $lines.Count) {
            $line = $lines[$r]
            for ($c = 0; $c -lt $COLS; $c++) {
                if ($c -lt $line.Length -and $line[$c] -eq '#') {
                    $word = $word -bor (1 -shl ($COLS - 1 - $c))
                }
            }
        }
        $words[$r] = "{0:X2}" -f $word
    }
    return ,$words
}

function Write-Mem {
    param([string]$outPath, [object[]]$glyphs)

    $full = Resolve-LocalPath $outPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
    $writer = [System.IO.StreamWriter]::new($full, $false, [System.Text.Encoding]::ASCII)
    try {
        foreach ($g in $glyphs) {
            foreach ($w in (Pack-Glyph $g)) { $writer.WriteLine($w) }
        }
    } finally {
        $writer.Dispose()
    }
    Write-Host "Wrote $full ($($glyphs.Count * $PADDED_ROWS) lines)."
}

# The one font: 32 glyph slots, shared by ui_layer and res_overlay.
Write-Mem $ResFile $resGlyphs
