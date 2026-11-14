# BenchWarp —— 长椅互相传送 mod 的构建 / 安装 / 卸载脚本
#
# 用法（一般由同目录的 Build.bat / Install.bat / Uninstall.bat 调用，也可直接运行）：
#   powershell -ExecutionPolicy Bypass -File BenchWarp.ps1 -Action build
#   powershell -ExecutionPolicy Bypass -File BenchWarp.ps1 -Action install
#   powershell -ExecutionPolicy Bypass -File BenchWarp.ps1 -Action uninstall
#   powershell -ExecutionPolicy Bypass -File BenchWarp.ps1 -Action status
#
# 它做三件事：
#   1) 用本机 .NET SDK 把 BenchWarp.cs 编译成 BenchWarp.dll（不改任何游戏文件）
#   2) 把 DLL 放进 hollow_knight_Data\Managed\，并在两份 Unity 清单里登记：
#        ScriptingAssemblies.json        -> 让 Unity 启动时加载这个程序集
#        RuntimeInitializeOnLoads.json   -> 让 Unity 启动后调用 Bootstrap.Init()
#   3) 卸载时把这两份 JSON 精确还原（不依赖备份也能按条目移除）

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('build', 'install', 'uninstall', 'status')]
    [string]$Action,

    [string]$GameDir = ''
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ModAsm = 'BenchWarp'          # 程序集名（无扩展名）
$script:ModDll = 'BenchWarp.dll'
$script:ModNs = 'BenchWarpMod'
$script:ModClass = 'Bootstrap'
$script:ModMethod = 'Init'
$script:RelDll = 'hollow_knight_Data\Managed\Assembly-CSharp.dll'

function Write-Line([string]$Text, [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
}

function Fail([string]$Text) {
    Write-Host ""
    Write-Host $Text -ForegroundColor Red
    Write-Host ""
    exit 1
}

# ---------------------------------------------------------------- 定位游戏目录

function Test-IsGameDir([string]$Dir) {
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    try {
        $p = [System.IO.Path]::Combine($Dir, $script:RelDll)
        return (Test-Path -LiteralPath $p -PathType Leaf)
    } catch { return $false }
}

function Get-InstallDir {
    $dirs = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($GameDir)) { [void]$dirs.Add($GameDir) }
    if ($env:HK_GAME_DIR) { [void]$dirs.Add($env:HK_GAME_DIR) }
    [void]$dirs.Add((Split-Path -Parent (Split-Path -Parent $script:Root)))

    # 与本脚本同目录（或包根目录）的 game_dir.txt
    foreach ($hint in @([System.IO.Path]::Combine($script:Root, 'game_dir.txt'),
                        [System.IO.Path]::Combine((Split-Path -Parent $script:Root), 'game_dir.txt'))) {
        if (-not (Test-Path -LiteralPath $hint -PathType Leaf)) { continue }
        foreach ($enc in @([System.Text.Encoding]::UTF8, [System.Text.Encoding]::Default)) {
            try {
                $raw = [System.IO.File]::ReadAllText($hint, $enc)
                foreach ($line in ($raw -split "\r?\n")) {
                    $t = ([string]$line).Trim().Trim('"').Trim([char]0xFEFF)
                    if ($t -and -not $t.StartsWith('#')) { [void]$dirs.Add($t); break }
                }
            } catch { }
        }
    }

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

    # Steam 根目录 + libraryfolders.vdf 里的所有库
    $steamRoots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam', 'HKCU:\SOFTWARE\Valve\Steam')) {
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

    # 各固定盘符常见位置
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
        if (Test-IsGameDir $d) { return (Resolve-Path -LiteralPath $d).Path }
    }

    Fail @"
找不到空洞骑士安装目录（需要包含 hollow_knight_Data\Managed\Assembly-CSharp.dll）。
请在包根目录新建 game_dir.txt，第一行写游戏根目录，例如：
    D:\SteamLibrary\steamapps\common\Hollow Knight
或用参数指定：
    powershell -ExecutionPolicy Bypass -File BenchWarp.ps1 -Action $Action -GameDir "D:\...\Hollow Knight"
"@
}

# ---------------------------------------------------------------- JSON 读写

function Read-JsonFile([string]$Path) {
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($raw | ConvertFrom-Json)
}

function Write-JsonFile([string]$Path, $Obj) {
    $json = $Obj | ConvertTo-Json -Compress -Depth 12
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $enc)
}

