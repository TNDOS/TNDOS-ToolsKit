# ============================================================================
# mkfat.ps1 —— 从目录生成一块真的 FAT16 磁盘映像
#
# 为什么需要它：QEMU 的 vvfat（-drive file=fat:rw:目录）在写回时会崩：
#     ERROR: block/vvfat.c:2429: commit_direntries: assertion failed: (mapping)
# 读没问题，写必炸。TNDDOS 是个 DOS，不能拿一个写不进去的文件系统测。
# 所以这里自己造一块 FAT16：MBR + 单分区 + 双 FAT + 固定根目录 + 数据区。
#
# 只支持 8.3 短名 —— 工程上的取舍：本项目的 ESP 里全是 8.3 名字，
# 不需要长文件名，省掉一整块复杂度。
# ============================================================================
param(
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Out,
    [int]$SizeMB = 32
)
$ErrorActionPreference = 'Stop'

# .NET 的文件 API 用进程工作目录，Set-Location 不会同步它。相对路径必须先转绝对。
function To-Abs([string]$p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path (Get-Location).Path $p)
}
$Source = To-Abs $Source
$Out    = To-Abs $Out

# ---- 几何参数 ----
$BPS        = 512
$SPC        = 4                       # 每簇 4 扇区 = 2KB
$RSVD       = 1
$NFATS      = 2
$ROOTENT    = 512
$PARTLBA    = 2048
# 注意：PowerShell 的 [int] 是四舍五入，不是截断。
# 必须显式 Floor/Ceiling，否则根目录扇区数会算成 33，
# 数据区整体偏移一个扇区，跟标准 FAT 对不上 —— 固件那边直接读歪。
$TotalSec   = [int][Math]::Floor($SizeMB * 1MB / $BPS)
$VolSec     = $TotalSec - $PARTLBA
$RootSec    = [int][Math]::Ceiling(($ROOTENT * 32) / $BPS)   # 32

# 解出 FAT 表大小：FatSz = ceil((CountOfClusters+2)*2/BPS)，而 CountOfClusters 又依赖 FatSz
$fatSz = 8
for ($i = 0; $i -lt 64; $i++) {
    $firstData = $RSVD + $NFATS * $fatSz + $RootSec
    $clusters  = [int][Math]::Floor(($VolSec - $firstData) / $SPC)
    $need      = [int][Math]::Ceiling((($clusters + 2) * 2) / $BPS)
    if ($need -le $fatSz) { break }
    $fatSz = $need
}
$FirstDataSec = $RSVD + $NFATS * $fatSz + $RootSec
$ClusterCount = [int][Math]::Floor(($VolSec - $FirstDataSec) / $SPC)
$ClusterBytes = $SPC * $BPS

if ($ClusterCount -ge 65525) { throw "簇数 $ClusterCount 超出 FAT16 上限，请调大 SPC 或调小盘" }

Write-Host ("  FAT16: 卷 $VolSec 扇区 / 簇 $ClusterCount 个 / FAT 每份 $fatSz 扇区 / 数据起始扇区 $FirstDataSec")

$buf = New-Object 'byte[]' ($TotalSec * $BPS)

function W16([byte[]]$b, [int]$o, [int]$v) { $b[$o] = [byte]($v -band 0xFF); $b[$o+1] = [byte](($v -shr 8) -band 0xFF) }
function W32([byte[]]$b, [int]$o, [long]$v) { for ($i=0; $i -lt 4; $i++) { $b[$o+$i] = [byte](($v -shr (8*$i)) -band 0xFF) } }
function WA([byte[]]$b, [int]$o, [string]$s, [int]$len) {
    for ($i=0; $i -lt $len; $i++) { $b[$o+$i] = if ($i -lt $s.Length) { [byte][char]$s[$i] } else { [byte]32 } }
}

$partBase = $PARTLBA * $BPS
function VolOff([int]$sec) { return $partBase + $sec * $BPS }
function ClusOff([int]$c)  { return (VolOff ($FirstDataSec + ($c - 2) * $SPC)) }

# ---- MBR ----
$buf[510] = 0x55; $buf[511] = 0xAA
$pe = 446
$buf[$pe + 0] = 0x00          # 非活动分区（UEFI 不看这个）
$buf[$pe + 1] = 0xFE; $buf[$pe + 2] = 0xFF; $buf[$pe + 3] = 0xFF
$buf[$pe + 4] = 0xEF          # EFI System Partition
$buf[$pe + 5] = 0xFE; $buf[$pe + 6] = 0xFF; $buf[$pe + 7] = 0xFF
W32 $buf ($pe + 8)  $PARTLBA
W32 $buf ($pe + 12) $VolSec

