# 约定 / Conventions

## 1. 提交信息必须双语 / Commit messages must be bilingual

**主题行 = 中文 + English，一行。**

```
提交初始代码 Submit the initial code
```

正文可以以中文为主，但**主题行必须有英文**。仓库是公开的，
看不懂中文的人至少要知道这次提交干了什么。

反例（只有中文，公开仓库里等于没写）：

```
TNX 加载器 + 裸程序名执行；工具链拆到独立仓库          <- 不合格
TNX loader + run programs by bare name; split toolchain out   <- 合格
```

完整例子：

```
TNX 加载器 + 裸程序名执行；工具链拆到独立仓库

TNX loader + run programs by bare name; split toolchain out

- 新增 TNX 可执行格式 v1 与加载器
- 敲程序名（扩展名可选）直接执行，TNX <file> 改为查看信息

- add TNX executable format v1 and its loader
- running a program is now just typing its name; TNX <file> inspects
```

---

## 2. 控制台输出一律 ASCII / Console output is ASCII only

UEFI 固件的点阵字体**不保证**带 ASCII 以外的字形。OVMF 实测结果：
中文 codepoint 找不到字形，屏幕上是一片**纯空白**。读不出字的控制台比没有更糟。

所以 `con_*` / `log_*` / `dputs` 的字符串**全部英文**。

源码**注释**保持中文 —— 那是给人读源码的，不经过任何字体。
文档（README / docs/）保持中文为主，按第 1 条的要求配英文主题。

---

## 3. 不写死任何机器相关的路径 / No hardcoded tool paths

所有外部工具从环境变量取，取不到就自动探测，再取不到就**报错并把 `setx` 命令打给用户**。

| 变量 | 用途 |
|---|---|
| `TNDDOS_LLVM_BIN` | 含 `clang.exe` 与 `ld.lld.exe` 的目录 |
| `TNDDOS_QEMU` | `qemu-system-x86_64.exe` 完整路径 |
| `TNDDOS_TOOLKIT` | TNDOS-ToolsKit 仓库根目录 |

---

## 4. PowerShell 脚本必须有 UTF-8 BOM

Windows PowerShell 5.1 没有 BOM 就按 ANSI 读文件，
**中文注释会让整个脚本语法错误** —— 而且报的错和真正的原因毫无关系。

编辑工具会吃掉 BOM，所以每次改完 `.ps1` 都要检查一遍。

---

## 5. 行尾统一 LF

见 `.gitattributes`。`*.ps1` / `*.bat` / `*.cmd` 例外，保持 CRLF。

---

## 6. 失败要响，不许静默 / Fail loud, never silently

这条是两次最贵的教训换来的：

- `t_read_file` 缓冲区满了却不报，内核映像被截断 1.5 KB，
  `LoadImage` 只回了一个没头没脑的 `Unsupported`
- `pmm_reserve` 因为 `gReady` 还没置位而**静默地什么都没做** ——
  位图上看不出来，日志里也没有任何迹象

**任何"可能悄悄没生效"的地方都要有断言或日志。**

---

## 7. 编译器看不见的东西必须埋运行期自检

结构体偏移、ABI、格式布局，编译器一声不吭。所以：

- `LoadedImage.SystemTable == SystemTable` —— 校验 `EFI_LOADED_IMAGE_PROTOCOL` 的偏移
- `FirmwareVendor == "EDK II"` —— 校验 `EFI_SYSTEM_TABLE` 的偏移
- TNX 加载器的 `validate()` —— 每条规则失败都有**具体**理由，绝不部分加载

---

## 8. 每个改动都要能真的跑一遍

不是"看起来对"，是**在 QEMU 里启动过**。
`tools/build-run.ps1` 一键完成：编译 -> 组 ESP -> 造 FAT16 映像 -> QEMU/OVMF 启动 -> 打印串口日志。

`tnxdump -Validate` 可以在不启动 QEMU 的情况下校验一个 TNX —— 构建流水线里优先用它。