function Backup-Once([string]$Path) {
    $dir = [System.IO.Path]::Combine($script:Root, 'backups')
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $bak = [System.IO.Path]::Combine($dir, ([System.IO.Path]::GetFileName($Path) + '.orig'))
    if (-not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $Path -Destination $bak -Force
        Write-Line "  已备份原始清单：$bak" 'DarkGray'
    }
    return $bak
}

# ---------------------------------------------------------------- 编译

function Resolve-DotNet {
    $c = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @(
        [System.IO.Path]::Combine($env:ProgramFiles, 'dotnet\dotnet.exe'),
        [System.IO.Path]::Combine(${env:ProgramFiles(x86)}, 'dotnet\dotnet.exe'))) {
        if ($env:ProgramFiles -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
    }
    return $null
}

function Invoke-Build([string]$Managed) {
    Write-Line "`n== 编译 BenchWarp ==" 'Cyan'
    $dotnet = Resolve-DotNet
    if (-not $dotnet) {
        Fail @"
没有找到 .NET SDK（只有运行时不带编译器）。
请先双击同目录的 InstallSDK8.bat 一键安装（自动下载 + 校验 + 静默安装）。
装完新开一个窗口，再重新运行 Build.bat。
"@
    }
    # --list-sdks 在「只有运行时」时不会报错，只是没有输出，所以先查它
    $sdks = @()
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $sdks = @(& $dotnet --list-sdks 2>$null | Where-Object { $_ -and ([string]$_).Trim().Length -gt 0 })
    } catch { $sdks = @() }
    if ($sdks.Count -eq 0) {
        Fail @"
检测到 .NET 运行时（$dotnet），但没有安装 .NET SDK（缺少编译器），无法编译。
请先双击同目录的 InstallSDK8.bat 一键安装（自动下载 + SHA-512 校验 + 静默安装）。
装完新开一个窗口，再重新运行 Build.bat。

如果你已经装了 SDK 8 却仍报这个错，说明 PATH 还没刷新 —— 新开窗口即可。
"@
    }
    $ErrorActionPreference = $prevEap
    Write-Line "  SDK: $($sdks[0])"
    Write-Line "  引用程序集目录：$Managed"

    $csproj = [System.IO.Path]::Combine($script:Root, 'BenchWarp.csproj')
    if (-not (Test-Path -LiteralPath $csproj -PathType Leaf)) { Fail "缺少 BenchWarp.csproj" }

    & $dotnet build $csproj -c Release -v:m "-p:GameManaged=$Managed" 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { Fail "编译失败（退出码 $LASTEXITCODE）。请把上面的报错发给我。" }

    $dll = [System.IO.Path]::Combine($script:Root, 'bin', $script:ModDll)
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) { Fail "编译似乎成功，但没有找到 $dll" }
    $size = (Get-Item -LiteralPath $dll).Length
    Write-Line "`n编译成功：$dll ($size 字节)" 'Green'
    return $dll
}

# ---------------------------------------------------------------- 安装 / 卸载

