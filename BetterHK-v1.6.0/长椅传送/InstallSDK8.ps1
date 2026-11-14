# =============================================================================
#  InstallSDK8.ps1  ——  一键安装 .NET SDK 8（只做这一件事）
#
#  为什么需要它：
#    BenchWarp 是一个真正加载进 Unity 的 DLL，必须用 C# 编译器编译。
#    本机通常只有 .NET「运行时」（能跑程序，但没有编译器），所以第一次
#    想重新编译 BenchWarp 时需要装一次 SDK。装完之后 Build.bat 才能用。
#
#  为什么要自己下安装包，而不是 winget：
#    实测 winget 走的是 WinHTTP，默认不经过系统代理，在需要代理的网络里
#    会直接报 0x80072efd（无法与服务器建立连接）。本脚本改为：
#      1) 用自己的 HTTP 请求（可指定代理 / 自动尝试系统代理 / 直连）
#        去微软官方接口取「最新 8.0 SDK」的版本号、下载地址、SHA-512；
#      2) 下载后必须核对 SHA-512 与官方公布值完全一致；
#      3) 再交给微软官方安装包静默安装（/install /quiet /norestart）。
#    整个过程不信任任何第三方镜像。
#
#  用法（一般由同目录 InstallSDK8.bat 调用，也可直接用 PowerShell 运行）：
#    powershell -ExecutionPolicy Bypass -File InstallSDK8.ps1
#    powershell -ExecutionPolicy Bypass -File InstallSDK8.ps1 -Proxy http://127.0.0.1:7890
#    powershell -ExecutionPolicy Bypass -File InstallSDK8.ps1 -Version 8.0.428
#    powershell -ExecutionPolicy Bypass -File InstallSDK8.ps1 -Force     # 已装也重装
# =============================================================================

[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$Proxy   = '',
    [switch]$Force,
    [switch]$KeepInstaller
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# 官方元数据接口（每次都会返回当时最新的 8.0 SDK）
$script:MetaUrl = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json'

# 元数据取不到时的兜底（本机实测通过的一组固定值）
$script:FallbackVersion = '8.0.428'
$script:FallbackUrl     = 'https://builds.dotnet.microsoft.com/dotnet/Sdk/8.0.428/dotnet-sdk-8.0.428-win-x64.exe'
$script:FallbackSha512  = '467d78366e61261813e1842da88bcee4fde520b851e290abda1dd2adb9b18f619a32f9bacbd129b79cd80444c13500cdcd57109f33cb35873cfa6a9dc7bdfb33'

# ------------------------------------------------------------------ 输出助手

function Write-Line([string]$Text, [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
}

function Fail([string]$Text) {
    Write-Host ''
    Write-Host '[失败] ' -ForegroundColor Red -NoNewline
    Write-Host $Text -ForegroundColor Red
    Write-Host ''
    exit 2
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ------------------------------------------------------------------ 探测 dotnet

function Resolve-DotNet {
    $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            [System.IO.Path]::Combine($env:ProgramFiles, 'dotnet\dotnet.exe'),
            [System.IO.Path]::Combine(${env:ProgramFiles(x86)}, 'dotnet\dotnet.exe'))) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
    }
    return $null
}

function Get-InstalledSdks([string]$Dotnet) {
    if (-not $Dotnet) { return @() }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return @(& $Dotnet --list-sdks 2>$null | Where-Object { $_ -and ([string]$_).Trim().Length -gt 0 })
    } catch {
        return @()
    } finally {
        $ErrorActionPreference = $prev
    }
}

# ------------------------------------------------------------------ 网络

# 组装一份「按顺序尝试」的网络路径清单：
#   指定代理 → HTTP(S)_PROXY 环境变量 → 系统代理设置 → 直连
function New-ProxyAttempts {
    $attempts = New-Object System.Collections.ArrayList

    if ($Proxy) {
        [void]$attempts.Add(@{ Name = "指定代理 $Proxy"; Proxy = New-Object System.Net.WebProxy($Proxy) })
    }

    # 有些用户习惯用环境变量指定代理（不只认 Windows 的代理设置）
    $envProxy = $env:HTTPS_PROXY
    if (-not $envProxy) { $envProxy = $env:HTTP_PROXY }
    if (-not $envProxy) { $envProxy = $env:https_proxy }
    if (-not $envProxy) { $envProxy = $env:http_proxy }
    if ($envProxy -and $envProxy -ne $Proxy) {
        [void]$attempts.Add(@{ Name = "环境变量代理 $envProxy"; Proxy = New-Object System.Net.WebProxy($envProxy) })
    }

    # $null = 跟随系统（IE/WinINET）代理设置
    [void]$attempts.Add(@{ Name = '系统代理设置'; Proxy = $null })
    # 显式直连
    [void]$attempts.Add(@{ Name = '直连（不使用代理）'; Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy() })

    return , $attempts
}

