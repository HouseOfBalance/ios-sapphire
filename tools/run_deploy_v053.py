import os
import sys
import time
import socket
import threading
import subprocess

ADB = r"C:\Users\TRAN VAN HUNG\.gemini\antigravity\scratch\ios-sapphire\platform-tools\adb.exe"
FASTBOOT = r"C:\Users\TRAN VAN HUNG\.gemini\antigravity\scratch\ios-sapphire\platform-tools\fastboot.exe"

print("=== Sapphire v0.5.3 Deployment Pipeline ===")

# 1. Check device status
res = subprocess.run([FASTBOOT, "devices"], capture_output=True, text=True)
if "fastboot" in res.stdout:
    print(f"Device in fastboot: {res.stdout.strip()}")
    print("Switching to slot a and rebooting to recovery...")
    subprocess.run([FASTBOOT, "set_active", "a"], check=True)
    subprocess.run([FASTBOOT, "reboot", "recovery"], check=True)
    print("Waiting 15s for OrangeFox Recovery to boot...")
    time.sleep(15)

# Wait for ADB
print("Waiting for ADB connection in recovery...")
for _ in range(30):
    res = subprocess.run([ADB, "devices"], capture_output=True, text=True)
    lines = [l for l in res.stdout.strip().split("\n") if "recovery" in l or "device" in l]
    if len(lines) > 1 or (len(lines) == 1 and not lines[0].startswith("List")):
        print(f"Device connected via ADB: {lines}")
        break
    time.sleep(2)
else:
    print("ERROR: Device not detected in ADB!")
    sys.exit(1)

# Check and copy nbd_server to device if needed
res = subprocess.run([ADB, "shell", "test -x /tmp/nbd_server && echo OK"], capture_output=True, text=True)
if "OK" not in res.stdout:
    print("Pushing nbd_server to device...")
    subprocess.run([ADB, "push", r"C:\Users\TRAN VAN HUNG\Downloads\ios-sapphire\tools\nbd_server", "/tmp/nbd_server"], check=True)
    subprocess.run([ADB, "shell", "chmod +x /tmp/nbd_server"], check=True)

print("[1] Ensuring nbd_server on device...")
res = subprocess.run([ADB, "shell", "ps -A | grep nbd_server | grep -v grep"], capture_output=True, text=True)
if "nbd_server" not in res.stdout:
    subprocess.run([ADB, "shell", "nohup /tmp/nbd_server /dev/block/by-name/iosroot > /tmp/nbd.log 2>&1 &"], capture_output=True)
    time.sleep(3)

res = subprocess.run([ADB, "shell", "ps -A | grep nbd_server | grep -v grep"], capture_output=True, text=True)
print(f"Device nbd_server: {res.stdout.strip()}")
if "nbd_server" not in res.stdout:
    print("ERROR: nbd_server failed to start on device!")
    res2 = subprocess.run([ADB, "shell", "cat /tmp/nbd.log"], capture_output=True, text=True)
    print(f"nbd.log: {res2.stdout}")
    sys.exit(1)

print("[2] Setting up ADB port forward 10809 -> 10809...")
res = subprocess.run([ADB, "forward", "tcp:10809", "tcp:10809"], capture_output=True, text=True)
print(f"ADB forward: {res.stdout.strip()}")

print("[3] Starting proxy 0.0.0.0:10810 -> 127.0.0.1:10809...")
stop_event = threading.Event()

def pipe(src, dst):
    try:
        while not stop_event.is_set():
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except:
        pass
    finally:
        try: src.close()
        except: pass
        try: dst.close()
        except: pass

def handle(client):
    try:
        upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        upstream.connect(('127.0.0.1', 10809))
        t1 = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
        t2 = threading.Thread(target=pipe, args=(upstream, client), daemon=True)
        t1.start()
        t2.start()
    except Exception as e:
        print(f"Proxy connect error: {e}")
        try: client.close()
        except: pass

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 10810))
srv.listen(5)

def srv_loop():
    while not stop_event.is_set():
        try:
            srv.settimeout(1.0)
            c, a = srv.accept()
            threading.Thread(target=handle, args=(c,), daemon=True).start()
        except socket.timeout:
            continue
        except:
            break

proxy_thread = threading.Thread(target=srv_loop, daemon=True)
proxy_thread.start()
print("Proxy active!")

print("[4] Executing WSL deployment script...")
wsl_cmd = ["wsl", "-u", "root", "bash", "/mnt/c/Users/TRAN VAN HUNG/Downloads/ios-sapphire/tools/apply_v053_deploy.sh"]
proc = subprocess.Popen(wsl_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
for line in iter(proc.stdout.readline, ''):
    print(line, end='', flush=True)
proc.stdout.close()
return_code = proc.wait()

print(f"\n[5] WSL script finished with exit code {return_code}")
stop_event.set()
try:
    srv.close()
except:
    pass

if return_code != 0:
    print("DEPLOYMENT FAILED!")
    sys.exit(return_code)

print("\n[5.5] Flashing freshly built sapphire-boot-053.img to boot_b...")
boot_img = r"C:\Users\TRAN VAN HUNG\Downloads\ios-sapphire\build_tmp\sapphire-boot-053.img"
if os.path.exists(boot_img):
    print("Pushing boot image to device...")
    subprocess.run([ADB, "push", boot_img, "/tmp/sapphire-boot-053.img"], check=True)
    print("Flashing to /dev/block/by-name/boot_b...")
    subprocess.run([ADB, "shell", "dd if=/tmp/sapphire-boot-053.img of=/dev/block/by-name/boot_b bs=4096 conv=fsync"], check=True)
    subprocess.run([ADB, "shell", "rm -f /tmp/sapphire-boot-053.img"])
    print("  ✓ Flashed boot_b successfully")

print("\n[6] Deployment successful! Switching back to Slot B (iOS) and rebooting...")
# Check if bootctl is available in recovery
res = subprocess.run([ADB, "shell", "bootctl set-active-boot-slot 1"], capture_output=True, text=True)
if res.returncode == 0:
    print("Switched to slot B via bootctl")
    subprocess.run([ADB, "reboot"], check=True)
    print("Rebooting to iOS!")
else:
    print("Rebooting to bootloader to switch slot...")
    subprocess.run([ADB, "reboot", "bootloader"], check=True)
    time.sleep(5)
    subprocess.run([FASTBOOT, "set_active", "b"], check=True)
    subprocess.run([FASTBOOT, "reboot"], check=True)
    print("Rebooted to iOS from fastboot!")

print("=== ALL DONE! iOS IS NOW BOOTING WITH v0.5.3 AND 4K KERNEL! ===")