function Install-Mod([string]$Dir) {
    $managed = [System.IO.Path]::Combine($Dir, 'hollow_knight_Data\Managed')
    $dataDir = [System.IO.Path]::Combine($Dir, 'hollow_knight_Data')
    $dllSrc = [System.IO.Path]::Combine($script:Root, 'bin', $script:ModDll)
    if (-not (Test-Path -LiteralPath $dllSrc -PathType Leaf)) {
        Write-Line "还没有编译产物，先编译。" 'Yellow'
        $dllSrc = Invoke-Build $managed
    }

    $proc = Get-Process -Name 'hollow_knight' -ErrorAction SilentlyContinue
    if ($proc) { Fail "游戏正在运行，请先完全退出游戏再安装（否则文件被占用）。" }

    Write-Line "`n== 安装 BenchWarp ==" 'Cyan'
    $dllDst = [System.IO.Path]::Combine($managed, $script:ModDll)
    Copy-Item -LiteralPath $dllSrc -Destination $dllDst -Force
    Write-Line "  已放置：$dllDst"

    # 1) ScriptingAssemblies.json
    $saPath = [System.IO.Path]::Combine($dataDir, 'ScriptingAssemblies.json')
    if (-not (Test-Path -LiteralPath $saPath -PathType Leaf)) { Fail "缺少 ScriptingAssemblies.json，游戏版本不符？" }
    [void](Backup-Once $saPath)
    $sa = Read-JsonFile $saPath
    $names = @($sa.names)
    $types = @($sa.types)
    if ($names -contains $script:ModDll) {
        Write-Line "  ScriptingAssemblies.json 已包含 $script:ModDll，跳过"
    } else {
        $sa.names = @($names + $script:ModDll)
        if ($types.Count -eq $names.Count) { $sa.types = @($types + 16) }
        Write-JsonFile $saPath $sa
        Write-Line "  ScriptingAssemblies.json：已登记 $script:ModDll"
    }

    # 2) RuntimeInitializeOnLoads.json
    $riPath = [System.IO.Path]::Combine($dataDir, 'RuntimeInitializeOnLoads.json')
    if (-not (Test-Path -LiteralPath $riPath -PathType Leaf)) { Fail "缺少 RuntimeInitializeOnLoads.json，游戏版本不符？" }
    [void](Backup-Once $riPath)
    $ri = Read-JsonFile $riPath
    $roots = @($ri.root)
    $exists = @($roots | Where-Object { $_ -and $_.assemblyName -eq $script:ModAsm }).Count -gt 0
    if ($exists) {
        Write-Line "  RuntimeInitializeOnLoads.json 已包含入口，跳过"
    } else {
        $entry = [pscustomobject][ordered]@{
            assemblyName = $script:ModAsm
            nameSpace    = $script:ModNs
            className    = $script:ModClass
            methodName   = $script:ModMethod
            loadTypes    = 0
            isUnityClass = $false
        }
        $ri.root = @($roots + $entry)
        Write-JsonFile $riPath $ri
        Write-Line "  RuntimeInitializeOnLoads.json：已登记入口 $script:ModNs.$script:ModClass.$script:ModMethod"
    }

    # 3) 回读校验
    $sa2 = Read-JsonFile $saPath
    $ri2 = Read-JsonFile $riPath
    $okDll = @($sa2.names) -contains $script:ModDll
    $okEntry = @(@($ri2.root) | Where-Object { $_ -and $_.assemblyName -eq $script:ModAsm }).Count -gt 0
    $okLen = @($sa2.names).Count -eq @($sa2.types).Count
    if ($okDll -and $okEntry -and $okLen) {
        Write-Line "`n校验通过：清单已正确登记（names/types 长度一致）" 'Green'
    } else {
        Fail "校验失败（DLL=$okDll Entry=$okEntry LenMatch=$okLen），请运行 Uninstall 后重试。"
    }

    Write-Line (@"

安装完成。用法（全部在游戏内的地图上完成）：

  1. 走到任意一张长椅坐下（必须处于休息状态）
  2. 按地图键打开地图
  3. 地图上会出现其他已解锁长椅的图标（青色方块 + 场景名）
  4. 鼠标点那个图标 —— 立即传送到对应长椅，并自动把它设为新的重生点

说明：
  · 没坐在长椅上时，地图上不显示任何图标，点击也不会触发传送，完全等同原版。
  · 图标只出现在地图上已经可见（探索过/买过地图）的区域内。
  · 当前所在的那张长椅显示为灰色，不可点击。
  · 长椅清单取自存档里已遇到的长椅；读不到存档时退回内置全表，保证功能可用。
  · 传送后角色会直接坐在目标长椅上，和正常休息完全一样（存档点随之更新）。
  · F1 = 开关诊断信息（左上角显示图标统计），平时不需要用。
  · 运行日志：%USERPROFILE%\AppData\LocalLow\Team Cherry\Hollow Knight\BenchWarp.log
"@) 'Green'
}

function Uninstall-Mod([string]$Dir) {
    $managed = [System.IO.Path]::Combine($Dir, 'hollow_knight_Data\Managed')
    $dataDir = [System.IO.Path]::Combine($Dir, 'hollow_knight_Data')
    Write-Line "`n== 卸载 BenchWarp ==" 'Cyan'

    $proc = Get-Process -Name 'hollow_knight' -ErrorAction SilentlyContinue
    if ($proc) { Fail "游戏正在运行，请先完全退出游戏再卸载。" }

    $dllDst = [System.IO.Path]::Combine($managed, $script:ModDll)
    if (Test-Path -LiteralPath $dllDst) { Remove-Item -LiteralPath $dllDst -Force; Write-Line "  已删除 $dllDst" }
    else { Write-Line "  $script:ModDll 不在游戏目录（可能已卸载）" 'DarkGray' }

    $saPath = [System.IO.Path]::Combine($dataDir, 'ScriptingAssemblies.json')
    if (Test-Path -LiteralPath $saPath -PathType Leaf) {
        $sa = Read-JsonFile $saPath
        $names = @($sa.names)
        $types = @($sa.types)
        if ($names -contains $script:ModDll) {
            $idx = [array]::IndexOf($names, $script:ModDll)
            $newNames = @()
            $newTypes = @()
            for ($i = 0; $i -lt $names.Count; $i++) {
                if ($i -eq $idx) { continue }
                $newNames += $names[$i]
                if ($i -lt $types.Count) { $newTypes += $types[$i] }
            }
            $sa.names = $newNames
            $sa.types = $newTypes
            Write-JsonFile $saPath $sa
            Write-Line "  ScriptingAssemblies.json：已移除 $script:ModDll"
        } else { Write-Line "  ScriptingAssemblies.json 不含 $script:ModDll" 'DarkGray' }
    }

    $riPath = [System.IO.Path]::Combine($dataDir, 'RuntimeInitializeOnLoads.json')
    if (Test-Path -LiteralPath $riPath -PathType Leaf) {
        $ri = Read-JsonFile $riPath
        $roots = @($ri.root)
        $kept = @($roots | Where-Object { -not ($_ -and $_.assemblyName -eq $script:ModAsm) })
        if ($kept.Count -ne $roots.Count) {
            $ri.root = $kept
            Write-JsonFile $riPath $ri
            Write-Line "  RuntimeInitializeOnLoads.json：已移除入口"
        } else { Write-Line "  RuntimeInitializeOnLoads.json 无本 mod 入口" 'DarkGray' }
    }

    Write-Line "`n卸载完成。长椅记录文件（BenchWarp_benches.txt）保留在游戏存档目录，可自行删除。" 'Green'}

function Show-Status([string]$Dir) {
    $managed = [System.IO.Path]::Combine($Dir, 'hollow_knight_Data\Managed')
    $dataDir = [System.IO.Path]::Combine($Dir, 'hollow_knight_Data')
    Write-Line "游戏目录 : $Dir"
    $dllDst = [System.IO.Path]::Combine($managed, $script:ModDll)
    if (Test-Path -LiteralPath $dllDst) {
        $it = Get-Item -LiteralPath $dllDst
        Write-Line "DLL      : 已安装 ($($it.Length) 字节, $($it.LastWriteTime))" 'Green'
    } else { Write-Line "DLL      : 未安装" 'Yellow' }

    $saPath = [System.IO.Path]::Combine($dataDir, 'ScriptingAssemblies.json')
    if (Test-Path -LiteralPath $saPath -PathType Leaf) {
        $sa = Read-JsonFile $saPath
        $has = @($sa.names) -contains $script:ModDll
        Write-Line ("清单登记 : " + $(if ($has) { '已登记（' + $script:ModDll + '）' } else { '未登记' }))
    }
    $riPath = [System.IO.Path]::Combine($dataDir, 'RuntimeInitializeOnLoads.json')
    if (Test-Path -LiteralPath $riPath -PathType Leaf) {
        $ri = Read-JsonFile $riPath
        $has = @(@($ri.root) | Where-Object { $_ -and $_.assemblyName -eq $script:ModAsm }).Count -gt 0
        Write-Line ("启动入口 : " + $(if ($has) { '已登记（' + $script:ModNs + '.' + $script:ModClass + '.' + $script:ModMethod + '）' } else { '未登记' }))
    }
    $dotnet = Resolve-DotNet
    Write-Line ("编译器   : " + $(if ($dotnet) { $dotnet } else { '未找到 .NET SDK（无法编译，但已安装的 DLL 仍可运行）' }))
    $log = [System.IO.Path]::Combine($env:USERPROFILE, 'AppData\LocalLow\Team Cherry\Hollow Knight\BenchWarp.log')
    if (Test-Path -LiteralPath $log) {
        Write-Line "`n最近日志（$log）：" 'Cyan'
        Get-Content -LiteralPath $log -Tail 12 | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Line "`n还没有 BenchWarp.log（启动游戏一次后生成）。" 'DarkGray'
    }
}

# ---------------------------------------------------------------- 主流程

Write-Line "BenchWarp —— 长椅互相传送（Hollow Knight 1.5.12620）" 'Cyan'
$dir = Get-InstallDir
Write-Line "游戏目录：$dir" 'DarkGray'
$managed = [System.IO.Path]::Combine($dir, 'hollow_knight_Data\Managed')

switch ($Action) {
    'build'     { [void](Invoke-Build $managed) }
    'install'   { Install-Mod $dir }
    'uninstall' { Uninstall-Mod $dir }
    'status'    { Show-Status $dir }
}