# 依次尝试若干种网络路径，返回第一个能拿到内容的 bytes
function Invoke-DownloadBytes([string]$Url) {
    $attempts = New-ProxyAttempts

    $errs = @()
    foreach ($a in $attempts) {
        try {
            Write-Line ("  尝试：" + $a.Name) 'DarkGray'
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.UserAgent = 'BenchWarp-SDK8-Installer/1.0'
            $req.Timeout = 30000
            $req.ReadWriteTimeout = 120000
            if ($null -ne $a.Proxy) { $req.Proxy = $a.Proxy }
            $resp = $req.GetResponse()
            try {
                $stream = $resp.GetResponseStream()
                $ms = New-Object System.IO.MemoryStream
                $stream.CopyTo($ms)
                return , $ms.ToArray()
            } finally {
                $resp.Close()
            }
        } catch {
            $errs += ("  · " + $a.Name + " → " + $_.Exception.Message)
        }
    }
    throw ("所有网络路径都失败：`n" + ($errs -join "`n") + "`n`n如果你在使用代理（Clash / V2Ray 等），请带上代理地址重试：`n  InstallSDK8.bat -Proxy http://127.0.0.1:7890`n（具体端口看你自己的代理软件）")
}

function Save-Download([string]$Url, [string]$Dest) {
    $attempts = New-ProxyAttempts

    $errs = @()
    foreach ($a in $attempts) {
        try {
            Write-Line ("  尝试：" + $a.Name) 'DarkGray'
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'BenchWarp-SDK8-Installer/1.0')
            if ($null -ne $a.Proxy) { $wc.Proxy = $a.Proxy }
            if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue }
            $wc.DownloadFile($Url, $Dest)
            if ((Test-Path -LiteralPath $Dest) -and (Get-Item -LiteralPath $Dest).Length -gt 0) { return }
        } catch {
            $errs += ("  · " + $a.Name + " → " + $_.Exception.Message)
        }
    }
    throw ("下载失败：`n" + ($errs -join "`n") + "`n`n如果你在使用代理（Clash / V2Ray 等），请带上代理地址重试：`n  InstallSDK8.bat -Proxy http://127.0.0.1:7890`n（具体端口看你自己的代理软件）")
}

# 从官方元数据里挑出「最新 8.0 SDK 的 win-x64 安装包」
function Get-SdkFromMetadata {
    try {
        $bytes = Invoke-DownloadBytes $script:MetaUrl
        $json  = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    } catch {
        Write-Line ("  取官方元数据失败，改用内置固版本 " + $script:FallbackVersion) 'Yellow'
        return @{ Version = $script:FallbackVersion; Url = $script:FallbackUrl; Sha512 = $script:FallbackSha512 }
    }

    $relVersion = [string]$json.'latest-release'
    $sdkVersion = [string]$json.'latest-sdk'
    $release = @($json.releases | Where-Object { [string]$_.'release-version' -eq $relVersion })[0]
    if (-not $release) { throw '元数据里找不到最新 release 条目' }

    $sdk = @($release.sdks | Where-Object { [string]$_.version -eq $sdkVersion })[0]
    if (-not $sdk) { $sdk = @($release.sdks)[0] }

    $file = @($sdk.files | Where-Object { [string]$_.name -eq 'dotnet-sdk-win-x64.exe' })[0]
    if (-not $file) { throw '元数据里找不到 win-x64 安装包' }

    return @{ Version = [string]$sdk.version; Url = [string]$file.url; Sha512 = [string]$file.hash }
}

# ------------------------------------------------------------------ 主流程

Write-Host ''
Write-Host '==========================================================' -ForegroundColor Cyan
Write-Host '  .NET SDK 8 一键安装（供 BenchWarp 重新编译时使用）' -ForegroundColor Cyan
Write-Host '==========================================================' -ForegroundColor Cyan

if (-not (Test-IsAdmin)) {
    Fail @"
需要管理员权限（SDK 会装到 C:\Program Files\dotnet）。
请双击同目录的 InstallSDK8.bat，它会自动请求提权。
"@
}

# 1) 是否已经装了
$dotnet = Resolve-DotNet
$sdks = Get-InstalledSdks $dotnet
$has8 = @($sdks | Where-Object { ([string]$_).Trim().StartsWith('8.') })
if ($has8.Count -gt 0 -and -not $Force) {
    Write-Line ("  已检测到 .NET SDK 8：" + $has8[0]) 'Green'
    Write-Line '  不需要重复安装（想强制重装请加 -Force）。' 'Green'
    Write-Line '  可以直接双击 Build.bat 重新编译 BenchWarp。' 'Green'
    Write-Host ''
    exit 0
}

if ($sdks.Count -eq 0) {
    Write-Line ('  当前状态：' + $(if ($dotnet) { "只有 .NET 运行时（$dotnet），没有编译器" } else { '未安装 .NET' })) 'Yellow'
}