# ---- 引导扇区 ----
$o = $partBase
$buf[$o+0] = 0xEB; $buf[$o+1] = 0x3C; $buf[$o+2] = 0x90
WA   $buf ($o+3)  "MSDOS5.0" 8
W16  $buf ($o+11) $BPS
$buf[$o+13] = [byte]$SPC
W16  $buf ($o+14) $RSVD
$buf[$o+16] = [byte]$NFATS
W16  $buf ($o+17) $ROOTENT
W16  $buf ($o+19) $(if ($VolSec -lt 65536) { $VolSec } else { 0 })
$buf[$o+21] = 0xF8
W16  $buf ($o+22) $fatSz
W16  $buf ($o+24) 63
W16  $buf ($o+26) 255
W32  $buf ($o+28) $PARTLBA
W32  $buf ($o+32) $(if ($VolSec -lt 65536) { 0 } else { $VolSec })
$buf[$o+36] = 0x80
$buf[$o+38] = 0x29
W32  $buf ($o+39) 0x544E4444
WA   $buf ($o+43) "TNDDOS     " 11
WA   $buf ($o+54) "FAT16   " 8
$buf[$o+510] = 0x55; $buf[$o+511] = 0xAA

# ---- FAT 表（先占位，边分配边写） ----
$fat = New-Object 'int[]' ($ClusterCount + 2)
$fat[0] = 0xFFF8; $fat[1] = 0xFFFF
$script:nextClus = 2

function AllocCluster {
    if ($script:nextClus -gt ($ClusterCount + 1)) { throw "磁盘满了" }
    $c = $script:nextClus; $script:nextClus++
    # 默认写成链尾。这一步不能省：FAT 表项 0 的含义是"空闲簇"，
    # 目录簇若留着 0，FAT 驱动会以为这个目录是空的 —— 文件就"不存在"了。
    $fat[$c] = 0xFFFF
    return $c
}

# ---- 目录树 ----
$dirList = New-Object System.Collections.ArrayList
[void]$dirList.Add(@{ rel = ''; first = 0; parent = 0 })

$i = 0
while ($i -lt $dirList.Count) {
    $cur = $dirList[$i]; $i++
    $full = if ($cur.rel -eq '') { $Source } else { Join-Path $Source $cur.rel }
    if (-not (Test-Path -LiteralPath $full)) { continue }
    foreach ($d in (Get-ChildItem -LiteralPath $full -Directory | Sort-Object Name)) {
        $rel = if ($cur.rel -eq '') { $d.Name } else { "$($cur.rel)\$($d.Name)" }
        [void]$dirList.Add(@{ rel = $rel; first = 0; parent = 0 })
    }
}

foreach ($d in $dirList) {
    if ($d.rel -eq '') { continue }
    $d.first = AllocCluster
}
foreach ($d in $dirList) {
    if ($d.rel -eq '') { continue }
    $parentRel = Split-Path $d.rel -Parent
    if (-not $parentRel) { $d.parent = 0 }
    else {
        $p = $dirList | Where-Object { $_.rel -eq $parentRel } | Select-Object -First 1
        $d.parent = if ($p) { $p.first } else { 0 }
    }
}

# 往目录里追加 32 字节目录项，满了就再要一簇
function AddEntry([hashtable]$dir, [string]$name, [int]$attr, [int]$cluster, [long]$size) {
    $base = $name; $ext = ''
    $dot = $name.LastIndexOf('.')
    if ($dot -gt 0) { $base = $name.Substring(0, $dot); $ext = $name.Substring($dot + 1) }
    $base = $base.ToUpper(); $ext = $ext.ToUpper()

    $slot = if ($dir.rel -eq '') { $null } else { $null }
    $written = $false
    $perClus = [int][Math]::Floor($ClusterBytes / 32)

    if ($dir.rel -eq '') {
        for ($k = 0; $k -lt $ROOTENT; $k++) {
            $e = (VolOff ($RSVD + $NFATS * $fatSz)) + $k * 32
            if ($buf[$e] -eq 0) { Write-EntryAt $e $base $ext $attr $cluster $size; $written = $true; break }
        }
        if (-not $written) { throw "根目录满" }
        return
    }

    # 沿链找空槽
    $c = $dir.first
    while ($c -ne 0) {
        $cb = ClusOff $c
        for ($k = 0; $k -lt $perClus; $k++) {
            $e = $cb + $k * 32
            if ($buf[$e] -eq 0) { Write-EntryAt $e $base $ext $attr $cluster $size; return }
        }
        if ($fat[$c] -eq 0xFFFF) {
            $nc = AllocCluster
            $fat[$c] = $nc; $fat[$nc] = 0xFFFF
            $e = (ClusOff $nc)
            Write-EntryAt $e $base $ext $attr $cluster $size
            return
        }
        $c = $fat[$c]
    }
    throw "目录 $($dir.rel) 没有可用簇"
}

