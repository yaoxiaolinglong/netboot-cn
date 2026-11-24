#!/usr/bin/env bash
#
# 把安装内核缓存到 U 盘，并注入无线固件
#
# 为什么需要这个：
#   1. GRUB 引导阶段认不出无线网卡 —— 把内核放本地，启动就不需要网线
#   2. Debian 官方 netboot 的 initrd 不含 non-free 无线固件
#      （实测 iwlwifi.ko 有，*.ucode 是 0 个）—— 把固件注入进去，
#      安装器里就能用 WiFi 联网装包
#
# 用法:
#   ./scripts/fetch-images.sh              # 全部
#   ./scripts/fetch-images.sh debian       # 只做 Debian
#   ./scripts/fetch-images.sh --no-firmware
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/images"
CACHE="$ROOT/build/cache"
TUNA="http://mirrors.tuna.tsinghua.edu.cn"
DEB_MIRROR="http://deb.debian.org/debian"

# 注入哪些固件包（按需增减，越大 initrd 越大）
FW_PACKAGES=(
  firmware-iwlwifi     # Intel 无线（最常见的笔记本网卡）
  firmware-realtek     # Realtek
  firmware-mediatek    # 联发科
)

WITH_FIRMWARE=1
TARGETS=()
for a in "$@"; do
  case "$a" in
    --no-firmware) WITH_FIRMWARE=0 ;;
    *) TARGETS+=("$a") ;;
  esac
done
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(debian alpine centos)

need() { command -v "$1" >/dev/null || { echo "缺少依赖: $1" >&2; exit 1; }; }
need curl; need cpio; need gzip; need dpkg-deb

mkdir -p "$OUT" "$CACHE"

fetch() {  # fetch <url> <output>
  if [ -f "$2" ]; then echo "  已缓存 $(basename "$2")"; return 0; fi
  echo "  下载 $(basename "$2")"
  curl -fsSL --connect-timeout 20 --retry 3 -o "$2" "$1"
}

# ── 无线固件 ────────────────────────────────────────
prepare_firmware() {
  local fwdir="$CACHE/firmware"
  if [ -d "$fwdir" ] && [ -n "$(find "$fwdir" -name '*.ucode' -print -quit 2>/dev/null)" ]; then
    echo "  固件已解包，跳过"
    return 0
  fi
  mkdir -p "$fwdir"
  for pkg in "${FW_PACKAGES[@]}"; do
    local fn
    fn="$(curl -s "$DEB_MIRROR/dists/stable/non-free-firmware/binary-amd64/Packages.gz" \
          | zcat | awk -v P="$pkg" '$0=="Package: "P{f=1} f&&/^Filename:/{print $2; exit}')"
    [ -n "$fn" ] || { echo "  跳过 $pkg（索引里找不到）"; continue; }
    local deb="$CACHE/$(basename "$fn")"
    fetch "$DEB_MIRROR/$fn" "$deb"
    echo "  解包 $(basename "$deb")"
    dpkg-deb -x "$deb" "$fwdir"
  done
  echo "  共 $(find "$fwdir" -name '*.ucode' | wc -l) 个 .ucode"
}

