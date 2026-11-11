# Points pdfium_flutter's .lib/latest at the downloaded release directory.
# A directory junction does not need Developer Mode or an elevated process.
# Symbolic links (CMake file(CREATE_LINK)) do, and fail on this machine.
param(
    [Parameter(Mandatory = $true)][string]$Link,
    [Parameter(Mandatory = $true)][string]$Target
)

$ErrorActionPreference = "Stop"

function Remove-LinkPath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        # Non-recursive delete unlinks a junction and does not follow it.
        [System.IO.Directory]::Delete($item.FullName)
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

if (-not (Test-Path -LiteralPath $Target)) {
    Write-Error "PDFium lib directory does not exist: $Target"
}

Remove-LinkPath $Link

try {
    New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
    exit 0
} catch {
    Write-Host "Junction failed ($($_.Exception.Message)); copying PDFium libs instead."
    if (Test-Path -LiteralPath $Link) {
        Remove-LinkPath $Link
    }
    New-Item -ItemType Directory -Path $Link | Out-Null
    Get-ChildItem -LiteralPath $Target -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Link $_.Name) -Recurse -Force
    }
    exit 0
}
