#requires -Version 5.1
<#
TripleWalkSpeed —— 《空洞骑士》常规水平移速 x3 补丁（分发版，包 v1.5.0）

零依赖：仅使用 Windows 自带的 PowerShell 5.1 / .NET Framework，不需要 Python、
不需要 Mod 加载器、不需要把任何 DLL 放进游戏目录。

原理：
  HeroController.Move(float) 的常规地面/空中分支 IL 为（7 字节，全文件唯一）
      ldarg.0 ; 02              压入 this
      ldfld <速度字段> ; 7B + 4  弹出 this，压入速度（净栈 0）
      mul ; 5A                 弹出 2 个值，压入乘积
  等长替换为
      nop ; 00                 不压栈
      ldc.r4 <3 倍值> ; 22 + 4 压入常量
      mul ; 5A
  替换前后整个方法体的栈深度序列一致（v1.0.0 只换 ldfld 会导致
  InvalidProgramException，人物无法左右移动，务必勿重犯）。

只改 4 处 7 字节中的 24 个字节；其余字节、其它游戏文件完全不动。
UNDERWATER_SPEED 分支、冲刺/跳跃/墙跳/碰撞/动画/存档相关字段与代码不变。

用法：
  powershell -NoProfile -ExecutionPolicy Bypass -File TripleWalkSpeed.ps1 -Action apply
  powershell -NoProfile -ExecutionPolicy Bypass -File TripleWalkSpeed.ps1 -Action verify
  powershell -NoProfile -ExecutionPolicy Bypass -File TripleWalkSpeed.ps1 -Action restore
  powershell -NoProfile -ExecutionPolicy Bypass -File TripleWalkSpeed.ps1 -Action info
  可选参数：-GameDir "D:\...\Hollow Knight"  -DllPath "..."  -Yes  -DryRun  -NoLogCheck
#>

[CmdletBinding()]
param(
    [ValidateSet('apply', 'verify', 'restore', 'info', 'menu')]
    [string]$Action = 'menu',
    [string]$GameDir = '',
    [string]$DllPath = '',
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$NoLogCheck
)

$ErrorActionPreference = 'Stop'
$script:Root      = $PSScriptRoot
$script:SpecPath  = Join-Path $Root 'patch_spec.json'
$script:BackupDir = Join-Path $Root 'backups'
$script:InsnLen   = 7
$script:UwHex     = '027B800400045A'   # 水下分支不变式：ldarg.0; ldfld UNDERWATER_SPEED; mul
$script:Latin1    = [System.Text.Encoding]::GetEncoding(28591)  # 字节 <-> 字符 1:1 映射

# ------------------------------------------------------------------ 基础工具