# ── 给 initrd 注入固件 ──────────────────────────────
# inject_firmware <源initrd> <输出initrd> <固件根目录>
inject_firmware() {
  local src="$1" dst="$2" fwroot="$3"
  local work
  work="$(mktemp -d)"
  # 不用 trap RETURN：local 变量在返回后已失效，trap 会报「未绑定的变量」
  # 所以每个出口都显式清理

  echo "  解包 initrd ..."
  # cpio 遇到尾部填充会返回 2，但解包本身是成功的 —— 不能让它中断脚本
  ( cd "$work" && zcat "$src" | cpio -idm --quiet 2>/dev/null || true )
  local nfiles
  nfiles="$(find "$work" -type f | wc -l)"
  [ "$nfiles" -gt 100 ] || { echo "  错误: 解包只得到 $nfiles 个文件" >&2; rm -rf "$work"; return 1; }

  local fwsrc
  fwsrc="$(find "$fwroot" -type d -name firmware -path '*lib/firmware' | head -1)"
  if [ -z "$fwsrc" ]; then
    echo "  警告: 固件目录没找到，跳过注入"
    cp "$src" "$dst"; rm -rf "$work"; return 0
  fi

  # Debian 的 initrd 里固件路径是 /usr/lib/firmware
  mkdir -p "$work/usr/lib/firmware"
  cp -a "$fwsrc"/. "$work/usr/lib/firmware"/ 2>/dev/null || true

  local n
  n="$(find "$work/usr/lib/firmware" -name '*.ucode' | wc -l)"
  echo "  注入 $n 个固件"

  ( cd "$work" && find . -print0 | cpio --null -o --format=newc --owner=0:0 2>/dev/null | gzip -9 ) > "$dst" || true
  rm -rf "$work"

  # 验证产物：能解开、固件在里面
  gzip -t "$dst" || { echo "  错误: 打包后的 initrd 损坏" >&2; return 1; }
  local got
  got="$(zcat "$dst" | cpio -t --quiet 2>/dev/null | grep -c '\.ucode$' || true)"
  echo "  校验: 产物内含 $got 个 .ucode"
  [ "${got:-0}" -gt 0 ] || { echo "  错误: 固件没有进到 initrd 里" >&2; return 1; }
}

# ── Debian ─────────────────────────────────────────
build_debian() {
  echo "[debian]"
  local d="$OUT/debian" pfx
  pfx="$TUNA/debian/dists/stable/main/installer-amd64/current/images/netboot/debian-installer/amd64"
  mkdir -p "$d"
  fetch "$pfx/linux"     "$d/linux"
  fetch "$pfx/initrd.gz" "$CACHE/debian-initrd.gz"

  if [ "$WITH_FIRMWARE" -eq 1 ]; then
    prepare_firmware
    inject_firmware "$CACHE/debian-initrd.gz" "$d/initrd.gz" "$CACHE/firmware"
  else
    cp "$CACHE/debian-initrd.gz" "$d/initrd.gz"
  fi
  printf '  完成: linux %s / initrd %s\n' \
    "$(du -h "$d/linux" | cut -f1)" "$(du -h "$d/initrd.gz" | cut -f1)"
}

# ── Alpine ─────────────────────────────────────────
build_alpine() {
  echo "[alpine]"
  local d="$OUT/alpine" pfx
  pfx="$TUNA/alpine/latest-stable/releases/x86_64/netboot"
  mkdir -p "$d"
  fetch "$pfx/vmlinuz-lts"   "$d/linux"
  fetch "$pfx/initramfs-lts" "$d/initrd.gz"
  printf '  完成: linux %s / initrd %s\n' \
    "$(du -h "$d/linux" | cut -f1)" "$(du -h "$d/initrd.gz" | cut -f1)"
}

# ── CentOS Stream ──────────────────────────────────
build_centos() {
  echo "[centos]"
  local d="$OUT/centos" pfx
  pfx="$TUNA/centos-stream/10-stream/BaseOS/x86_64/os/images/pxeboot"
  mkdir -p "$d"
  fetch "$pfx/vmlinuz"    "$d/linux"
  fetch "$pfx/initrd.img" "$d/initrd.gz"
  printf '  完成: linux %s / initrd %s\n' \
    "$(du -h "$d/linux" | cut -f1)" "$(du -h "$d/initrd.gz" | cut -f1)"
}

echo "输出目录: $OUT"
echo "无线固件注入: $([ "$WITH_FIRMWARE" -eq 1 ] && echo 开启 || echo 关闭)"
echo

for t in "${TARGETS[@]}"; do
  case "$t" in
    debian) build_debian ;;
    alpine) build_alpine ;;
    centos) build_centos ;;
    *) echo "未知目标: $t（可选 debian alpine centos）" >&2 ;;
  esac
done

echo
echo "总计: $(du -sh "$OUT" | cut -f1)"
echo
echo "下一步: sudo ./install-usb.sh /dev/sdX　会把 images/ 一起写进U盘"
