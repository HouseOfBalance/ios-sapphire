# Hướng dẫn Build & Boot iOS 16 cho Xiaomi Redmi Note 13 4G (`sapphire`) trên Windows + WSL2 Ubuntu

Tài liệu này tổng hợp toàn bộ quy trình từ đầu đến cuối đã được kiểm chứng thực tế trên máy **Xiaomi Redmi Note 13 4G (`sapphire`, Snapdragon 685 / SM6225)**, sử dụng **Windows + WSL2 Ubuntu**.

---

## 0. Các nguyên tắc sống còn (Đọc kỹ trước khi chạy)

1. **KHÔNG BAO GIỜ chạy `fastboot flash boot ...`!**
   Luôn boot tạm bằng `fastboot boot <boot.img>` để giữ nguyên kernel/recovery Android gốc trên máy.
2. **KHÔNG pipe dữ liệu nhị phân qua `adb.exe shell` trên Windows!**
   `adb.exe shell` trên Windows làm hỏng dữ liệu nhị phân qua stdin. Luôn `adb push` từng chunk ra `/tmp/` rồi `dd` trực tiếp trên máy và kiểm tra `md5sum`.
3. **MỌI binary & `.dylib` tự build đều PHẢI ký `ldid -S`!**
   Kernel `sweet` dùng `sweet_amfi.c` để đánh dấu *platform binary* thông qua `vnode_check_signature`. Nếu binary thiếu chữ ký ad-hoc (`ldid -S`), `launchd` sẽ panic ngay khi khởi chạy với lỗi:
   `userspace panic: unexpected exec of non-platform binary: /redwood/bin/bbstart`
4. **Không nên để `sweetbl=1` khi chưa có userland hoàn chỉnh:**
   Patch `0209` bật `sweetbl=1` mặc định làm tối màn hình khi không có userland điều khiển độ sáng. Nếu test màn hình console/lần đầu, thêm `sweetbl=0 sweet_splash=0`.

---

## 1. Chuẩn bị môi trường

### 1.1. Trên Windows
- Cài **Android Platform Tools** (`adb.exe`, `fastboot.exe`).
- Điện thoại đã unlock bootloader, cài **OrangeFox Recovery** (hoặc TWRP có `adb` root).
- Bật WSL2 Ubuntu (`wsl --install -d Ubuntu`).

### 1.2. Trong WSL2 Ubuntu
Cài các gói cần thiết để biên dịch userland, Mesa, `ldid` và xử lý HFS+:
```bash
sudo apt-get update
sudo apt-get install -y \
  clang-18 lld-18 llvm-18 \
  meson ninja-build bison flex zstd \
  build-essential git python3 python3-pip \
  hfsprogs libplist-dev libssl-dev unzip curl wget
```

Clone repo và SDK:
```bash
git clone -b sapphire https://github.com/HouseOfBalance/ios-sapphire.git ~/ios-sapphire
mkdir -p ~/work/sdks ~/tools-dl
git clone --depth=1 https://github.com/theos/sdks.git ~/work/sdks/theos-sdks
```

Build `ldid` (bắt buộc để ký binary Mach-O):
```bash
git clone --depth=1 https://github.com/ProcursusTeam/ldid.git ~/tools-dl/ldid
make -C ~/tools-dl/ldid -j$(nproc)
```

> **Lưu ý về `hfsplus.ko` trong WSL2:**
> Kernel WSL2 mặc định không bật module `hfsplus`. Cần build hoặc đặt `hfsplus.ko` khớp với `uname -r` của WSL2 tại `~/modules/hfsplus.ko` (dùng để mount/format ảnh `ios16-root.img`).

---

## 2. Backup phân vùng quan trọng & trích xuất Firmware từ điện thoại

Đưa điện thoại vào **OrangeFox Recovery**, chạy qua `adb`:

### 2.1. Backup phân vùng hiệu chuẩn & boot gốc (giữ an toàn tuyệt đối, KHÔNG push lên GitHub)
```powershell
mkdir backup
foreach ($p in @("persist","modemst1","modemst2","fsg","fsc","boot_a","dtbo_a","vbmeta_a")) {
    adb shell "dd if=/dev/block/by-name/$p of=/tmp/$p.img"
    adb pull "/tmp/$p.img" ".\backup\$p.img"
    adb shell "rm -f /tmp/$p.img"
}
```

### 2.2. Trích xuất GPU & IPA firmware từ `vendor_a`
Mount `vendor_a` trong Recovery (read-only) rồi kéo các file firmware vào `~/work/gpu-fw/`:
- `a610_zap.*`
- `a630_sqe.fw`
- `ipa_fws.*`

```powershell
adb shell "mkdir -p /tmp/v && mount -o ro /dev/block/mapper/vendor_a /tmp/v"
mkdir gpu-fw
# Kéo toàn bộ a610_zap.*, a630_sqe.fw, ipa_fws.* từ /tmp/v/firmware/ về .\gpu-fw\
adb shell "umount /tmp/v"
```
Copy sang WSL vào `~/work/gpu-fw/`.

---

## 3. Tải Kernel XNU (`kernel.development.sweet`) & IPSW iPhone X 16.7.16

1. **Kernel**: Tải artifact `xnu-kernel` (`kernel.development.sweet`) từ GitHub Actions (hoặc build từ `xnu/`) và đặt vào:
   `~/ios-sapphire/xnu/out/kernel.development.sweet`
2. **IPSW**: Tải IPSW **iPhone X (iPhone10,6 / d22ap) iOS 16.7.16 (`20H392`)** về `~/work/iPhoneX_16.7.16_20H392.ipsw`.

---

## 4. Build RootFS (`ios16-root.img` — 16 GiB)