function Write-Line([string]$Text, [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
}

function Stop-WithError([string]$Text) {
    Write-Host '' 
    Write-Host "[失败] $Text" -ForegroundColor Red
    Write-Host ''
    exit 2
}

function Get-Sha256Hex([byte[]]$Bytes) {
    $alg = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($alg.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $alg.Dispose()
    }
}

function ConvertFrom-HexBytes([string]$Hex) {
    $arr = New-Object 'byte[]' ([int]($Hex.Length / 2))
    for ($i = 0; $i -lt $arr.Length; $i++) {
        $arr[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
    }
    return ,$arr
}

function ConvertTo-HexBytes([byte[]]$Bytes) {
    return ([BitConverter]::ToString($Bytes)).Replace('-', '').ToUpperInvariant()
}

function ConvertFrom-HexInt([string]$Text) {
    $s = $Text.Trim()
    if ($s.StartsWith('0x') -or $s.StartsWith('0X')) { $s = $s.Substring(2) }
    return [Convert]::ToInt32($s, 16)
}

function Test-BytesEqual([byte[]]$A, [byte[]]$B) {
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}

function Find-All([string]$Haystack, [string]$Needle) {
    $res = New-Object 'System.Collections.Generic.List[int]'
    $idx = $Haystack.IndexOf($Needle, [StringComparison]::Ordinal)
    while ($idx -ge 0 -and $res.Count -lt 10) {
        [void]$res.Add($idx)
        $idx = $Haystack.IndexOf($Needle, $idx + 1, [StringComparison]::Ordinal)
    }
    return $res.ToArray()
}

function New-ByteList {
    return New-Object 'System.Collections.Generic.List[byte]'
}

function New-MatchBytes([int]$Token) {
    $lst = New-ByteList
    [void]$lst.Add([byte]0x02)      # ldarg.0
    [void]$lst.Add([byte]0x7B)      # ldfld
    $tokBytes = [BitConverter]::GetBytes([uint32]$Token)
    if (-not [BitConverter]::IsLittleEndian) { [Array]::Reverse($tokBytes) }
    foreach ($b in $tokBytes) { [void]$lst.Add($b) }
    [void]$lst.Add([byte]0x5A)      # mul
    return ,$lst.ToArray()
}

function New-ReplaceBytes([double]$Value) {
    $lst = New-ByteList
    [void]$lst.Add([byte]0x00)      # nop
    [void]$lst.Add([byte]0x22)      # ldc.r4
    $f = [BitConverter]::GetBytes([float]$Value)
    if (-not [BitConverter]::IsLittleEndian) { [Array]::Reverse($f) }
    foreach ($b in $f) { [void]$lst.Add($b) }
    [void]$lst.Add([byte]0x5A)      # mul
    return ,$lst.ToArray()
}

# ------------------------------------------------------------------ 规格读取与自检

function Read-Spec {
    if (-not (Test-Path -LiteralPath $script:SpecPath -PathType Leaf)) {
        Stop-WithError "找不到补丁规格 patch_spec.json（应与本脚本在同一目录）"
    }
    $raw = [System.IO.File]::ReadAllText($script:SpecPath, [System.Text.Encoding]::UTF8)
    try {
        $spec = $raw | ConvertFrom-Json
    } catch {
        Stop-WithError "patch_spec.json 解析失败：$_"
    }
    if ($spec.schema_version -ne 2) { Stop-WithError "不支持的补丁规格版本：$($spec.schema_version)" }
    return $spec
}

function Build-Sites([object]$Spec) {
    $sites = @()
    foreach ($p in $Spec.patches) {
        $token = ConvertFrom-HexInt $p.token
        $offset = ConvertFrom-HexInt $p.file_offset
        [byte[]]$match  = ConvertFrom-HexBytes $p.match_hex
        [byte[]]$repl   = ConvertFrom-HexBytes $p.replace_hex
        if ($match.Length -ne $script:InsnLen -or $repl.Length -ne $script:InsnLen) {
            Stop-WithError "$($p.field): 指令长度不是 $($script:InsnLen) 字节"
        }
        # 审计：字节序列必须与「由 token / 目标常量推出的语义」严格一致
        [byte[]]$expMatch = New-MatchBytes $token
        [byte[]]$expRepl  = New-ReplaceBytes ([double]$p.tripled)
        if (-not (Test-BytesEqual $match $expMatch)) {
            Stop-WithError "$($p.field): match_hex 不是 ldarg.0; ldfld <字段>; mul"
        }
        if (-not (Test-BytesEqual $repl $expRepl)) {
            Stop-WithError "$($p.field): replace_hex 不是 nop; ldc.r4 <3 倍值>; mul"
        }
        if ($repl[6] -ne 0x5A -or $match[6] -ne 0x5A) {
            Stop-WithError "$($p.field): mul 指令被改动"
        }
        $expected = ([double]$p.original) * ([double]$Spec.multiplier)
        if ([Math]::Abs(([double]$p.tripled) - $expected) -gt 0.001) {
            Stop-WithError "$($p.field): tripled 不是原值的 $($Spec.multiplier) 倍"
        }
        $changed = @()
        for ($j = 0; $j -lt $script:InsnLen; $j++) {
            if ($match[$j] -ne $repl[$j]) { $changed += $j }
        }
        $sites += [pscustomobject]@{
            Field    = $p.field
            Branch   = $p.branch
            Original = [double]$p.original
            Tripled  = [double]$p.tripled
            Offset   = $offset
            Match    = $match
            Replace  = $repl
            Changed  = $changed
        }
    }
    if ($sites.Count -eq 0) { Stop-WithError '规格中没有补丁条目' }
    return $sites
}

# ------------------------------------------------------------------ 定位游戏 DLL

function Test-TargetDll([string]$Dir, [string]$Rel) {
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $null }
    try {
        $p = [System.IO.Path]::Combine($Dir, $Rel)
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    } catch { }
    return $null
}

function Get-GameDll([object]$Spec) {
    $rel = ([string]$Spec.target_relative_path).Replace('/', '\')

    if (-not [string]::IsNullOrWhiteSpace($DllPath)) {
        if (Test-Path -LiteralPath $DllPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $DllPath).Path
        }
        Stop-WithError "指定的 DLL 不存在：$DllPath"
    }

    $dirs = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($GameDir)) { [void]$dirs.Add($GameDir) }
    if ($env:HK_GAME_DIR) { [void]$dirs.Add($env:HK_GAME_DIR) }

    # 手动指定：与本脚本同目录的 game_dir.txt 第一行
    $hint = Join-Path $script:Root 'game_dir.txt'
    if (Test-Path -LiteralPath $hint -PathType Leaf) {
        # 记事本可能存成 UTF-8 或系统 ANSI；中文路径用错编码会乱码，两种都试
        foreach ($enc in @([System.Text.Encoding]::UTF8, [System.Text.Encoding]::Default)) {
            try {
                $rawHint = [System.IO.File]::ReadAllText($hint, $enc)
                foreach ($line in ($rawHint -split "\r?\n")) {
                    $t = ([string]$line).Trim().Trim('"').Trim([char]0xFEFF)
                    if ($t -and -not $t.StartsWith('#')) { [void]$dirs.Add($t); break }
                }
            } catch { }
        }
    }

    # 规格中的示例路径
    foreach ($d in $Spec.reference_game_dirs) { [void]$dirs.Add([string]$d) }

    # Steam 卸载注册表项（AppID 367520）
    foreach ($k in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 367520',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 367520',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 367520')) {
        if (Test-Path -LiteralPath $k) {
            $v = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
            if ($v -and $v.InstallLocation) { [void]$dirs.Add([string]$v.InstallLocation) }
        }
    }

    # Steam 安装目录 + libraryfolders.vdf 中的所有库
    $steamRoots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in @(
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam',
        'HKCU:\SOFTWARE\Valve\Steam')) {
        if (Test-Path -LiteralPath $k) {
            $v = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
            if ($v -and $v.InstallPath) { [void]$steamRoots.Add([string]$v.InstallPath) }
            if ($v -and $v.SteamPath)   { [void]$steamRoots.Add([string]$v.SteamPath) }
        }
    }
    if ($env:ProgramFiles)        { [void]$steamRoots.Add([System.IO.Path]::Combine($env:ProgramFiles, 'Steam')) }
    if (${env:ProgramFiles(x86)}) { [void]$steamRoots.Add([System.IO.Path]::Combine(${env:ProgramFiles(x86)}, 'Steam')) }
    foreach ($sr in $steamRoots) {
        [void]$dirs.Add([System.IO.Path]::Combine($sr, 'steamapps\common\Hollow Knight'))
        $vdf = [System.IO.Path]::Combine($sr, 'steamapps\libraryfolders.vdf')
        if (Test-Path -LiteralPath $vdf -PathType Leaf) {
            $txt = Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue
            if ($txt) {
                foreach ($m in [regex]::Matches($txt, '"path"\s*"([^"]+)"')) {
                    $lib = $m.Groups[1].Value.Replace('\\', '\')
                    [void]$dirs.Add([System.IO.Path]::Combine($lib, 'steamapps\common\Hollow Knight'))
                }
            }
        }
    }

    # 各固定盘符的常见位置
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
        [void]$dirs.Add([System.IO.Path]::Combine($d.Name, 'SteamLibrary\steamapps\common\Hollow Knight'))
        [void]$dirs.Add([System.IO.Path]::Combine($d.Name, 'Steam\steamapps\common\Hollow Knight'))
        [void]$dirs.Add([System.IO.Path]::Combine($d.Name, 'Program Files (x86)\Steam\steamapps\common\Hollow Knight'))
        [void]$dirs.Add([System.IO.Path]::Combine($d.Name, 'Games\Hollow Knight'))
    }

    $seen = @{}
    foreach ($d in $dirs) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        if ($seen.ContainsKey($d)) { continue }
        $seen[$d] = $true
        $p = Test-TargetDll $d $rel
        if ($p) { return (Resolve-Path -LiteralPath $p).Path }
    }

    Stop-WithError @"
