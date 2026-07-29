param(
    [string]$HostIP = "117.55.234.72",
    [string]$User = "root",
    [string]$Key = "",
    [int]$SshPort = 22,
    [int]$AppPort = 8768,
    [string]$Branch = "main"
)

$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/about-felicity/vue_doubao_xl.git"
$RawScript = "https://raw.githubusercontent.com/about-felicity/vue_doubao_xl/$Branch/deploy_centos.sh"

$sshArgs = @(
    "-p", "$SshPort",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ServerAliveInterval=15"
)
if ($Key) {
    $resolvedKey = (Resolve-Path -LiteralPath $Key).Path
    $sshArgs += @("-i", $resolvedKey)
}

$remoteCommand = @"
set -e
tmp_script=`$(mktemp)
curl -fsSL '$RawScript' -o "`$tmp_script"
chmod +x "`$tmp_script"
if [ "`$(id -u)" -eq 0 ]; then
  PUBLIC_IP='$HostIP' APP_PORT='$AppPort' REPO_URL='$RepoUrl' BRANCH='$Branch' bash "`$tmp_script"
else
  sudo env PUBLIC_IP='$HostIP' APP_PORT='$AppPort' REPO_URL='$RepoUrl' BRANCH='$Branch' bash "`$tmp_script"
fi
rm -f "`$tmp_script"
"@

Write-Host "正在连接 $User@$HostIP 并部署..." -ForegroundColor Cyan
& ssh @sshArgs "$User@$HostIP" $remoteCommand
if ($LASTEXITCODE -ne 0) {
    throw "远程部署失败，SSH 退出码：$LASTEXITCODE"
}

$url = "http://$HostIP`:$AppPort/"
Write-Host "正在检查公网地址 $url ..." -ForegroundColor Cyan
$response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
if ($response.StatusCode -ne 200) {
    throw "公网检查失败，HTTP 状态：$($response.StatusCode)"
}
Write-Host "部署成功：$url" -ForegroundColor Green
