# TNDOS-ToolsKit

TNDDOS 的**宿主机工具**。这些东西跑在你的开发机上，不跑在 TNDDOS 里。

| 工具 | 干什么 | 输入 -> 输出 |
|---|---|---|
| @tnxpack.ps1@ | TNX 打包器 | ELF64 -> @.TNX@ |
| @tnxdump.ps1@ | TNX 检查器 | @.TNX@ -> 人可读的头部 + 段表，可选校验 |
| @mkfat.ps1@ | FAT16 映像生成器 | 目录 -> 可启动的 @.img@ |

当前版本 **v1.0**（对应 TNX 格式 v1.0）。

---

## 为什么单独一个仓库

因为它们和操作系统的**生命周期不同**。

操作系统会重写、会换架构、会长出新子系统。而这几个工具的接口是稳定的：
输入 ELF64 输出 TNX，输入目录输出 FAT16 映像。它们的接口由**格式**决定，
不由内核代码决定。

而且它们要被三处使用：SysCore 构建、SDK 构建、以及你手动排查问题的时候。
放在任何一个仓库里，另外两个就得连带拉取。

---

## 用法

三个脚本都是独立可跑的，互相不依赖，也不依赖任何环境变量。

### tnxpack —— ELF64 转 TNX

@​@​@powershell
.\tnxpack.ps1 -In hello.elf -Out HELLO.TNX
.\tnxpack.ps1 -In hello.elf -Out HELLO.TNX -Dump     # 顺便打印解析出来的每个值
@​@​@

@​@​@
  [tnx] HELLO.TNX   3 sections (CODE+RODT+DATA),  image 1760 bytes @ 0x1000000,  entry +0x0,  file 1840 bytes
@​@​@

它只做一件事：读 ELF64 的 @PT_LOAD@ 程序头，写 TNX 的段表加段数据。
段类型由 @p_flags@ 推出来（X -> CODE，W -> DATA，否则 RODT），
@ImageBase@ 取所有 @PT_LOAD@ 的最小 @p_vaddr@。

**不做重定位、不做符号解析、不做导入 —— 因为 TNX 里根本没有这些东西。**

### tnxdump —— 检查一个 TNX

@​@​@powershell
.\tnxdump.ps1 HELLO.TNX              # 打印头部与段表
.\tnxdump.ps1 HELLO.TNX -Validate    # 再判断"内核会不会接受它"
.\tnxdump.ps1 *.TNX -Quiet           # 批量，只出结论
@​@​@

@​@​@
=== HELLO.TNX   (1840 bytes) ===
  magic      0x000000001A584E54   TNX
  version    0x00010000   (1.0.0)
  header     48 bytes
  flags      0x00000001   CONSOLE
  sections   3
  entry      RVA 0x0
  imageBase  0x0000000001000000
  imageSize  1760 bytes
  #0  CODE  R-X-   file 1053 -> mem 1053   rva 0x0   off 176
  #1  RODT  R---   file 599 -> mem 599   rva 0x420   off 1232
  #2  DATA  RW-Z   file 0 -> mem 96   rva 0x680   off 1840
  OK -- 内核加载器会接受它
@​@​@

**@-Validate@ 是这个工具的主要价值。** 它把内核加载器
（@TNDOS-SysCore/src/kernel/tnx.c@ 里的 @validate()@）的每一条规则
在宿主机上重跑一遍，所以**不用启动 QEMU 就能知道一个 TNX 能不能加载**。
构建流水线里跑它，比启动一次虚拟机快几百倍。

失败时退出码为 1，可以直接接在 @if ($LASTEXITCODE)@ 后面。

@​@​@
=== BAD.TNX   (1840 bytes) ===
  ...
  imageBase  0x0000000001009999
  ...
  REJECTED -- 内核加载器会拒绝它：
    - ImageBase 0x1009999 != loader window 0x1000000
@​@​@