找不到 $($Spec.target_relative_path)。
请在本脚本同目录新建 game_dir.txt，第一行写游戏根目录（含 hollow_knight_Data 的那一层），例如：
    D:\SteamLibrary\steamapps\common\Hollow Knight
或用参数指定：
    powershell -ExecutionPolicy Bypass -File TripleWalkSpeed.ps1 -Action apply -GameDir "D:\...\Hollow Knight"
"@
}

# ------------------------------------------------------------------ 状态判定

function Get-State([byte[]]$Data, [object]$Spec, [array]$Sites) {
    $res = [pscustomobject]@{
        State   = 'reject'
        Mode    = 'none'
        Hash    = ''
        Offsets = @()
        Reason  = ''
    }
    $res.Hash = Get-Sha256Hex $Data
    if ($Data.Length -ne [int]$Spec.original_size) {
        $res.Reason = "文件大小 $($Data.Length) 与规格 $($Spec.original_size) 不符"
        return $res
    }
    if ($res.Hash -eq $Spec.original_sha256) {
        $res.State = 'vanilla'; $res.Mode = 'strict'
        $res.Offsets = @($Sites | ForEach-Object { $_.Offset })
        return $res
    }
    if ($res.Hash -eq $Spec.patched_sha256) {
        $res.State = 'patched'; $res.Mode = 'strict'
        $res.Offsets = @($Sites | ForEach-Object { $_.Offset })
        return $res
    }

    # 兼容模式：哈希不同（例如不同地区/平台构建、装了其它 mod），
    # 但要求 4 个模式各唯一命中、相对间距与规格一致、水下分支不变、大小一致。
    $hay = $script:Latin1.GetString($Data)
    $mOff = @(); $rOff = @()
    foreach ($s in $Sites) {
        $mh = @(Find-All $hay ($script:Latin1.GetString($s.Match)))
        $rh = @(Find-All $hay ($script:Latin1.GetString($s.Replace)))
        if ($mh.Count -ne 1 -and $rh.Count -ne 1) {
            $res.Reason = "$($s.Field): 目标指令模式未唯一命中（布局已变化，游戏版本可能不同）"
            return $res
        }
        if ($mh.Count -gt 1 -or $rh.Count -gt 1) {
            $res.Reason = "$($s.Field): 目标指令模式出现多次，拒绝猜测"
            return $res
        }
        if ($mh.Count -eq 1) { $mOff += $mh[0] } else { $mOff += -1 }
        if ($rh.Count -eq 1) { $rOff += $rh[0] } else { $rOff += -1 }
    }
    [byte[]]$uw = ConvertFrom-HexBytes $script:UwHex
    $uwHits = @(Find-All $hay ($script:Latin1.GetString($uw)))
    if ($uwHits.Count -ne 1) {
        $res.Reason = '水下分支不变式不成立，程序集布局与规格不符'
        return $res
    }

    $matchCount = @($mOff | Where-Object { $_ -ge 0 }).Count
    $replCount  = @($rOff | Where-Object { $_ -ge 0 }).Count
    $allMatch = $matchCount -eq $Sites.Count
    $allRepl  = $replCount -eq $Sites.Count
    if (-not ($allMatch -or $allRepl)) {
        $res.Reason = '原版指令与补丁版指令混合出现，文件状态异常'
        return $res
    }
    $offs = if ($allMatch) { $mOff } else { $rOff }
    $specDeltas = @(); $actDeltas = @()
    for ($i = 1; $i -lt $Sites.Count; $i++) {
        $specDeltas += ($Sites[$i].Offset - $Sites[$i - 1].Offset)
        $actDeltas  += ($offs[$i] - $offs[$i - 1])
    }
    for ($i = 0; $i -lt $specDeltas.Count; $i++) {
        if ($specDeltas[$i] -ne $actDeltas[$i]) {
            $res.Reason = '目标指令的相对间距与规格不一致，程序集布局不同'
            return $res
        }
    }
    $res.State = if ($allMatch) { 'vanilla' } else { 'patched' }
    $res.Mode = 'similar'
    $res.Offsets = $offs
    return $res
}

