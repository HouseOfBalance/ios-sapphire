import subprocess
import os
import sys

ADB = r"C:\Users\TRAN VAN HUNG\.gemini\antigravity\scratch\ios-sapphire\platform-tools\adb.exe"

def run_cmd(cmd):
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
    return res.stdout.strip()

print("Getting device block...")
dev = run_cmd([ADB, "shell", "for d in /dev/block/by-name/iosroot /dev/block/by-name/userdata /dev/block/bootdevice/by-name/userdata; do [ -e $d ] && readlink -f $d && break; done"])
print(f"Device: {dev}")

size_str = run_cmd([ADB, "shell", f"blockdev --getsize64 {dev}"])
bytes_total = int(size_str)
print(f"Bytes: {bytes_total}")

skip = (bytes_total // 4096) - 1025
print(f"Skip: {skip}")

bin_path = os.path.join(os.path.dirname(__file__), "..", "klog_current.bin")
txt_path = os.path.join(os.path.dirname(__file__), "..", "klog_current.txt")

with open(bin_path, "wb") as f:
    subprocess.run([ADB, "exec-out", f"dd if={dev} bs=4096 skip={skip} count=1025 2>/dev/null"], stdout=f, check=True)

print(f"Saved {bin_path} ({os.path.getsize(bin_path)} bytes)")

# Decode with sweet-log.py
sweet_log = os.path.join(os.path.dirname(__file__), "sweet-log.py")
subprocess.run([sys.executable, sweet_log, bin_path, txt_path], check=True)

with open(txt_path, "r", encoding="utf-8", errors="replace") as f:
    lines = f.readlines()

print(f"Decoded {len(lines)} lines of log. Last 60 lines:")
for l in lines[-60:]:
    print(l, end="")
