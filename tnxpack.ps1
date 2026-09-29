# ============================================================================
# tnxpack.ps1 —— ELF64 -> TNX 打包器
#
# 定位：**TNX v1 不需要自己的编译器，也不需要自己的链接器。**
# 真正的工具链还是 clang / lld，tnxpack 只负责最后一步：
#
#     foo.c -> clang -> foo.o -> lld -> foo.elf -> tnxpack -> FOO.TNX
#
# 它只做一件事：读 ELF64 的 PT_LOAD 段，写 TNX 的段表 + 段数据。
# 不做重定位、不做符号解析、不做导入 —— 因为 TNX 里根本没有这些东西。
#
# 注意：这个工具是用 PowerShell 写的，不是 C。原因很实际 ——
# 这台机器上只有 clang，没有 C 运行库（没有 MSVC 头、没有 libc），
# 写 C 版宿主工具反而要手搓文件 IO。等 SDK 成形、工具链仓库建起来，
# 再把它重写成 C 并自举。现在优先"能用且可验证"。
# ============================================================================
param(
    [Parameter(Mandatory=$true)][string]$In,
    [Parameter(Mandatory=$true)][string]$Out,
    [switch]$Quiet,
    [switch]$Dump
)
$ErrorActionPreference = 'Stop'

# .NET 的文件 API 用的是**进程工作目录**，而 PowerShell 的 Set-Location 不会同步它。
# 直接把相对路径喂给 [System.IO.File] 会解析到别的目录去 —— 这个坑踩过一次。
function To-Abs([string]$p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path (Get-Location).Path $p)
}
$In  = To-Abs $In
$Out = To-Abs $Out

$TNX_MAGIC        = [uint64]0x000000001A584E54   # "TNX\x1A" + 4 个 0
$TNX_VERSION      = [uint32]0x00010000
$TNX_HEADER_SIZE  = 48
$TNX_SECTION_SIZE = 40
$TNX_ALIGN        = 16
$TNX_FLAG_CONSOLE = [uint32]0x00000001

$img = [System.IO.File]::ReadAllBytes($In)
$n = $img.Length

# ------------------------------------------------------------ ELF64 头校验
if ($n -lt 64) { throw ("输入太小，不是 ELF64（" + $n + " 字节）") }
if (-not ($img[0] -eq 0x7F -and $img[1] -eq 0x45 -and $img[2] -eq 0x4C -and $img[3] -eq 0x46)) { throw "ELF 魔数不对" }
if ($img[4] -ne 2) { throw "EI_CLASS != 2，不是 ELF64" }
if ($img[5] -ne 1) { throw "EI_DATA != 1，不是小端" }

$etype     = [BitConverter]::ToUInt16($img, 0x10)
$emach     = [BitConverter]::ToUInt16($img, 0x12)
$entry     = [long][BitConverter]::ToUInt64($img, 0x18)
$phoff     = [long][BitConverter]::ToUInt64($img, 0x20)
$phentsize = [int][BitConverter]::ToUInt16($img, 0x36)
$phnum     = [int][BitConverter]::ToUInt16($img, 0x38)

if ($etype -ne 2)  { throw ("e_type = " + $etype + "，不是 ET_EXEC —— 链接脚本里不要开 PIE") }
if ($emach -ne 62) { throw ("e_machine = " + $emach + "，不是 x86-64") }
if ($phnum -eq 0)  { throw "没有程序头，链接脚本可能把一切都丢进 /DISCARD/ 了" }
if ($phentsize -lt 56) { throw ("程序头条目只有 " + $phentsize + " 字节，不是 ELF64 的 56") }

