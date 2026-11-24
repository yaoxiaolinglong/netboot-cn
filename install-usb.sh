#!/usr/bin/env bash
#
# 把构建好的引导写入U盘
#
# 用法: sudo ./install-usb.sh /dev/sdX
#
# 警告：会清空目标设备全部分区。脚本会做多重检查，但仍然请你亲自确认设备名。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="${1:-}"
NETBOOT_URL="https://boot.netboot.xyz/ipxe/netboot.xyz.efi"
LABEL="NETBOOT"

die() { echo "错误: $*" >&2; exit 1; }

[ -n "$DEV" ] || die "用法: sudo $0 /dev/sdX"
[ "$(id -u)" -eq 0 ] || die "需要 root 权限"
[ -b "$DEV" ] || die "$DEV 不是块设备"

# ── 安全检查 1：不能是根分区所在的盘 ────────────────
ROOTDISK="$(lsblk -no pkname "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)"
[ -n "$ROOTDISK" ] && [ "/dev/$ROOTDISK" = "$DEV" ] && die "$DEV 是系统盘，拒绝操作"

# ── 安全检查 2：确认是U盘（可移动 或 USB 总线）────
TRAN="$(lsblk -no tran "$DEV" | head -1 | tr -d ' ')"
if [ "$TRAN" != "usb" ]; then
  echo "警告: $DEV 的总线类型是 '$TRAN'，不是 usb"
  read -r -p "确认继续吗？这将清空 $DEV 的全部数据 [yes/N] " ans
  [ "$ans" = "yes" ] || die "已取消"
fi

# ── 安全检查 3：二次人工确认 ───────────────────────
echo
lsblk -o NAME,SIZE,MODEL,TRAN "$DEV"
echo
read -r -p "上面这块盘将被完全清空，继续？[yes/N] " ans2
[ "$ans2" = "yes" ] || die "已取消"

# ── 构建（如果没有产物）───────────────────────────
[ -f "$ROOT/dist/BOOTX64.EFI" ] || "$ROOT/build.sh"

# ── 准备 netboot.xyz.efi ──────────────────────────
CACHE="$ROOT/build/netboot.xyz.efi"
if [ ! -f "$CACHE" ]; then
  echo "下载 netboot.xyz.efi ..."
  mkdir -p "$ROOT/build"
  curl -fsSL -o "$CACHE" "$NETBOOT_URL"
fi

# ── 卸载已有分区 ──────────────────────────────────
for p in $(lsblk -ln -o NAME "$DEV" | tail -n +2); do
  umount "/dev/$p" 2>/dev/null || true
done
sleep 1

# ── 分区 + 格式化 ─────────────────────────────────
echo "清空 $DEV ..."
wipefs -a "$DEV" >/dev/null

echo "建立 MBR + FAT32 分区 ..."
parted -s "$DEV" mklabel msdos
parted -s "$DEV" mkpart primary fat32 1MiB 100%
parted -s "$DEV" set 1 boot on
sleep 1
partprobe "$DEV" 2>/dev/null || true
sleep 2
mkfs.vfat -F 32 -n "$LABEL" "${DEV}1" >/dev/null

# ── 写入 ──────────────────────────────────────────
MNT="$(mktemp -d)"
trap 'umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT

mount "${DEV}1" "$MNT"
# 断言挂载正确，防止误写到本地磁盘
[ "$(findmnt -n -o SOURCE "$MNT")" = "${DEV}1" ] || die "挂载点校验失败"

mkdir -p "$MNT/EFI/BOOT"
cp "$ROOT/dist/BOOTX64.EFI"      "$MNT/EFI/BOOT/BOOTX64.EFI"
cp "$CACHE"                       "$MNT/netboot.xyz.efi"
[ -f "$ROOT/docs/使用说明.txt" ] && cp "$ROOT/docs/使用说明.txt" "$MNT/使用说明.txt"

# 本地缓存的内核（有就带上，没有就靠联网）
if [ -d "$ROOT/images" ] && [ -n "$(ls -A "$ROOT/images" 2>/dev/null)" ]; then
  echo "复制本地内核缓存 ..."
  cp -r "$ROOT/images" "$MNT/images"
else
  echo "提示: images/ 为空，启动时将联网下载内核（需要网线）"
  echo "      想做到全程无线，先跑 ./scripts/fetch-images.sh"
fi
sync

echo
echo "写入完成："
find "$MNT" -type f -printf "  %10s  %P\n" | sort -k2
umount "$MNT"
echo
echo "可以拔盘了。"