**代价**：校验规则有两份（内核一份、这里一份）。改了一边就得改另一边。
权威定义在 @TNDOS-SysCore/src/include/tnx.h@ 和内核的 @validate()@。

### mkfat —— 生成真实 FAT16 映像

@​@​@powershell
.\mkfat.ps1 -Source .\esp -Out .\esp.img
@​@​@

@​@​@
  FAT16: 卷 63488 扇区 / 簇 15832 个 / FAT 每份 62 扇区 / 数据起始扇区 157
  已生成 esp.img  (32 MB, 9 个文件, 75974 字节, 用了 45 簇)
@​@​@

造一块完整的 FAT16：MBR + 单分区（type 0xEF）+ 双 FAT + 固定根目录 + 数据区。
只支持 8.3 短名 —— 工程取舍：TNDDOS 的 ESP 里全是 8.3 名字，省掉长文件名一整块复杂度。

**为什么不用 QEMU 自带的 vvfat（@-drive file=fat:rw:目录@）：**

读没问题，**写回时会直接把 QEMU 干掉**：

@​@​@
ERROR: block/vvfat.c:2429: commit_direntries: assertion failed: (mapping)
@​@​@

TNDDOS 是个 DOS，不能拿一个写不进去的文件系统来测。

---

## 环境变量

**工具本身不依赖任何环境变量**，独立可用。

但 TNDOS-SysCore 和 TNDOS-SDK 的构建脚本会通过这个变量找过来：

@​@​@powershell
setx TNDDOS_TOOLKIT "D:\TNDOS-ToolsKit"
@​@​@

（变量名历史原因叫 @TNDDOS_TOOLKIT@，仓库名是 @TNDOS-ToolsKit@。不影响使用。）

---

## 开发这几个工具时踩过的坑

写在这里免得再踩：

**PowerShell 的 @[int]@ 是四舍五入，不是截断。**
算 FAT16 根目录扇区数时 @[int](16895/512)@ 得到的是 33 而不是 32，
数据区整体偏移一个扇区，固件那边直接读歪。现在全部显式 @[Math]::Floor@ / @Ceiling@。

**@Measure-Object@ 的 @-Minimum@ 返回 Double。**
混进地址运算后写出来的 @ImageBase@ 会变成 @0x100000000@ 而不是 @0x1000000@，
而且 @ToString("X")@ 直接抛"格式说明符无效"。现在地址一律显式 @[long]@。

**@[System.IO.File]@ 用的是进程工作目录，而 PowerShell 的 @Set-Location@ 不会同步它。**
把相对路径喂给 .NET 文件 API 会解析到别的目录去。三个工具现在开头都有 @To-Abs@。

**FAT16 的目录簇 FAT 表项不能留 0。**
0 在 FAT 里的含义是"空闲簇"，目录簇留着 0，FAT 驱动会以为这个目录是空的 ——
文件就"不存在"了。

**PowerShell 变量名不区分大小写。**
@$D@ 被循环变量 @$d@ 覆盖过一次，结果把一堆目录建到了错误的地方。

---

## 为什么是 PowerShell 不是 C

很实际的原因：这台机器上只有 clang，**没有 C 运行库**（没有 MSVC 头、没有 libc）。
写 C 版宿主工具反而要手搓文件 IO 和字符串。

等 TNDDOS-SDK 成形、TNDDOS 能自举之后，这几个工具会重写成 C 并在 TNDDOS 上跑 ——
那时候它们就从"宿主机工具"变成"TNDDOS 原生工具"了，
@tnxdump@ 甚至可以直接用 TNDDOS 自己的 VFS 读文件。

---

## 相关

- **TNDOS-SysCore** —— 操作系统本体，TNX 加载器在那里（@src/kernel/tnx.c@）
- **TNDOS-SDK** —— 写 TNX 程序和驱动需要的头文件 / 运行时 / 链接脚本
- **TNX 格式规范** —— @TNDOS-SysCore/docs/TNX-SPEC.md@，已冻结在 v1.0
