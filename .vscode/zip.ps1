$ROOT = Split-Path -Parent $PSScriptRoot
$PROJECT_NAME = Split-Path -Leaf $ROOT
$TIMESTAMP = Get-Date -Format "yyyyMMdd_HHmmss"
$DESKTOP = [Environment]::GetFolderPath('Desktop')
$ZIP_PATH = Join-Path $DESKTOP "$PROJECT_NAME`_$TIMESTAMP.zip"
$TEMP_ROOT = Join-Path ([System.IO.Path]::GetTempPath()) "$PROJECT_NAME`_$TIMESTAMP"
$STAGE_DIR = Join-Path $TEMP_ROOT $PROJECT_NAME
# impl/ is the Gowin build output: megabytes of generated files that get rebuilt
# from source anyway, so it does not belong in a hand-in zip.
$EXCLUDED_ROOT_ITEMS = @(".git", ".gitignore", "impl")

if (Test-Path $TEMP_ROOT) {
    Remove-Item -LiteralPath $TEMP_ROOT -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $STAGE_DIR | Out-Null

try {
    Get-ChildItem -LiteralPath $ROOT -Force |
        Where-Object { $EXCLUDED_ROOT_ITEMS -notcontains $_.Name } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $STAGE_DIR -Recurse -Force
        }

    if (Test-Path $ZIP_PATH) {
        Remove-Item -LiteralPath $ZIP_PATH -Force
    }

    Compress-Archive -LiteralPath $STAGE_DIR -DestinationPath $ZIP_PATH -Force

    Write-Host "Created zip: $ZIP_PATH"
}
finally {
    if (Test-Path $TEMP_ROOT) {
        Remove-Item -LiteralPath $TEMP_ROOT -Recurse -Force
    }
}