# --------------------------------------------------------- 收集 PT_LOAD 段
$loads = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $phnum; $i++) {
    $o = $phoff + $i * $phentsize
    if ($o + 56 -gt $n) { throw "程序头越界" }
    $ptype = [BitConverter]::ToUInt32($img, $o)
    if ($ptype -ne 1) { continue }                       # 只要 PT_LOAD
    $pflags   = [int][BitConverter]::ToUInt32($img, $o + 4)
    $p_offset = [long][BitConverter]::ToUInt64($img, $o + 0x08)
    $p_vaddr  = [long][BitConverter]::ToUInt64($img, $o + 0x10)
    $p_filesz = [long][BitConverter]::ToUInt64($img, $o + 0x20)
    $p_memsz  = [long][BitConverter]::ToUInt64($img, $o + 0x28)

    if ($p_memsz -eq 0) { continue }                     # 空段不要
    if ($p_offset + $p_filesz -gt $n) { throw ("段数据越界：offset=" + $p_offset + " filesz=" + $p_filesz) }
    if ($p_filesz -gt $p_memsz) { throw "FileSize > MemSize，ELF 本身就不对" }

    [void]$loads.Add([pscustomobject]@{
        Flags  = $pflags
        Offset = $p_offset
        Vaddr  = $p_vaddr
        FileSz = $p_filesz
        MemSz  = $p_memsz
    })
}
if ($loads.Count -eq 0) { throw "没有可加载的段（PT_LOAD）" }
if ($loads.Count -gt 16) { throw ("段数 " + $loads.Count + " 超过 TNX 上限 16") }

# ------------------------------------------------------------- 地址规划
# 注意：这里全部显式用 [long]。
# Measure-Object 的 -Minimum 返回的是 Double，而 PowerShell 的 Double
# 一旦混进地址运算，写出来的 ImageBase 就会变成 0x100000000 这种鬼东西，
# 而且 ToString("X") 还会直接抛"格式说明符无效"。别偷懒。
$base = [long]::MaxValue
$top  = [long]::MinValue
foreach ($s in $loads) {
    $v = [long]$s.Vaddr
    $m = [long]$s.MemSz
    if ($v -lt $base) { $base = $v }
    if (($v + $m) -gt $top) { $top = [long]($v + $m) }
}
$imageSize = [long]($top - $base)
$entryRva  = [long]($entry - $base)

if ($base -le 0)        { throw ("映像基址算出来是 " + $base + "，链接脚本没设 . = 基址？") }
if ($entryRva -lt 0 -or $entryRva -ge $imageSize) {
    throw ("入口点 0x" + ([long]$entry).ToString("X") + " 落在映像之外")
}

# --------------------------------------------------------- TNX 输出布局
$secTabBytes = $TNX_SECTION_SIZE * $loads.Count
$dataStart   = $TNX_HEADER_SIZE + $secTabBytes
$dataStart   = [int]([Math]::Ceiling($dataStart / $TNX_ALIGN) * $TNX_ALIGN)

$cursor = $dataStart
$sections = @()
foreach ($s in $loads) {
    $cursor = [int]([Math]::Ceiling($cursor / $TNX_ALIGN) * $TNX_ALIGN)

    $tag = [uint32]0
    if ($s.Flags -band 1) { $tag = [uint32]0x45444F43 }        # X -> 'CODE'
    elseif ($s.Flags -band 2) { $tag = [uint32]0x41544144 }    # W -> 'DATA'
    else { $tag = [uint32]0x54444F52 }                         #   -> 'RODT'

    # ZERO 表示纯 BSS：文件里一字节都没有，全靠加载器置零
    $secFlags = 1                                              # R 恒真
    if ($s.Flags -band 2) { $secFlags = $secFlags -bor 2 }
    if ($s.Flags -band 1) { $secFlags = $secFlags -bor 4 }
    if ($s.FileSz -eq 0)  { $secFlags = $secFlags -bor 8 }

    $sections += [pscustomobject]@{
        Tag     = $tag
        Flags   = [uint32]$secFlags
        FileOff = [long]$cursor
        Rva     = [long]([long]$s.Vaddr - $base)
        FileSz  = [long]$s.FileSz
        MemSz   = [long]$s.MemSz
        SrcOff  = [long]$s.Offset
    }
    $cursor = [long]($cursor + [long]$s.FileSz)
}

