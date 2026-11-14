param(
    [string]$AdbPath = "adb.exe",
    [string]$WslDistro = "Ubuntu",
    [string]$WslImgPath = "~/work/out/ios16-root.img",
    [string]$WslChunkPath = "~/work/out/chunk.bin",
    [int]$TotalGiB = 16
)

$ErrorActionPreference = "Stop"
$wslHome = (wsl -d $WslDistro -- bash -c 'printf "%s" "$HOME"').Trim()
$imgExpanded = $WslImgPath -replace '^~', $wslHome
$chunkExpanded = $WslChunkPath -replace '^~', $wslHome
$winChunk = "\\wsl.localhost\$WslDistro" + ($chunkExpanded -replace '/', '\')

Write-Output "Unmounting /sdcard and /data..."
& $AdbPath shell "umount /sdcard 2>/dev/null; umount /data 2>/dev/null; mount | grep -E 'sda18|userdata' || echo UNMOUNT_OK"

for ($i = 0; $i -lt $TotalGiB; $i++) {
    $seek = $i * 1024
    Write-Output "=== Chunk $i/$($TotalGiB - 1) (offset ${seek}M) ==="
    $srcMd5 = (wsl -d $WslDistro -- bash -c "dd if='$imgExpanded' of='$chunkExpanded' bs=1M skip=$seek count=1024 status=none && md5sum '$chunkExpanded' | cut -d' ' -f1").Trim()
    Write-Output "WSL MD5: $srcMd5"
    & $AdbPath push $winChunk /tmp/chunk.bin
    if ($LASTEXITCODE -ne 0) { throw "adb push failed on chunk $i" }
    $dstOut = & $AdbPath shell "dd if=/tmp/chunk.bin of=/dev/block/by-name/userdata bs=1M seek=$seek conv=notrunc 2>/dev/null && rm -f /tmp/chunk.bin && sync && dd if=/dev/block/by-name/userdata bs=1M skip=$seek count=1024 2>/dev/null | md5sum"
    $dstMd5 = ($dstOut -split '\s+')[0].Trim()
    Write-Output "DEV MD5: $dstMd5"
    if ($srcMd5 -ne $dstMd5) {
        throw "MD5 mismatch on chunk ${i}: $srcMd5 != $dstMd5"
    }
}
wsl -d $WslDistro -- rm -f "$chunkExpanded"
Write-Output "ALL $TotalGiB CHUNKS VERIFIED OK!"
