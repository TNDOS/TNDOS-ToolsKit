# ============================================================================
# tnxdump.ps1 -- TNX 检查器
#
#   .\tnxdump.ps1 HELLO.TNX              打印头部与段表
#   .\tnxdump.ps1 HELLO.TNX -Validate    再判断"内核会不会接受它"
#
# -Validate 干的事就是把内核加载器 (src/kernel/tnx.c 的 validate()) 的每一条
# 校验规则在宿主机上重跑一遍。目的是**不用启动 QEMU 就能知道一个 TNX 能不能加载** ——
# 构建流水线里跑这个，比启动一次虚拟机快几百倍。
#
# 注意：这里的规则必须和内核保持一致。改了一边就要改另一边。
# 权威定义在 include/tnx.h 和内核的 validate()。
# ============================================================================
param(
    [Parameter(Mandatory=$true, Position=0)][string[]]$Path,
    [switch]$Validate,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# .NET 的文件 API 用进程工作目录，Set-Location 不会同步它。相对路径必须先转绝对。
function To-Abs([string]$p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path (Get-Location).Path $p)
}
$Path = @($Path | ForEach-Object { To-Abs $_ })

# --- 格式常量（权威定义见 include/tnx.h）---
$TNX_MAGIC        = [uint64]0x000000001A584E54
$TNX_VERSION      = [uint32]0x00010000
$TNX_HEADER_SIZE  = 48
$TNX_SECTION_SIZE = 40
$TNX_ALIGN        = 16
$TNX_KNOWN_FLAGS  = [uint32]0x00000001
$TNX_IMAGE_BASE   = [uint64]0x0000000001000000
$TNX_WINDOW_SIZE  = [uint64]0x00000000800000
$TNX_MAX_SECTIONS = 16

$TAGS = @{
    0x45444F43 = 'CODE'
    0x41544144 = 'DATA'
    0x54444F52 = 'RODT'
    0x43525352 = 'RSRC'
    0x4E474953 = 'SIGN'
}

$global:AnyFail = $false