# ------------------------------------------------------------------ 字节构造 / 校验

function New-PatchedBytes([byte[]]$Data, [array]$Sites, [array]$Offsets) {
    $out = [byte[]]$Data.Clone()
    for ($i = 0; $i -lt $Sites.Count; $i++) {
        for ($j = 0; $j -lt $script:InsnLen; $j++) {
            $out[$Offsets[$i] + $j] = $Sites[$i].Replace[$j]
        }
    }
    return ,$out
}

function New-VanillaBytes([byte[]]$Data, [array]$Sites, [array]$Offsets) {
    $out = [byte[]]$Data.Clone()
    for ($i = 0; $i -lt $Sites.Count; $i++) {
        for ($j = 0; $j -lt $script:InsnLen; $j++) {
            $out[$Offsets[$i] + $j] = $Sites[$i].Match[$j]
        }
    }
    return ,$out
}

function Test-ChangeSet([byte[]]$Before, [byte[]]$After, [array]$Sites, [array]$Offsets) {
    # 1) 区间内只有白名单字节不同
    $allowed = @{}
    for ($i = 0; $i -lt $Sites.Count; $i++) {
        foreach ($j in $Sites[$i].Changed) { $allowed[($Offsets[$i] + $j)] = $true }
    }
    for ($i = 0; $i -lt $Sites.Count; $i++) {
        for ($j = 0; $j -lt $script:InsnLen; $j++) {
            $pos = $Offsets[$i] + $j
            if ($Before[$pos] -ne $After[$pos] -and -not $allowed.ContainsKey($pos)) {
                return "站点 $($Sites[$i].Field) 的 +$j 字节发生越界改动"
            }
        }
    }
    # 2) 反向恢复 4 个区间后，整体哈希必须与改动前完全一致
    $proof = [byte[]]$After.Clone()
    for ($i = 0; $i -lt $Sites.Count; $i++) {
        for ($j = 0; $j -lt $script:InsnLen; $j++) {
            $proof[$Offsets[$i] + $j] = $Sites[$i].Match[$j]
        }
    }
    if ((Get-Sha256Hex $proof) -ne (Get-Sha256Hex $Before)) {
        return '反向恢复后哈希不一致：除 4 个目标区间外还有其它字节被改动'
    }
    return ''
}

