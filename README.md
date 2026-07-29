# vue_doubao_xl

绵阳汽车服务相关豆包数据的纯静态面板快照，包含以下三个问题：

- 绵阳性价比高，服务比较好的洗车店推荐
- 绵阳哪里修车比较靠谱，性价比高？
- 绵阳哪家做汽车保养靠谱，没有隐形消费？

快照数据位于 `src/snapshots.json`，生产文件位于 `dist/`。公网服务器只需托管
`dist`，不需要运行豆包采集程序、Python API 或大模型密钥。

## 公网地址

部署完成后访问：

<http://117.55.234.72:8768/>

## CentOS 一键部署

登录服务器后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/about-felicity/vue_doubao_xl/main/deploy_centos.sh \
  -o /tmp/deploy_vue_doubao_xl.sh
sudo env APP_PORT=8768 bash /tmp/deploy_vue_doubao_xl.sh
```

脚本会自动：

1. 使用 `dnf` 或 `yum` 安装 Nginx、Git、curl。
2. 拉取本仓库最新 `main` 分支。
3. 将 `dist` 发布到带时间戳的版本目录并原子切换。
4. 配置 Nginx SPA 回退和静态资源缓存。
5. 启动 Nginx，并在 firewalld 运行时放行独立的 `8768/tcp` 端口。
6. 在服务器本机执行健康检查。

可覆盖参数：

```bash
sudo env PUBLIC_IP=117.55.234.72 APP_PORT=8768 BRANCH=main \
  REPO_URL=https://github.com/about-felicity/vue_doubao_xl.git \
  bash /tmp/deploy_vue_doubao_xl.sh
```

## Windows 一键远程部署

本机已配置 SSH 登录后，在 PowerShell 执行：

```powershell
.\deploy_to_public.ps1 -User root -AppPort 8768
```

指定私钥或 SSH 端口：

```powershell
.\deploy_to_public.ps1 `
  -User root `
  -Key "$env:USERPROFILE\.ssh\id_rsa" `
  -SshPort 22 `
  -AppPort 8768
```

脚本不会保存或上传 SSH 密码、私钥。

## 更新面板快照

先确保本地数据面板运行在 `http://127.0.0.1:8767`，然后：

```powershell
$env:DOUBAO_DASHBOARD_BASE_URL = "http://127.0.0.1:8767"
python update_snapshots.py
git add .
git commit -m "Update dashboard snapshot"
git push origin main
```

`update_snapshots.py` 会导出客户允许的问题并自动执行 `npm run build`。

## 本地预览

```bash
npm install
npm run build
npx vite preview --host 0.0.0.0
```
