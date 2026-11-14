param(
    [string]$AdbPath = "adb.exe",
    [string]$WslDistro = "Ubuntu",
    [string]$OutTxt = "klog.txt"
)

$ErrorActionPreference = "Stop"
$bytesStr = (& $AdbPath shell "blockdev --getsize64 /dev/block/by-name/userdata").Trim()
$bytes = [int64]$bytesStr
$skip = [int64]($bytes / 4096) - 1025
Write-Output "userdata=$bytes bytes, pulling 1025 4K blocks from skip=$skip..."

& $AdbPath shell "dd if=/dev/block/by-name/userdata of=/tmp/klog.bin bs=4096 skip=$skip count=1025"
& $AdbPath pull /tmp/klog.bin "$env:TEMP\klog.bin"

$wslTemp = (wsl -d $WslDistro -- wslpath -u "$env:TEMP\klog.bin").Trim()
wsl -d $WslDistro -- python3 -c "
import subprocess, sys
data = open('$wslTemp', 'rb').read()
idx = data.find(b'SWEETLOG')
print('SWEETLOG offset:', idx)
if idx < 0:
    sys.exit(1)
open('/tmp/klog_slice.bin', 'wb').write(data[idx:])
out = subprocess.check_output(['python3', '/home/' + __import__('os').environ['USER'] + '/ios-sapphire/tools/sweet-log.py', '/tmp/klog_slice.bin'], text=True, errors='replace')
print('Lines:', len(out.splitlines()))
open('/tmp/klog_decoded.txt', 'w').write(out)
"
Copy-Item "\\wsl.localhost\$WslDistro\tmp\klog_decoded.txt" $OutTxt -Force
Write-Output "Saved decoded log to $OutTxt"