function Write-Dll([string]$Path, [byte[]]$Bytes) {
    $want = Get-Sha256Hex $Bytes
    $tmp = $Path + '.twstmp'
    try {
        [System.IO.File]::WriteAllBytes($tmp, $Bytes)
        if ((Get-Sha256Hex ([System.IO.File]::ReadAllBytes($tmp))) -ne $want) {
            throw '临时文件校验失败'
        }
        # 原地覆盖：不删除、不重建 DLL（部分 Windows 环境替换该 DLL 会 WinError 5）
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $fs.Write($Bytes, 0, $Bytes.Length)
            $fs.SetLength($Bytes.Length)
            $fs.Flush($true)
        } finally {
            $fs.Dispose()
        }
        if ((Get-Sha256Hex ([System.IO.File]::ReadAllBytes($Path))) -ne $want) {
            throw '写入后回读校验失败'
        }
    } finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Save-Backup([byte[]]$Vanilla, [string]$Hash) {
    if (-not (Test-Path -LiteralPath $script:BackupDir)) {
        New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    }
    $main = Join-Path $script:BackupDir 'Assembly-CSharp.dll.vanilla'
    if (-not (Test-Path -LiteralPath $main -PathType Leaf)) {
        [System.IO.File]::WriteAllBytes($main, $Vanilla)
        return $main
    }
    if ((Get-Sha256Hex ([System.IO.File]::ReadAllBytes($main))) -eq $Hash) { return $main }
    $alt = Join-Path $script:BackupDir ('Assembly-CSharp.dll.vanilla-' + $Hash.Substring(0, 8))
    [System.IO.File]::WriteAllBytes($alt, $Vanilla)
    return $alt
}

function Test-PlayerLog {
    $p = Join-Path $env:USERPROFILE 'AppData\LocalLow\Team Cherry\Hollow Knight\Player.log'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        Write-Line '  Player.log        : 未找到（可能还没启动过游戏）' 'DarkGray'
        return $true
    }
    $txt = [System.IO.File]::ReadAllText($p)
    # 只看最后一次启动之后的内容，避免旧日志误报
    $idx = $txt.LastIndexOf('Begin MonoManager ReloadAssembly', [StringComparison]::Ordinal)
    if ($idx -ge 0) { $txt = $txt.Substring($idx) }
    $bad = [regex]::Matches($txt, 'InvalidProgramException|Invalid IL code')
    $stamp = (Get-Item -LiteralPath $p).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    if ($bad.Count -gt 0) {
        Write-Line "  Player.log        : [警告] 最近一次启动出现 $($bad.Count) 条 IL 异常！" 'Red'
        Write-Line  '                       建议运行 Restore.bat 还原，并把日志发给补丁作者。' 'Red'
        return $false
    }
    Write-Line "  Player.log        : 本次启动未发现 IL 异常（日志更新 $stamp）" 'Green'
    return $true
}

# ------------------------------------------------------------------ 各命令