function Write-EntryAt([int]$o, [string]$base, [string]$ext, [int]$attr, [int]$cluster, [long]$size) {
    for ($i = 0; $i -lt 11; $i++) { $buf[$o + $i] = 32 }
    for ($i = 0; $i -lt [Math]::Min(8, $base.Length); $i++) { $buf[$o + $i] = [byte][char]$base[$i] }
    for ($i = 0; $i -lt [Math]::Min(3, $ext.Length);  $i++) { $buf[$o + 8 + $i] = [byte][char]$ext[$i] }
    $buf[$o + 11] = [byte]$attr
    W16 $buf ($o + 22) 0x6000
    W16 $buf ($o + 24) 0x5C21
    W16 $buf ($o + 20) 0
    W16 $buf ($o + 26) $cluster
    W32 $buf ($o + 28) $size
}

# 目录自身的 . 和 ..
foreach ($d in $dirList) {
    if ($d.rel -eq '') { continue }
    $cb = ClusOff $d.first
    for ($i = 0; $i -lt 11; $i++) { $buf[$cb + $i] = 32 }
    $buf[$cb + 0] = [byte][char]'.'
    $buf[$cb + 11] = 0x10
    W16 $buf ($cb + 20) 0
    W16 $buf ($cb + 26) $d.first
    W32 $buf ($cb + 28) 0

    $eb = $cb + 32
    for ($i = 0; $i -lt 11; $i++) { $buf[$eb + $i] = 32 }
    $buf[$eb + 0] = [byte][char]'.'
    $buf[$eb + 1] = [byte][char]'.'
    $buf[$eb + 11] = 0x10
    W16 $buf ($eb + 20) 0
    W16 $buf ($eb + 26) $d.parent
    W32 $buf ($eb + 28) 0
}

# ---- 子目录项 ----
foreach ($d in $dirList) {
    if ($d.rel -eq '') { continue }
    $parentRel = Split-Path $d.rel -Parent
    $parent = if (-not $parentRel) { $dirList[0] } else { $dirList | Where-Object { $_.rel -eq $parentRel } | Select-Object -First 1 }
    $leaf = Split-Path $d.rel -Leaf
    AddEntry $parent $leaf 0x10 $d.first 0
}

# ---- 文件 ----
$fileCount = 0; $byteCount = 0
foreach ($d in $dirList) {
    $full = if ($d.rel -eq '') { $Source } else { Join-Path $Source $d.rel }
    if (-not (Test-Path -LiteralPath $full)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $full -File | Sort-Object Name)) {
        if ($f.Name -notmatch '^[A-Za-z0-9_\-]{1,8}(\.[A-Za-z0-9_\-]{1,3})?$') {
            Write-Host ("  [skip] " + $f.Name + "  (非 8.3 名称，本工具不支持长文件名)")
            continue
        }
        $data = [System.IO.File]::ReadAllBytes($f.FullName)
        $n = $data.Length
        $first = 0
        if ($n -gt 0) {
            $need = [int][Math]::Ceiling($n / $ClusterBytes)
            $prev = 0
            for ($k = 0; $k -lt $need; $k++) {
                $c = AllocCluster
                if ($k -eq 0) { $first = $c }
                if ($prev -ne 0) { $fat[$prev] = $c }
                $fat[$c] = 0xFFFF
                $prev = $c
                $cb = ClusOff $c
                $off = $k * $ClusterBytes
                $len = [Math]::Min($ClusterBytes, $n - $off)
                [Array]::Copy($data, $off, $buf, $cb, $len)
            }
        }
        AddEntry $d $f.Name 0x20 $first $n
        $fileCount++; $byteCount += $n
    }
}

# ---- 把 FAT 表写进两份 ----
for ($k = 0; $k -lt $NFATS; $k++) {
    $base = VolOff ($RSVD + $k * $fatSz)
    for ($c = 0; $c -le ($ClusterCount + 1); $c++) {
        W16 $buf ($base + $c * 2) $fat[$c]
    }
}

[System.IO.File]::WriteAllBytes($Out, $buf)
Write-Host ("  已生成 " + $Out + "  (" + [Math]::Round($buf.Length / 1MB, 1) + " MB, " + $fileCount + " 个文件, " + $byteCount + " 字节, 用了 " + ($script:nextClus - 2) + " 簇)")
