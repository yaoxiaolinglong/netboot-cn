#!/usr/bin/env bash
#
# 构建中文 GRUB 网络启动 EFI
#
# 用法:
#   ./build.sh                    # 构建到 dist/BOOTX64.EFI
#   ./install-usb.sh /dev/sdX     # 构建并写入U盘（会清空该盘！）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
BUILD="$ROOT/build"
DIST="$ROOT/dist"

GRUB_CFG="$SRC/grub.cfg"
EFI_OUT="$DIST/BOOTX64.EFI"

# 中文字体候选（按优先级）
CN_FONT_CANDIDATES=(
  /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc
  /usr/share/fonts/truetype/wqy/wqy-microhei.ttc
  /usr/share/fonts/truetype/wqy/wqy-zenhei.ttc
  /usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf
)
ASCII_FONT_CANDIDATES=(
  /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
  /usr/share/fonts/truetype/noto/NotoSans-Regular.ttf
  /usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf
)

MODULES="normal linux chain reboot halt search search_fs_file search_fs_uuid \
search_label font gfxterm all_video video video_fb efi_gop part_msdos part_gpt \
fat echo test terminal minicmd configfile png net efinet http tftp"

# ── 检查依赖 ───────────────────────────────────────
need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少依赖: $1" >&2; exit 1; }; }
need grub-mkstandalone
need grub-mkfont
[ -d /usr/lib/grub/x86_64-efi ] || { echo "缺少 GRUB EFI 模块目录 /usr/lib/grub/x86_64-efi" >&2; exit 1; }

pick_font() {
  for f in "$@"; do [ -f "$f" ] && { echo "$f"; return 0; }; done
  return 1
}

CN_FONT="$(pick_font "${CN_FONT_CANDIDATES[@]}")" || { echo "找不到中文字体，请安装 fonts-noto-cjk" >&2; exit 1; }
ASCII_FONT="$(pick_font "${ASCII_FONT_CANDIDATES[@]}")" || { echo "找不到拉丁字体，请安装 fonts-dejavu-core" >&2; exit 1; }

echo "中文字体: $CN_FONT"
echo "拉丁字体: $ASCII_FONT"

rm -rf "$BUILD" && mkdir -p "$BUILD/fonts" "$DIST"

# ── 从菜单里提取用到的汉字，只生成这些字形 ─────────
echo "[1/4] 统计菜单字符集"
python3 - "$GRUB_CFG" "$BUILD/charset.txt" "$BUILD/ranges.txt" <<'PY'
import sys
cfg, charset_out, ranges_out = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(cfg, encoding='utf-8').read()
chars = sorted({c for c in text if ord(c) > 0x7e and c not in '\n\r\t'})
open(charset_out, 'w', encoding='utf-8').write("".join(chars))
cps = sorted({ord(c) for c in chars})
if not cps:
    open(ranges_out, 'w').write("")
    print("  无中文，跳过")
    sys.exit(0)
groups = []
start = prev = cps[0]
for c in cps[1:]:
    if c == prev + 1:
        prev = c
    else:
        groups.append((start, prev)); start = prev = c
groups.append((start, prev))
open(ranges_out, 'w').write(",".join(f"0x{a:x}-0x{b:x}" for a, b in groups))
print(f"  {len(chars)} 个非 ASCII 字形，压缩为 {len(groups)} 个区间")
PY

# ── 生成字库 ───────────────────────────────────────
echo "[2/4] 生成字库"
RANGES="$(cat "$BUILD/ranges.txt")"
FONT_ARGS=(-s 20 -n "CN")
if [ -n "$RANGES" ]; then FONT_ARGS+=(--range="$RANGES"); fi
# .ttc 需要指定索引，SC 简体通常是 2；.ttf 不需要
if [[ "$CN_FONT" == *.ttc ]]; then FONT_ARGS+=(-i 2); fi
grub-mkfont -v "${FONT_ARGS[@]}" -o "$BUILD/fonts/cn.pf2" "$CN_FONT" 2>&1 | grep -i "number of glyph" || true

grub-mkfont -v -s 20 -n "ASCII" --range="0x20-0x7e" \
  -o "$BUILD/fonts/ascii.pf2" "$ASCII_FONT" 2>&1 | grep -i "number of glyph" || true

# ── 打包 EFI ───────────────────────────────────────
echo "[3/4] 打包 EFI"
grub-mkstandalone -O x86_64-efi -o "$EFI_OUT" \
  --modules="$MODULES" \
  --fonts="" --locales="" --themes="" \
  "boot/grub/grub.cfg=$GRUB_CFG" \
  "boot/grub/fonts/cn.pf2=$BUILD/fonts/cn.pf2" \
  "boot/grub/fonts/ascii.pf2=$BUILD/fonts/ascii.pf2"

# ── 校验 ───────────────────────────────────────────
echo "[4/4] 校验"
python3 - "$EFI_OUT" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
checks = {
    'grub.cfg 内嵌': b'grub.cfg' in data,
    '中文字库内嵌': b'cn.pf2' in data,
    '拉丁字库内嵌': b'ascii.pf2' in data,
    '中文菜单文本': '网络安装'.encode() in data,
}
for k, v in checks.items():
    print(f"  {'OK ' if v else 'FAIL'} {k}")
if not all(checks.values()):
    sys.exit(1)
print(f"  产物: {sys.argv[1]}  {len(data)/1048576:.2f} MB")
PY

echo
echo "构建完成: $EFI_OUT"
echo
echo "写入U盘（注意 /dev/sdX 必须是U盘，会全部清空）:"
echo "  sudo ./install-usb.sh /dev/sdX"