function Show-Info([object]$Spec, [array]$Sites) {
    Write-Line ''
    Write-Line "TripleWalkSpeed v$($Spec.mod_version) —— 常规地面/空中水平移速 x$('{0:0.#}' -f [double]$Spec.multiplier)" 'Cyan'
    Write-Line "适用游戏 : Hollow Knight $($Spec.target_game_version) / Unity $($Spec.target_unity_version)" 'White'
    Write-Line "目标文件 : $($Spec.target_relative_path)" 'White'
    Write-Line "原版哈希 : $($Spec.original_sha256)" 'White'
    Write-Line "补丁哈希 : $($Spec.patched_sha256)" 'White'
    Write-Line "改动字节 : $($Spec.changed_bytes_total) 字节（4 处各 6 字节），文件大小与指令数不变" 'White'
    Write-Line ''
    Write-Line '  字段                    原值  ->  新值     文件偏移    match -> replace' 'Gray'
    foreach ($s in $Sites) {
        Write-Line ("  {0,-22} {1,5:N1} -> {2,5:N1}   0x{3:X6}   {4} -> {5}" -f `
            $s.Field, $s.Original, $s.Tripled, $s.Offset,
            (ConvertTo-HexBytes $s.Match), (ConvertTo-HexBytes $s.Replace)) 'Gray'
    }
    Write-Line ''
    Write-Line '  栈平衡 : ldarg.0; ldfld; mul  ( +1 / 净0 / -1 )' 'Yellow'
    Write-Line '            -> nop; ldc.r4; mul (  0  /  +1 / -1 )  栈深度序列一致' 'Yellow'
    Write-Line '  水下   : UNDERWATER_SPEED 分支保持 027B800400045A 原样' 'Yellow'
    Write-Line ''
}

function Invoke-Apply([object]$Spec, [array]$Sites, [string]$Dll) {
    [byte[]]$data = [System.IO.File]::ReadAllBytes($Dll)
    $st = Get-State $data $Spec $Sites

    if ($st.State -eq 'patched') {
        Write-Line "[跳过] 3 倍移速补丁已经安装（$($st.Mode) 模式）。" 'Green'
        Write-Line "        SHA-256: $($st.Hash)" 'Gray'
        return 0
    }
    if ($st.State -eq 'reject') {
        Stop-WithError "目标 DLL 与补丁规格不匹配：$($st.Reason)`n        实际 SHA-256: $($st.Hash)`n        期望 SHA-256: $($Spec.original_sha256)`n        请确认游戏版本为 $($Spec.target_game_version)，且未被其它 mod 修改。"
    }

    Write-Line "目标文件 : $Dll" 'White'
    Write-Line "当前状态 : 原版（$($st.Mode) 模式），SHA-256 $($st.Hash)" 'White'
    if ($st.Mode -eq 'similar') {
        Write-Line '' 
        Write-Line '[注意] 该文件哈希与标准原版不同，但 4 处目标指令唯一命中、' 'Yellow'
        Write-Line '       相对间距与规格一致、水下分支未变，判定为同版本的不同构建。' 'Yellow'
        Write-Line '       若你装过其它修改 Assembly-CSharp.dll 的 mod，请谨慎继续。' 'Yellow'
        if (-not $Yes) {
            $a = Read-Host '        输入 Y 继续安装，其它任意键取消'
            if ($a -ne 'Y' -and $a -ne 'y') { Write-Line '[取消] 未做任何改动。' 'Yellow'; return 1 }
        }
    }

    [byte[]]$patched = New-PatchedBytes $data $Sites $st.Offsets
    $err = Test-ChangeSet $data $patched $Sites $st.Offsets
    if ($err) { Stop-WithError "字节差异校验失败：$err" }

    $changedCount = 0
    foreach ($s in $Sites) { $changedCount += $s.Changed.Count }
    Write-Line ''
    Write-Line "校验通过 : 文件大小 $($patched.Length) 字节不变，差异 $changedCount 字节，越界 0 字节" 'Green'
    Write-Line '  字段                    原值  ->  新值      实际偏移' 'Gray'
    for ($i = 0; $i -lt $Sites.Count; $i++) {
        Write-Line ("  {0,-22} {1,5:N1} -> {2,5:N1}   0x{3:X6}" -f `
            $Sites[$i].Field, $Sites[$i].Original, $Sites[$i].Tripled, $st.Offsets[$i]) 'Gray'
    }

    if ($DryRun) {
        Write-Line ''
        Write-Line '[DryRun] 仅校验，未写入任何文件。' 'Yellow'
        return 0
    }

    $bk = Save-Backup $data $st.Hash
    Write-Line ''
    Write-Line "备份     : $bk" 'White'

    # 若游戏正在运行，DLL 可能被占用，给出明确提示
    $running = @(Get-Process -Name 'hollow_knight' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Line ''
        Write-Line '[警告] 检测到游戏正在运行，请先完全退出游戏再安装，否则可能写入失败。' 'Yellow'
    }
    try {
        Write-Dll $Dll $patched
    } catch {
        Stop-WithError "写入失败：$($_)`n        若游戏装在 C:\Program Files，请右键 Install.bat 选「以管理员身份运行」；`n        也可先关闭杀毒软件实时防护后重试。当前 DLL 未被改动。"
    }

    Write-Line ''
    Write-Line "[完成] 已安装 3 倍移速补丁，SHA-256: $(Get-Sha256Hex ([System.IO.File]::ReadAllBytes($Dll)))" 'Green'
    Write-Line '       直接启动游戏即可生效（无需任何 mod 加载器，标题界面不会出现 mod 列表）。' 'Green'
    Write-Line '       建议运行 Verify.bat 复核，并在游戏里左右走两步确认移动正常。' 'Green'
    return 0
}

function Invoke-Verify([object]$Spec, [array]$Sites, [string]$Dll) {
    [byte[]]$data = [System.IO.File]::ReadAllBytes($Dll)
    $st = Get-State $data $Spec $Sites
    $map = @{ vanilla = '原版（未安装补丁）'; patched = '已安装 3 倍移速补丁 v1.1.0'; reject = '未知 / 不匹配' }
    Write-Line ''
    Write-Line "目标文件 : $Dll" 'White'
    Write-Line "SHA-256  : $($st.Hash)" 'White'
    Write-Line "文件大小 : $($data.Length) 字节" 'White'
    $color = if ($st.State -eq 'patched') { 'Green' } elseif ($st.State -eq 'vanilla') { 'Yellow' } else { 'Red' }
    Write-Line "状态     : $($map[$st.State])  [$($st.Mode) 模式]" $color
    if ($st.Reason) { Write-Line "原因     : $($st.Reason)" 'Red' }
    Write-Line ''

    $ok = $true
    if ($st.State -ne 'reject') {
        $offs = $st.Offsets
        for ($i = 0; $i -lt $Sites.Count; $i++) {
            $actual = New-Object 'byte[]' $script:InsnLen
            [Array]::Copy($data, $offs[$i], $actual, 0, $script:InsnLen)
            $want = if ($st.State -eq 'patched') { $Sites[$i].Replace } else { $Sites[$i].Match }
            $good = Test-BytesEqual $actual $want
            Write-Line ("  {0,-22} 0x{1:X6}  {2}  {3}  期望 {4}" -f `
                $Sites[$i].Field, $offs[$i], (ConvertTo-HexBytes $actual),
                $(if ($good) { 'OK  ' } else { '异常' }), (ConvertTo-HexBytes $want)) `
                $(if ($good) { 'Green' } else { 'Red' })
            if (-not $good) { $ok = $false }
        }
        $hay = $script:Latin1.GetString($data)
        [byte[]]$uw = ConvertFrom-HexBytes $script:UwHex
        $uwOk = @(Find-All $hay ($script:Latin1.GetString($uw))).Count -eq 1
        Write-Line ("  {0,-22} {1}  水下分支保持 027B800400045A: {2}" -f `
            'UNDERWATER_SPEED', '        ', $(if ($uwOk) { 'OK' } else { '异常' })) `
            $(if ($uwOk) { 'Green' } else { 'Red' })
        if (-not $uwOk) { $ok = $false }

        # 与备份逐字节比较（用反向恢复后的哈希做等价证明，避免逐字节大循环）
        if (Test-Path -LiteralPath $script:BackupDir) {
            $bks = @(Get-ChildItem -LiteralPath $script:BackupDir -Filter 'Assembly-CSharp.dll.vanilla*' -File -ErrorAction SilentlyContinue)
            $matched = $false
            foreach ($b in $bks) {
                [byte[]]$bkData = [System.IO.File]::ReadAllBytes($b.FullName)
                if ($bkData.Length -ne $data.Length) { continue }
                $proof = if ($st.State -eq 'patched') {
                    New-VanillaBytes $data $Sites $st.Offsets
                } else {
                    [byte[]]$data.Clone()
                }
                if ((Get-Sha256Hex $bkData) -eq (Get-Sha256Hex $proof)) {
                    $diffCount = 0
                    foreach ($s in $Sites) { $diffCount += $s.Changed.Count }
                    Write-Line ''
                    Write-Line ("  与备份逐字节比较: 差异 {0} 字节，越界改动 0 字节 -> OK（备份 {1}）" -f `
                        $(if ($st.State -eq 'patched') { $diffCount } else { 0 }), $b.Name) 'Green'
                    $matched = $true
                    break
                }
            }
            if (-not $matched) { Write-Line ''; Write-Line '  备份比较      : 未找到与当前文件匹配的备份（不影响补丁状态判定）' 'DarkGray' }
        } else {
            Write-Line ''; Write-Line '  备份比较      : 未找到备份（仍可用 Restore.bat 反向还原）' 'DarkGray'
        }
    } else {
        $ok = $false
    }

    if (-not $NoLogCheck) {
        Write-Line ''
        if (-not (Test-PlayerLog)) { $ok = $false }
    }

    Write-Line ''
    if ($ok -and $st.State -eq 'patched') {
        Write-Line '结论: PASS —— 补丁状态正确，无越界改动，无 IL 异常' 'Green'
        return 0
    } elseif ($ok -and $st.State -eq 'vanilla') {
        Write-Line '结论: PASS —— 当前是原版，补丁未安装' 'Yellow'
        return 0
    }
    Write-Line '结论: FAIL —— 请检查上面的异常项，必要时运行 Restore.bat 还原' 'Red'
    return 1
}

