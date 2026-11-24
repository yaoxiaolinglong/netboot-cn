# 用这张盘装 Windows

## 先说结论

**netboot.xyz 不自带 Windows，你必须有 Windows ISO。**

它用的机制叫 `wimboot`：把 Windows 安装程序需要的几个文件通过网络喂给一个微型引导器，绕开光盘/U盘。所以那些文件必须存在于某台机器上，并且能通过 HTTP 访问。

微软不提供公开的网络引导端点，ISO 也有授权限制——netboot.xyz 作为一个分发平台不能托管它。这不是技术缺陷，是法律边界。

## 你要准备什么

| 材料 | 说明 |
|---|---|
| Windows ISO | 微软官网免费下载：[Windows 11](https://www.microsoft.com/software-download/windows11) / [Windows 10](https://www.microsoft.com/software-download/windows10) |
| 一台能跑 HTTP 服务的机器 | 和目标机**同一个局域网**。笔记本、树莓派、NAS 都行 |
| 目标机 ≥ 4 GB 内存 | `boot.wim` 会被整个加载进内存 |

## 步骤

### 1. 解压 ISO

**不要**只把 ISO 文件拷过去，要解压出里面的内容。

```bash
# Linux
mkdir -p ~/win-http/windows
sudo mount -o loop Win11.iso /mnt
cp -r /mnt/* ~/win-http/windows/
sudo umount /mnt
```

Windows 上右键 ISO → 「装载」→ 把虚拟光驱里的内容全选复制出来。

### 2. 确认关键文件在

```
~/win-http/windows/
├── bootmgr
├── bootmgr.efi
├── boot/
│   ├── bcd
│   └── boot.sdi
└── sources/
    └── boot.wim          ← 这个最大，通常 400-700 MB
```

缺任何一个都会在加载阶段报错。

### 3. 起一个 HTTP 服务

```bash
cd ~/win-http
python3 -m http.server 8000 --bind 0.0.0.0
```

查一下这台机器的局域网 IP：

```bash
ip -4 addr show | grep inet
```

假设是 `192.168.1.50`，那么 Windows 文件的可访问地址就是：

```
http://192.168.1.50:8000/windows
```

**先在自己浏览器里试一下这个地址**，能看到文件列表或下载提示就对了。

### 4. 目标机启动

1. 插上本项目的 U 盘，开机按 `F12`，选 UEFI 启动
2. 中文菜单选 **⑤ 安装 Windows**
3. 进入 netboot.xyz 英文菜单后，选 **Windows**
4. 选 **`Set Base URL`**，输入：
   ```
   http://192.168.1.50:8000/windows
   ```
5. 返回，选 **`Load Microsoft Windows Installer...`**
6. 等 `boot.wim` 传完，Windows 安装程序就起来了

### 5. 安装

和普通 U 盘装 Windows 完全一样。唯一区别：**中途不要拔网线**，因为安装程序可能还要从网络拿东西。

## 常见问题

**卡在 "Loading boot.wim" 不动**
- 文件没传完就超时了。检查 HTTP 服务的日志，看有没有完整传输
- 局域网带宽不够（WiFi 传 600 MB 要几分钟）。改用网线

**报 `URL not set`**
- 忘了设 Base URL，回去第 4 步

**报找不到 `boot/bcd` 或 `Boot/BCD`**
- ISO 没解压干净，或者路径不对。netboot.xyz 会同时试小写 `boot/` 和大写 `Boot/`，两者都没有就是真缺

**安装到一半报 "找不到安装源"**
- 这是 wimboot 的固有限制。安装程序起来后，最好把 ISO 也放到一个 HTTP 目录，安装时手动指定；或者干脆用别的方式装

**内存不足**
- `boot.wim` 整个进内存，4 GB 是底线，8 GB 更稳

## 更省事的替代方案

如果只是要装 Windows，**别折腾 wimboot**，用 Ventoy 更简单：

1. 下载 Ventoy，装到 U 盘
2. 把 Windows ISO 直接拷进 U 盘根目录
3. 启动，选 ISO，装

代价是 U 盘要占掉 5-7 GB。

**wimboot 唯一的价值是"不占 U 盘空间"**——如果你的 U 盘够大，Ventoy 省事一百倍。

## 想用 Linux 装 Windows 双系统？

流程一样，只是要在装 Windows 之前给磁盘留出 NTFS 分区，装完 Windows 再用 Linux 安装器把 GRUB 找回来（Windows 会覆盖引导记录）。

顺序：**先装 Windows，后装 Linux**，GRUB 会自动识别 Windows 并加进菜单。反过来的话要手动修引导。