Chạy script trong WSL:
```bash
bash ~/ios-sapphire/tools/windows-wsl/build_root.sh ~/work/iPhoneX_16.7.16_20H392.ipsw
```
Script này sẽ:
- Giải nén `d22ap.adt` vào `~/ios-sapphire/research/ipsw-x/d22ap.adt`
- Giải nén 3 file `.dmg` từ IPSW
- Gọi `tools/sapphire-root.sh` để tạo `~/work/out/ios16-root.img` (16 GiB HFS+).

---

## 5. Build Userland & Cài vào `ios16-root.img`

### 5.1. Build toàn bộ userland
```bash
bash ~/ios-sapphire/tools/windows-wsl/build_userland.sh
```
Bao gồm:
- `SapphireMetal.bundle` (Metal driver cho Adreno 610)
- `RedwoodAudio.driver` (HAL audio driver)
- `telephony` (`qmitool`, `ccbridge.dylib`, `ccstart`, `pdpnet`, `ctdial`, `libsapphire-fakebb.dylib`, `bbstart`)
- Mesa 25.0.7 (`libOSMesa.8.dylib` softpipe + freedreno)
- EAGL bridge (`libredwood-gl.dylib`, `libredwood-glload.dylib`)
- Procursus rootless + Sileo + ElleKit + OpenSSH (`~/work/jb-build/root/var/jb`)

*(Sau bước này có thể xóa `~/work/mesa-ios/build-softpipe-freedreno`, `~/work/mesa-ios/mesa-25.0.7*` và `~/work/iPhoneX_*.ipsw` để tiết kiệm dung lượng.)*

### 5.2. Ký `ldid -S`, cài userland vào `ios16-root.img` và kiểm tra `fsck.hfsplus`
```bash
bash ~/ios-sapphire/tools/windows-wsl/install_userland_to_img.sh
```
Script này tự động:
- Build `rtcd`
- Chạy `ldid -S` (và kèm entitlement cho `rtcd`, `ctdial`) trên **toàn bộ** binary & `.dylib`
- Tạo cặp khóa SSH `~/.ssh/sapphire_phone`
- Mount `ios16-root.img`, copy `/redwood`, `SapphireMetal.bundle`, `RedwoodAudio.driver`, `/private/var/jb`, cấu hình `sshd` (cổng 22 & 2222) và cập nhật `/System/Library/xpc/launchd.plist`
- Chạy `fsck.hfsplus -f -y` xác nhận `The volume iOSRoot appears to be OK`.

---

## 6. Build Boot Image (`sapphire-boot-full.img`)

Trong WSL:
```bash
cd ~/ios-sapphire
./tools/sapphire-boot.sh \
  --gpu-fw ~/work/gpu-fw \
  --ipa-fw ~/work/gpu-fw \
  --console \
  --extra "sweetusb=2 gpu=3 gpu_delay=20 gpu_mmu=1 gpu_service=1 sweetfb_gpucopy=1 sweetmetal=1 sweetgl=1 modem=1 wifi=1 audio=2 gpu_div=1 sweetfb_direct=0 gpu_mhz=1260 glwait=0 ipa=1 sweetbl=0 sweet_glload=1 sweet_splash=0" \
  -o ~/work/out/sapphire-boot-full.img
```
Copy `~/work/out/sapphire-boot-full.img` sang Windows để dùng với `fastboot.exe`.

---

## 7. Nạp `ios16-root.img` lên điện thoại & Boot iOS 16

1. Đưa điện thoại vào **OrangeFox Recovery** (`adb devices` thấy `recovery`).
2. Chạy script PowerShell trên Windows để đẩy 16 chunk × 1 GiB vào `/dev/block/by-name/userdata` và đối chiếu MD5 từng chunk:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\tools\windows-wsl\push_root.ps1 -AdbPath ".\platform-tools\adb.exe"
   ```
   Đợi thông báo: `ALL 16 CHUNKS VERIFIED OK!`
3. Khởi động lại vào Fastboot và boot iOS 16:
   ```powershell
   .\platform-tools\adb.exe reboot bootloader
   .\platform-tools\fastboot.exe boot .\sapphire-boot-full.img
   ```
4. Lần boot đầu mất khoảng **3–5 phút** (rebuild LaunchServices DB + `gpu_delay=20`).
   Các lần sau muốn vào lại iOS từ Android/Recovery: giữ **Nguồn + Giảm âm lượng** vào Fastboot rồi chạy lại `fastboot boot sapphire-boot-full.img`.

---

## 8. Debug & Thu hồi dung lượng WSL2

### 8.1. Kéo kernel log (`SWEETLOG`) khi boot lỗi / panic
Đưa máy về Recovery và chạy:
```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows-wsl\pull_klog.ps1 -AdbPath ".\platform-tools\adb.exe" -OutTxt .\klog.txt
```
Log được lưu ở cuối `userdata` (magic `SWEETLOG`) và tự động giải mã bằng `tools/sweet-log.py`.

### 8.2. Thu hồi dung lượng ổ `C:` sau khi xóa file build trong WSL2
1. Xóa file nặng trong WSL (`~/work/out`, `~/work/jb-build`, `~/work/sdks`, `~/work/mesa-ios`, `~/work/ipsw`) và chạy `sudo fstrim -av`.
2. Chạy `wsl --shutdown`.
3. Mở **PowerShell (Run as Administrator)** và thu gọn `ext4.vhdx`:
   ```powershell
   wsl --shutdown
   @"
   select vdisk file="$env:LOCALAPPDATA\Packages\CanonicalGroupLimited.Ubuntu_79rhkp1fndgsc\LocalState\ext4.vhdx"
   attach vdisk readonly
   compact vdisk
   detach vdisk
   exit
   "@ | diskpart
   ```