function Invoke-Restore([object]$Spec, [array]$Sites, [string]$Dll) {
    [byte[]]$data = [System.IO.File]::ReadAllBytes($Dll)
    $st = Get-State $data $Spec $Sites
    if ($st.State -eq 'vanilla') {
        Write-Line '[跳过] 当前已是原版 DLL，无需还原。' 'Green'
        return 0
    }
    if ($st.State -eq 'reject') {
        Stop-WithError "无法识别当前 DLL 状态（$($st.Reason)），拒绝盲目还原。请用 Steam「验证游戏文件完整性」修复。"
    }

    [byte[]]$guess = New-VanillaBytes $data $Sites $st.Offsets
    # 校验还原结果本身就是合法原版：严格模式下哈希必须等于规格中的原版哈希，
    # 兼容模式下 4 处 match 唯一、布局与规格一致。比字节差异比较更直接可靠。
    $restoredState = Get-State $guess $Spec $Sites
    if ($restoredState.State -ne 'vanilla') {
        Stop-WithError "反向还原校验失败：还原后状态为 $($restoredState.State)（$($restoredState.Reason)）"
    }

    [byte[]]$restore = $guess
    $source = '反向替换 replace -> match（无可用备份）'
    if (Test-Path -LiteralPath $script:BackupDir) {
        $bks = @(Get-ChildItem -LiteralPath $script:BackupDir -Filter 'Assembly-CSharp.dll.vanilla*' -File -ErrorAction SilentlyContinue)
        foreach ($b in $bks) {
            [byte[]]$bkData = [System.IO.File]::ReadAllBytes($b.FullName)
            if ((Get-Sha256Hex $bkData) -eq (Get-Sha256Hex $guess)) {
                $restore = $bkData
                $source = "备份 $($b.FullName)"
                break
            }
        }
    }
    if ($DryRun) {
        Write-Line "[DryRun] 可还原，来源: $source；未写入。" 'Yellow'
        return 0
    }
    try {
        Write-Dll $Dll $restore
    } catch {
        Stop-WithError "写入失败：$($_)。请右键 Restore.bat 选「以管理员身份运行」。"
    }
    Write-Line "[完成] 已还原原版 DLL（来源: $source）" 'Green'
    Write-Line "        SHA-256: $(Get-Sha256Hex ([System.IO.File]::ReadAllBytes($Dll)))" 'Green'
    return 0
}