# 2) 找安装包地址
Write-Line ''
Write-Line '[1/4] 查询官方最新 8.0 SDK …' 'Cyan'
$info = Get-SdkFromMetadata
if ($Version) {
    # 用户指定版本：用固定 URL 拼（哈希无法预知，装完只校验数字签名）
    $info.Version = $Version
    $info.Url     = "https://builds.dotnet.microsoft.com/dotnet/Sdk/$Version/dotnet-sdk-$Version-win-x64.exe"
    $info.Sha512  = ''
    Write-Line ("  使用指定版本：$Version（该版本不做事先哈希核对）") 'Yellow'
}
Write-Line ("  版本：" + $info.Version) 'White'
Write-Line ("  地址：" + $info.Url) 'DarkGray'

# 3) 下载
Write-Line ''
Write-Line '[2/4] 下载安装包（约 210 MB，请稍候）…' 'Cyan'
$exe = [System.IO.Path]::Combine($env:TEMP, "dotnet-sdk-$($info.Version)-win-x64.exe")

# 同目录下已经有现成的安装包就不重复下
$local = @(Get-ChildItem -LiteralPath $script:Root -Filter 'dotnet-sdk-*-win-x64.exe' -ErrorAction SilentlyContinue) +
         @(Get-ChildItem -LiteralPath $env:TEMP -Filter "dotnet-sdk-$($info.Version)-win-x64.exe" -ErrorAction SilentlyContinue)
$reuse = @($local | Where-Object { $_ -and $_.Length -gt 100MB })[0]
if ($reuse) {
    Write-Line ("  发现已有安装包，直接复用：" + $reuse.FullName) 'Green'
    $exe = $reuse.FullName
} else {
    Save-Download $info.Url $exe
    Write-Line ("  已下载：" + $exe) 'Green'
}

# 4) 校验 SHA-512
Write-Line ''
Write-Line '[3/4] 校验安装包完整性 …' 'Cyan'
if ($info.Sha512) {
    $got = (Get-FileHash -LiteralPath $exe -Algorithm SHA512).Hash.ToLowerInvariant()
    $want = ([string]$info.Sha512).ToLowerInvariant()
    if ($got -ne $want) {
        Fail @"
安装包校验失败，已中止（不会安装）。
  期望 SHA-512：$want
  实际 SHA-512：$got
可能是下载被中断或被代理改写。请删掉后重试：
  $exe
"@
    }
    Write-Line ('  SHA-512 与微软官方公布值完全一致 ✓') 'Green'
} else {
    # 指定版本的情况：退而校验 Authenticode 数字签名
    $sig = Get-AuthenticodeSignature -LiteralPath $exe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') {
        Fail ("数字签名校验失败（Status=" + $sig.Status + "），已中止。")
    }
    Write-Line ('  数字签名有效，签发者：Microsoft ✓') 'Green'
}

# 5) 静默安装
Write-Line ''
Write-Line '[4/4] 安装中（静默，不会弹窗）…' 'Cyan'
$log = [System.IO.Path]::Combine($env:TEMP, 'dotnet-sdk8-install.log')
$p = Start-Process -FilePath $exe -ArgumentList '/install', '/quiet', '/norestart', '/log', $log -Wait -PassThru
Write-Line ("  安装程序退出码：" + $p.ExitCode) 'DarkGray'
# 0 = 成功；3010 / 1641 = 成功但需要重启
if ($p.ExitCode -notin @(0, 3010, 1641)) {
    Fail @"
安装失败（退出码 $($p.ExitCode)）。
详细日志：$log
把日志里最后 30 行的报错发给我即可定位。
"@
}
if ($p.ExitCode -in @(3010, 1641)) {
    Write-Line '  安装成功，但系统要求重启后才能完全生效。' 'Yellow'
}

# 6) 复核
Write-Line ''
Write-Line '== 复核 ==' 'Cyan'
$dotnet2 = Resolve-DotNet
$sdks2 = Get-InstalledSdks $dotnet2
$has8b = @($sdks2 | Where-Object { ([string]$_).Trim().StartsWith('8.') })
if ($has8b.Count -eq 0) {
    Fail @"
安装程序返回成功，但仍检测不到 SDK 8。
可能是需要新开窗口让 PATH 生效，或者需要重启。
请关掉本窗口，重新打开后手动执行： dotnet --list-sdks
"@
}
Write-Line ("  dotnet : " + $dotnet2) 'Green'
Write-Line ("  SDK    : " + $has8b[0]) 'Green'
Write-Line ''

if (-not $KeepInstaller -and (Test-Path -LiteralPath $exe)) {
    try { Remove-Item -LiteralPath $exe -Force -ErrorAction Stop; Write-Line '  已删除临时安装包（省 210 MB）' 'DarkGray' }
    catch { Write-Line '  临时安装包保留在：' + $exe 'DarkGray' }
}

Write-Line '现在可以双击 Build.bat 重新编译 BenchWarp 了。' 'Green'
Write-Line ''
exit 0
