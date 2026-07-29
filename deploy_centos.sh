#!/usr/bin/env bash
# CentOS 一键部署：使用隔离的 Nginx 服务发布静态快照，不影响系统已有的 80/443 服务。

set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/about-felicity/vue_doubao_xl.git}"
BRANCH="${BRANCH:-main}"
PUBLIC_IP="${PUBLIC_IP:-117.55.234.72}"
APP_PORT="${APP_PORT:-8768}"
APP_NAME="${APP_NAME:-vue_doubao_xl}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/var/www/${APP_NAME}}"
RELEASES_DIR="${DEPLOY_ROOT}/releases"
CURRENT_LINK="${DEPLOY_ROOT}/current"
SERVICE_ROOT="/etc/${APP_NAME}"
NGINX_CONF="${SERVICE_ROOT}/nginx.conf"
SYSTEMD_UNIT="/etc/systemd/system/${APP_NAME}.service"
OLD_NGINX_CONF="/etc/nginx/conf.d/${APP_NAME}.conf"
RELEASE_ID="$(date +%Y%m%d%H%M%S)"
RELEASE_DIR="${RELEASES_DIR}/${RELEASE_ID}"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

if [[ ! "${APP_PORT}" =~ ^[0-9]+$ ]] || (( APP_PORT < 1024 || APP_PORT > 65535 )); then
  echo "APP_PORT 必须是 1024-65535 之间的端口号。"
  exit 1
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash deploy_centos.sh"
  exit 1
fi

install_packages() {
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx git curl policycoreutils-python-utils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y nginx git curl policycoreutils-python-utils
  else
    echo "未找到 dnf/yum；该脚本仅支持 CentOS/RHEL 系统。"
    exit 1
  fi
}

echo "[1/6] 安装/确认 Nginx、Git、curl..."
install_packages

echo "[2/6] 从 GitHub 拉取 ${BRANCH} 分支..."
git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${WORK_DIR}/repo"
if [[ ! -f "${WORK_DIR}/repo/dist/index.html" ]]; then
  echo "仓库中没有 dist/index.html，请先在本地执行 npm run build 并推送 dist。"
  exit 1
fi

echo "[3/6] 发布静态快照..."
install -d -m 0755 "${RELEASE_DIR}"
cp -a "${WORK_DIR}/repo/dist/." "${RELEASE_DIR}/"
ln -sfn "${RELEASE_DIR}" "${CURRENT_LINK}.next"
mv -Tf "${CURRENT_LINK}.next" "${CURRENT_LINK}"

echo "[4/6] 配置 Nginx..."
install -d -m 0755 "${SERVICE_ROOT}"
cat >"${NGINX_CONF}" <<EOF
worker_processes auto;
pid /run/${APP_NAME}.pid;
error_log /var/log/nginx/${APP_NAME}-error.log warn;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/${APP_NAME}-access.log;
    sendfile on;

    server {
        listen ${APP_PORT};
        listen [::]:${APP_PORT};
        server_name ${PUBLIC_IP} _;

        root ${CURRENT_LINK};
        index index.html;

        location / {
            try_files \$uri \$uri/ /index.html;
        }

        location /dashboard-assets/ {
            try_files \$uri =404;
            expires 7d;
            add_header Cache-Control "public, immutable";
        }

        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
    }
}
EOF

cat >"${SYSTEMD_UNIT}" <<EOF
[Unit]
Description=Vue DouBao XL isolated dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/sbin/nginx -t -c ${NGINX_CONF}
ExecStart=/usr/sbin/nginx -c ${NGINX_CONF} -g "daemon off;"
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# 清理由旧版脚本创建的 conf.d 配置；不删除或修改任何其他 Nginx 站点。
rm -f -- "${OLD_NGINX_CONF}"

if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
  if ! command -v semanage >/dev/null 2>&1; then
    echo "SELinux 已启用，但没有 semanage 命令，无法授权 Nginx 监听 ${APP_PORT}。"
    exit 1
  fi
  if ! semanage port -l | awk '$1 == "http_port_t" { print $0 }' | grep -Eq "(^|[ ,])${APP_PORT}([ ,]|$|-)"; then
    semanage port -a -t http_port_t -p tcp "${APP_PORT}" 2>/dev/null \
      || semanage port -m -t http_port_t -p tcp "${APP_PORT}"
  fi
fi

nginx -t -c "${NGINX_CONF}"
systemctl daemon-reload
systemctl enable "${APP_NAME}.service"
if ! systemctl restart "${APP_NAME}.service"; then
  echo "独立面板服务启动失败，以下是服务日志："
  systemctl status "${APP_NAME}.service" --no-pager -l || true
  journalctl -u "${APP_NAME}.service" --no-pager -n 50 || true
  exit 1
fi

echo "[5/6] 放行 ${APP_PORT}/tcp 端口..."
if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --permanent --add-port="${APP_PORT}/tcp"
  firewall-cmd --reload
fi
if command -v restorecon >/dev/null 2>&1; then
  restorecon -RF "${DEPLOY_ROOT}" >/dev/null 2>&1 || true
fi

echo "[6/6] 健康检查..."
for _ in {1..15}; do
  if curl --fail --silent --show-error --max-time 3 \
    -H "Host: ${PUBLIC_IP}" "http://127.0.0.1:${APP_PORT}/" >/dev/null; then
    echo "部署成功：http://${PUBLIC_IP}:${APP_PORT}/"
    echo "当前版本：${RELEASE_ID}"
    exit 0
  fi
  sleep 1
done

echo "独立面板服务已启动，但本机健康检查失败。"
journalctl -u "${APP_NAME}.service" --no-pager -n 50 || true
exit 1
