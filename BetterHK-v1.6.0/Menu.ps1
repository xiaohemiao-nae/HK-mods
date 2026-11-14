#requires -Version 5.1
<#
    空洞骑士 修改包 —— 中文使用菜单
    ------------------------------------------------------------
    为什么中文放在这里而不是 .bat 里：
      .bat 文件在中文 Windows 上会被 GBK / UTF-8 代码页来回折腾，
      写中文极易变乱码；而且 .bat 里出现中文字面量后，连路径判断
      都可能整段失效。
      所以 .bat 只保留纯 ASCII 的一行启动逻辑，所有中文界面（菜单、
      提示、错误）都交给本脚本渲染 —— PowerShell 读 UTF-8 BOM 的
      脚本时中文是确定正确的。
#>

$ErrorActionPreference = 'Stop'

try { $Host.UI.RawUI.WindowTitle = 'Better HK v1.6.0' } catch { }

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# ------------------------------------------------------------------ 定位功能目录
# 按标记文件查找，兼容「扁平布局（脚本在根目录）」与「按功能分文件夹」两种形态
function Find-FeatureDir {
    param([string]$Marker)

    if (Test-Path -LiteralPath (Join-Path $Root $Marker)) { return $Root }

    $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName $Marker)) { return $d.FullName }
    }
    return $null
}

$SpeedDir = Find-FeatureDir -Marker 'TripleWalkSpeed.ps1'
$BenchDir = Find-FeatureDir -Marker 'BenchWarp.ps1'

# ------------------------------------------------------------------ 界面
function Write-Rule {
    param([string]$Color = 'DarkCyan')
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor $Color
}

function Show-Banner {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host '    Better HK   v1.6.0        作者：小禾苗' -ForegroundColor Cyan
    Write-Host '    游戏版本 1.5.12620   /   Unity 6000.0.61f1' -ForegroundColor DarkGray
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Show-Menu {
    Clear-Host
    Show-Banner

    Write-Host '  【功能一】移速 3 倍' -ForegroundColor Yellow
    Write-Host '      改动游戏程序集里的 24 个字节，地面和空中的水平移速变 3 倍；' -ForegroundColor DarkGray
    Write-Host '      冲刺、跳跃、受击、存档等机制保持不变。' -ForegroundColor DarkGray
    Write-Host '    1) 安装        —— 打补丁' -ForegroundColor White
    Write-Host '    2) 校验        —— 查看当前是否已生效' -ForegroundColor White
    Write-Host '    3) 还原        —— 恢复原版文件' -ForegroundColor White
    if (-not $SpeedDir) {
        Write-Host '    [!] 没找到移速功能的文件夹（缺 TripleWalkSpeed.ps1），请完整解压压缩包。' -ForegroundColor Red
    }
    Write-Host ''

    Write-Host '  【功能二】长椅传送（在椅子之间互相传送）' -ForegroundColor Yellow
    Write-Host '      放一个自制 DLL 并登记两份 Unity 清单，不需要任何 mod 加载器；' -ForegroundColor DarkGray
    Write-Host '      坐下休息后打开地图，点地图上的长椅图标即可传送。' -ForegroundColor DarkGray
    Write-Host '    4) 安装' -ForegroundColor White
    Write-Host '    5) 查看状态' -ForegroundColor White
    Write-Host '    6) 卸载' -ForegroundColor White
    if (-not $BenchDir) {
        Write-Host '    [!] 没找到长椅传送的文件夹（缺 BenchWarp.ps1），请完整解压压缩包。' -ForegroundColor Red
    }
    Write-Host ''

    Write-Host '  【工具】' -ForegroundColor Yellow
    Write-Host '    7) 安装 .NET SDK 8   （只有想自己重新编译长椅传送时才需要）' -ForegroundColor White
    Write-Host '    8) 打开中文说明文档' -ForegroundColor White
    Write-Host '    0) 退出' -ForegroundColor White
    Write-Host ''
    Write-Rule
}

# 各功能脚本自己结尾都有 pause，不需要在这里再停一次
function Invoke-BatchFile {
    param([string]$Path, [string]$Name)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Write-Host ''
        Write-Host ("  找不到 {0} 对应的启动脚本。" -f $Name) -ForegroundColor Red
        return
    }
    Write-Host ''
    & $env:ComSpec /c "`"$Path`""
}

# ------------------------------------------------------------------ 主循环
while ($true) {
    Show-Menu

    $raw = Read-Host '  请输入编号 [0-8]'
    $choice = ''
    if ($null -ne $raw) { $choice = ([string]$raw).Trim() }

    switch ($choice) {
        '1' {
            Invoke-BatchFile -Path (Join-Path $SpeedDir 'Install.bat') -Name '移速 3 倍 / 安装'
            break
        }
        '2' {
            Invoke-BatchFile -Path (Join-Path $SpeedDir 'Verify.bat') -Name '移速 3 倍 / 校验'
            break
        }
        '3' {
            Invoke-BatchFile -Path (Join-Path $SpeedDir 'Restore.bat') -Name '移速 3 倍 / 还原'
            break
        }
        '4' {
            Invoke-BatchFile -Path (Join-Path $BenchDir 'Install.bat') -Name '长椅传送 / 安装'
            break
        }
        '5' {
            Invoke-BatchFile -Path (Join-Path $BenchDir 'Status.bat') -Name '长椅传送 / 状态'
            break
        }
        '6' {
            Invoke-BatchFile -Path (Join-Path $BenchDir 'Uninstall.bat') -Name '长椅传送 / 卸载'
            break
        }
        '7' {
            Invoke-BatchFile -Path (Join-Path $BenchDir 'InstallSDK8.bat') -Name '.NET SDK 8 / 安装'
            break
        }
        '8' {
            $readme = Join-Path $Root 'README_CN.txt'
            if (Test-Path -LiteralPath $readme) {
                Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $readme + '"')
            } else {
                Write-Host '  找不到 README_CN.txt。' -ForegroundColor Red
            }
            Start-Sleep -Milliseconds 400
            break
        }
        '0' {
            Write-Host ''
            Write-Host '  已退出。祝游戏愉快。' -ForegroundColor DarkGray
            Write-Host ''
            return
        }
        default {
            if ($choice -ne '') {
                Write-Host ''
                Write-Host ("  没有编号 {0} 这一项，请输入 0 到 8。" -f $choice) -ForegroundColor Yellow
                Start-Sleep -Milliseconds 1000
            }
            break
        }
    }
}