# ------------------------------------------------------------------ 入口

$spec = Read-Spec
$sites = @(Build-Sites $spec)

if ($Action -eq 'menu') {
    Write-Line ''
    Write-Line '==========================================================' 'Cyan'
    Write-Line '  TripleWalkSpeed —— 空洞骑士 常规水平移速 x3（包 v1.5.0）' 'Cyan'
    Write-Line '  适用版本: Hollow Knight 1.5.12620 / Unity 6000.0.61f1' 'Cyan'
    Write-Line '==========================================================' 'Cyan'
    Write-Line '  1) 安装补丁（3 倍移速）' 'White'
    Write-Line '  2) 检查当前状态' 'White'
    Write-Line '  3) 还原原版 DLL' 'White'
    Write-Line '  4) 查看技术信息' 'White'
    Write-Line '  0) 退出' 'White'
    Write-Line ''
    $c = Read-Host '请输入数字后回车'
    switch ($c) {
        '1' { $Action = 'apply' }
        '2' { $Action = 'verify' }
        '3' { $Action = 'restore' }
        '4' { $Action = 'info' }
        default { Write-Line '已退出。' 'Gray'; exit 0 }
    }
}

if ($Action -eq 'info') {
    Show-Info $spec $sites
    exit 0
}

$dll = Get-GameDll $spec
try {
    switch ($Action) {
        'apply'   { $code = Invoke-Apply   $spec $sites $dll }
        'verify'  { $code = Invoke-Verify  $spec $sites $dll }
        'restore' { $code = Invoke-Restore $spec $sites $dll }
    }
} catch {
    Stop-WithError "$($_.Exception.GetType().Name): $($_.Exception.Message)"
}
exit $code
