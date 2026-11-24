# netboot-cn — 中文网络启动盘

一个**全中文菜单**的 UEFI 网络启动盘。插上电脑、选个系统，**当场联网装**，U 盘里不存任何系统镜像。

基于 [netboot.xyz](https://netboot.xyz) 的思路，但把菜单层换成了自己编译的 GRUB——因为 netboot.xyz 用的 iPXE 引擎**物理上无法显示中文**（下面有证据）。

```
┌──────────────────────────────────────────────────────┐
│  ① Debian 13 · 清华源 · 简体中文安装器                │
│  ② Debian 13 · 中科大源 · 简体中文安装器              │
│  ③ Alpine Linux · 超轻量 · 命令行安装（英文）         │
│  ④ CentOS Stream 10 · 英文安装器（首次加载较慢）      │
│  ⑤ 安装 Windows · 需自备 ISO 的 HTTP 地址             │
│  ⑥ netboot.xyz · 90+ 系统 · 英文菜单                  │
│  ⑦ 从本地硬盘启动                                     │
│  ⑧ 重启                                               │
└──────────────────────────────────────────────────────┘
```

## 它解决什么问题

普通装机盘要把几个 G 的 ISO 写进 U 盘，一个盘顶多放三四个系统。

这张盘只有 **4.3 MB**。选完系统，安装程序从镜像站现拉——所以：

- U 盘 58 G 空间全空着，爱放什么放什么
- 想试五个发行版，不用刻五次盘
- 系统版本更新了，什么都不用改，它拉的就是最新的

## 为什么菜单分中文和英文两部分

这不是偷懒，是 iPXE 的限制。看源码：

```c
/* iPXE src/core/console.c */
int putchar ( int character ) {
        ...
        list_for_each_entry ( console, &consoles, list )
                console->putchar ( character );   /* 逐字节交给显示驱动 */
}
```

`putchar` 接收一个字节就交给驱动绘制。全树 `grep -i "utf8|unicode|wchar"` **零命中**——没有 UTF-8 解码，没有多字节字符处理。

汉字在 UTF-8 里是 3 个字节，iPXE 会把它们当成 3 个独立字符画出来，结果是乱码或方块。

要汉化得：重写渲染层 → 生成几千字的点阵字库 → 改字模索引 → 重编译。而且 netboot.xyz 的菜单是它**服务器实时下发**的，改了本地客户端也没用。

所以方案是**分层**：

| 层 | 引擎 | 语言 | 覆盖 |
|---|---|---|---|
| 前置菜单 | GRUB（本项目自己编译） | 中文 | 4 个直连系统 + 导航 |
| 兜底菜单 | netboot.xyz（iPXE） | 英文 | 90+ 系统 |

## 快速开始

### 依赖

```bash
# Debian / Ubuntu / Kali
sudo apt install grub-common grub-efi-amd64-bin fonts-noto-cjk fonts-dejavu-core \
                 python3 parted dosfstools util-linux curl
```

### 构建

```bash
./build.sh
```

产物：`dist/BOOTX64.EFI`（约 4.3 MB）

构建过程会：
1. 扫描 `src/grub.cfg`，提取用到的汉字
2. 只给这些字生成字模（125 个字形 → 8 KB 字库）
3. 把菜单 + 两套字库内嵌进 EFI 二进制
4. 校验内嵌内容

### 写入 U 盘

```bash
sudo ./install-usb.sh /dev/sdX
```

**会清空整个设备。** 脚本有三重检查（非系统盘 / USB 总线 / 人工二次确认），但设备名请你自己核对：

```bash
lsblk -o NAME,SIZE,MODEL,TRAN
```

### 启动

1. 插到目标电脑
2. 开机连按 `F12`（或 `F11` / `F7` / `Esc`）
3. 选 **`UEFI: 你的U盘名`**——不要选 Legacy / CSM
4. 中文菜单出来，方向键选择，回车

> **必须插网线。** GRUB 阶段无线网卡基本认不出来。装完进了系统再用 WiFi 没问题。

## 为什么只有 4 个系统能直连

GRUB 的 http 模块要一次性把 initrd 拉进内存，几百 MB 的 initrd 扛不住。实测各发行版 initrd 大小：

| 发行版 | vmlinuz | initrd | 能否直连 |
|---|---|---|---|
| Debian 13 | 11.6 MB | **38.9 MB** | ✅ |
| Alpine Linux | 13.9 MB | **26.7 MB** | ✅ |
| CentOS Stream 10 | 16.0 MB | **77.2 MB** | ✅（较慢） |
| Fedora 43 | 17.0 MB | 251.5 MB | ❌ |
| openSUSE Leap 15.6 | 13.5 MB | 226.5 MB | ❌ |
| Rocky / AlmaLinux 9 | 14.6 MB | 218.2 MB | ❌ |

超标的统一走 ⑥ netboot.xyz——iPXE 是专业的网络引导引擎，几百 MB 也不在话下，代价是菜单变英文。

## 装 Windows

netboot.xyz 里**有** Windows 菜单，但它不自带任何 Windows 文件。它要你提供一个解压好的 ISO 的 HTTP 地址：

```
Set the HTTP URL of an extracted Windows ISO without the trailing slash:
e.g. http://www.mydomain.com/windows
```

它会依次加载：

```
${win_base_url}/x64/bootmgr
${win_base_url}/x64/bootmgr.efi
${win_base_url}/x64/boot/bcd
${win_base_url}/x64/boot/boot.sdi
${win_base_url}/x64/sources/boot.wim
```

完整操作步骤见 [docs/Windows安装.md](docs/Windows安装.md)。

**没有 ISO 的话，Windows 装不了。** 这是微软的授权限制，不是技术选择。

## 目录结构

```
.
├── build.sh               构建 EFI
├── install-usb.sh         写入 U 盘
├── src/grub.cfg           菜单源文件（改这里）
├── dist/                  构建产物
├── docs/
│   ├── 发行版对照表.md     90+ 系统的中文名与一句话说明
│   ├── Windows安装.md
│   ├── 常见问题.md
│   └── 使用说明.txt        拷进 U 盘的说明文件
└── .github/workflows/     CI 自动构建
```

## 改菜单

编辑 `src/grub.cfg`，然后重新 `./build.sh`。

配置是**内嵌在 EFI 里**的，改了源文件不重新构建不生效。

字体同理——菜单里新加的字如果不在字库里，会显示成空白。`build.sh` 会自动扫描配置提取字符集，所以只要重新构建就不会漏。

## 已知限制

- **只支持 UEFI**，不做 Legacy BIOS 引导（2020 年后的机器基本都 UEFI）
- **必须联网**，没网什么都装不了
- **必须插网线**（用 GRUB 直连那几项时）
- 镜像站 IP 是硬编码的（GRUB 没有 DNS 模块），清华源 `101.6.15.130`、中科大 `202.141.160.110`。IP 变了要改 `src/grub.cfg`
- Windows 需要自备 ISO
- 国产系统（Deepin / UOS / openKylin）不在 netboot.xyz 收录范围内，需要 ISO

## 许可

MIT

## 致谢

- [netboot.xyz](https://github.com/netbootxyz/netboot.xyz) — 网络安装的整套思路和兜底菜单
- [GNU GRUB](https://www.gnu.org/software/grub/) — 中文显示能力的来源
- [清华大学开源软件镜像站](https://mirrors.tuna.tsinghua.edu.cn/) / [中科大镜像](https://mirrors.ustc.edu.cn/) — 安装源
- Noto Sans CJK / DejaVu — 字库