$total = $cursor
if ($total -gt 8388608) { throw ("TNX 映像 " + $total + " 字节，超过内核窗口 8MiB") }

$outBuf = New-Object 'byte[]' $total

function PutU32([byte[]]$b, [long]$o, $v) { [Array]::Copy([BitConverter]::GetBytes([uint32]$v), 0, $b, $o, 4) }
function PutU64([byte[]]$b, [long]$o, $v) { [Array]::Copy([BitConverter]::GetBytes([uint64]$v), 0, $b, $o, 8) }

# ------------------------------------------------------------------ 头部
PutU64 $outBuf 0  $TNX_MAGIC
PutU32 $outBuf 8  $TNX_VERSION
PutU32 $outBuf 12 $TNX_HEADER_SIZE
PutU32 $outBuf 16 $TNX_FLAG_CONSOLE
PutU32 $outBuf 20 $loads.Count
PutU64 $outBuf 24 $entryRva
PutU64 $outBuf 32 $base
PutU64 $outBuf 40 $imageSize

# ------------------------------------------------------------------ 段表
for ($i = 0; $i -lt $sections.Count; $i++) {
    $o = $TNX_HEADER_SIZE + $i * $TNX_SECTION_SIZE
    $s = $sections[$i]
    PutU32 $outBuf ($o + 0)  $s.Tag
    PutU32 $outBuf ($o + 4)  $s.Flags
    PutU64 $outBuf ($o + 8)  $s.FileOff
    PutU64 $outBuf ($o + 16) $s.Rva
    PutU64 $outBuf ($o + 24) $s.FileSz
    PutU64 $outBuf ($o + 32) $s.MemSz
}

# ------------------------------------------------------------------ 段数据
foreach ($s in $sections) {
    if ($s.FileSz -gt 0) { [Array]::Copy($img, $s.SrcOff, $outBuf, $s.FileOff, $s.FileSz) }
}

[System.IO.File]::WriteAllBytes($Out, $outBuf)

function TagName($t) {
    switch ([uint32]$t) {
        0x45444F43 { "CODE" }
        0x41544144 { "DATA" }
        0x54444F52 { "RODT" }
        0x43525352 { "RSRC" }
        0x4E474953 { "SIGN" }
        default    { "????" }
    }
}

if ($Dump) {
    Write-Host ("  ELF    : e_entry=0x" + ([long]$entry).ToString("X") + "  PT_LOAD=" + $loads.Count)
    foreach ($s in $loads) {
        Write-Host ("            flags=" + $s.Flags + "  vaddr=0x" + ([long]$s.Vaddr).ToString("X") + "  filesz=" + $s.FileSz + "  memsz=" + $s.MemSz)
    }
    Write-Host ("  TNX    : imageBase=0x" + $base.ToString("X") + "  imageSize=" + $imageSize + "  entryRva=0x" + $entryRva.ToString("X"))
    $i = 0
    foreach ($s in $sections) {
        Write-Host ("            #" + $i + "  " + (TagName $s.Tag) + "  flags=0x" + ([uint32]$s.Flags).ToString("X") + "  rva=0x" + $s.Rva.ToString("X") + "  file=" + $s.FileSz + "  mem=" + $s.MemSz + "  off=" + $s.FileOff)
        $i++
    }
}

if (-not $Quiet) {
    $tags = ($sections | ForEach-Object { TagName $_.Tag }) -join "+"
    Write-Host ("  [tnx] " + (Split-Path $Out -Leaf) + "   " + $loads.Count + " sections (" + $tags + "),  image " + $imageSize + " bytes @ 0x" + $base.ToString("X") + ",  entry +0x" + $entryRva.ToString("X") + ",  file " + $total + " bytes")
}