foreach ($file in $Path) {
    if (-not (Test-Path -LiteralPath $file)) { Write-Host ("找不到文件: " + $file); $global:AnyFail = $true; continue }

    $b = [System.IO.File]::ReadAllBytes($file)
    $n = $b.Length
    if (-not $Quiet) { Write-Host ("=== " + (Split-Path $file -Leaf) + "   (" + $n + " bytes) ===") }

    $fail = New-Object System.Collections.ArrayList
    function Bad($m) { [void]$fail.Add($m) }

    if ($n -lt $TNX_HEADER_SIZE) { Bad "文件小于 48 字节"; }
    else {
        $magic   = [uint64][BitConverter]::ToUInt64($b, 0)
        $version = [uint32][BitConverter]::ToUInt32($b, 8)
        $hdrsize = [uint32][BitConverter]::ToUInt32($b, 12)
        $flags   = [uint32][BitConverter]::ToUInt32($b, 16)
        $seccnt  = [uint32][BitConverter]::ToUInt32($b, 20)
        $entry   = [uint64][BitConverter]::ToUInt64($b, 24)
        $base    = [uint64][BitConverter]::ToUInt64($b, 32)
        $imgsize = [uint64][BitConverter]::ToUInt64($b, 40)

        if (-not $Quiet) {
            Write-Host ("  magic      0x" + $magic.ToString("X16") + $(if ($magic -eq $TNX_MAGIC) { "   TNX" } else { "   <不是 TNX 魔数>" }))
            Write-Host ("  version    0x" + $version.ToString("X8") + "   (" + ($version -shr 16) + "." + (($version -shr 8) -band 0xFF) + "." + ($version -band 0xFF) + ")")
            Write-Host ("  header     " + $hdrsize + " bytes")
            $flagStr = @()
            if ($flags -band 1) { $flagStr += "CONSOLE" }
            $unknown = $flags -band (-bnot $TNX_KNOWN_FLAGS)
            if ($unknown) { $flagStr += ("UNKNOWN(0x" + $unknown.ToString("X") + ")") }
            Write-Host ("  flags      0x" + $flags.ToString("X8") + "   " + ($flagStr -join ' '))
            Write-Host ("  sections   " + $seccnt)
            Write-Host ("  entry      RVA 0x" + $entry.ToString("X"))
            Write-Host ("  imageBase  0x" + $base.ToString("X16"))
            Write-Host ("  imageSize  " + $imgsize + " bytes")
        }

        # ---- 逐条重跑内核的 validate() ----
        if ($magic   -ne $TNX_MAGIC)                { Bad "bad magic (not a TNX)" }
        if ($version -ne $TNX_VERSION)              { Bad ("unsupported version 0x" + $version.ToString("X8")) }
        if ($hdrsize -lt $TNX_HEADER_SIZE)          { Bad "HeaderSize below 48" }
        if ($hdrsize -gt $n)                        { Bad "HeaderSize beyond file" }
        if ($flags -band (-bnot $TNX_KNOWN_FLAGS))  { Bad ("unknown flag bits 0x" + $unknown.ToString("X")) }
        if ($seccnt -eq 0)                          { Bad "no sections" }
        if ($seccnt -gt $TNX_MAX_SECTIONS)          { Bad ("too many sections (" + $seccnt + " > " + $TNX_MAX_SECTIONS + ")") }
        if ($base -ne $TNX_IMAGE_BASE)              { Bad ("ImageBase 0x" + $base.ToString("X") + " != loader window 0x" + $TNX_IMAGE_BASE.ToString("X")) }
        if ($imgsize -eq 0)                         { Bad "ImageSize is 0" }
        if ($imgsize -gt $TNX_WINDOW_SIZE)          { Bad ("image larger than window (" + $imgsize + " > " + $TNX_WINDOW_SIZE + ")") }
        if ($entry -ge $imgsize)                    { Bad "entry point outside image" }
        if (([uint64]$hdrsize + [uint64]$seccnt * $TNX_SECTION_SIZE) -gt [uint64]$n) { Bad "section table runs past end of file" }

        if (-not $Quiet -and $seccnt -gt 0 -and $seccnt -le 64) {
            for ($i = 0; $i -lt $seccnt; $i++) {
                $o = [int]$hdrsize + $i * $TNX_SECTION_SIZE
                if ($o + $TNX_SECTION_SIZE -gt $n) { Write-Host ("  #" + $i + "  <段表越界>"); break }
                $tag    = [uint32][BitConverter]::ToUInt32($b, $o + 0)
                $sflags = [uint32][BitConverter]::ToUInt32($b, $o + 4)
                $soff   = [uint64][BitConverter]::ToUInt64($b, $o + 8)
                $srva   = [uint64][BitConverter]::ToUInt64($b, $o + 16)
                $sfile  = [uint64][BitConverter]::ToUInt64($b, $o + 24)
                $smem   = [uint64][BitConverter]::ToUInt64($b, $o + 32)
                $name   = if ($TAGS.ContainsKey([int]$tag)) { $TAGS[[int]$tag] } else { "????" }
                $fs = ""
                $fs += if ($sflags -band 1) { "R" } else { "-" }
                $fs += if ($sflags -band 2) { "W" } else { "-" }
                $fs += if ($sflags -band 4) { "X" } else { "-" }
                $fs += if ($sflags -band 8) { "Z" } else { "-" }
                Write-Host ("  #" + $i + "  " + $name + "  " + $fs + "   file " + $sfile + " -> mem " + $smem + "   rva 0x" + $srva.ToString("X") + "   off " + $soff)

                # 段级规则（同上，照抄内核）
                if (-not $TAGS.ContainsKey([int]$tag))    { Bad ("#" + $i + " unknown section tag") }
                if ($sfile -gt $smem)                     { Bad ("#" + $i + " FileSize > MemSize") }
                if (($sflags -band 8) -and $sfile -ne 0)  { Bad ("#" + $i + " ZERO section carries file data") }
                if (($soff + $sfile) -gt [uint64]$n)      { Bad ("#" + $i + " section data past end of file") }
                if (($srva + $smem) -gt $imgsize)         { Bad ("#" + $i + " section runs past image end") }
                if (($srva -band ($TNX_ALIGN - 1)) -ne 0) { Bad ("#" + $i + " section RVA not 16-byte aligned") }
            }
        }
    }

    if ($fail.Count -gt 0) {
        $global:AnyFail = $true
        Write-Host ("  REJECTED -- 内核加载器会拒绝它：")
        foreach ($f in $fail) { Write-Host ("    - " + $f) }
    } elseif (-not $Quiet) {
        Write-Host "  OK -- 内核加载器会接受它"
    }
    if (-not $Quiet) { Write-Host "" }
}

if ($global:AnyFail) { exit 1 } else { exit 0 }
