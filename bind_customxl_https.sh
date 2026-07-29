#!/usr/bin/env bash
# 将已发布的面板快照绑定到 https://1any.top/customXL/。
# 该脚本会停用占用 443 的 x-ui/Xray，让系统 Nginx 接管现有 HTTPS 站点。

set -Eeuo pipefail

DOMAIN="${DOMAIN:-1any.top}"
URL_PREFIX="${URL_PREFIX:-/customXL}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"
STATIC_ROOT="${STATIC_ROOT:-/var/www/vue_doubao_xl/current}"
XUI_SERVICE="${XUI_SERVICE:-x-ui.service}"
BACKUP_DIR="${BACKUP_DIR:-/root/vue_doubao_xl_backups}"
BACKUP_FILE="${BACKUP_DIR}/nginx.conf.$(date +%Y%m%d%H%M%S).bak"
STATE_CHANGED=0
XUI_WAS_ACTIVE=0
XUI_WAS_ENABLED=0

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash bind_customxl_https.sh"
  exit 1
fi
if [[ ! "${URL_PREFIX}" =~ ^/[A-Za-z0-9._~-]+$ ]]; then
  echo "URL_PREFIX 必须是类似 /customXL 的单层安全路径。"
  exit 1
fi
if [[ ! "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "DOMAIN 格式不正确。"
  exit 1
fi
URL_PREFIX="${URL_PREFIX%/}"

for required in nginx systemctl curl python3 ss; do
  if ! command -v "${required}" >/dev/null 2>&1; then
    echo "缺少命令：${required}"
    exit 1
  fi
done
if [[ ! -f "${NGINX_CONF}" ]]; then
  echo "没有找到 Nginx 配置：${NGINX_CONF}"
  exit 1
fi
if [[ ! -f "${STATIC_ROOT}/index.html" ]]; then
  echo "没有找到面板快照：${STATIC_ROOT}/index.html"
  echo "请先执行 deploy_centos.sh 发布面板。"
  exit 1
fi
if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] \
  || [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
  echo "没有找到 ${DOMAIN} 的 Let's Encrypt 证书，已停止修改。"
  exit 1
fi

systemctl is-active --quiet "${XUI_SERVICE}" && XUI_WAS_ACTIVE=1 || true
systemctl is-enabled --quiet "${XUI_SERVICE}" && XUI_WAS_ENABLED=1 || true

install -d -m 0700 "${BACKUP_DIR}"
cp -a -- "${NGINX_CONF}" "${BACKUP_FILE}"
echo "Nginx 配置备份：${BACKUP_FILE}"

rollback() {
  local exit_code=$?
  trap - ERR
  if (( STATE_CHANGED )); then
    echo "部署失败，正在恢复原配置..."
    cp -a -- "${BACKUP_FILE}" "${NGINX_CONF}" || true
    systemctl stop nginx.service >/dev/null 2>&1 || true
    if (( XUI_WAS_ENABLED )); then
      systemctl enable "${XUI_SERVICE}" >/dev/null 2>&1 || true
    fi
    if (( XUI_WAS_ACTIVE )); then
      systemctl start "${XUI_SERVICE}" >/dev/null 2>&1 || true
    fi
  fi
  exit "${exit_code}"
}
trap rollback ERR

export DOMAIN URL_PREFIX NGINX_CONF STATIC_ROOT
python3 <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ["NGINX_CONF"])
domain = os.environ["DOMAIN"]
prefix = os.environ["URL_PREFIX"]
static_root = os.environ["STATIC_ROOT"].rstrip("/")
text = path.read_text(encoding="utf-8")

begin = "        # BEGIN CUSTOMXL MANAGED"
end = "        # END CUSTOMXL MANAGED"
text = re.sub(
    rf"\n{re.escape(begin)}.*?{re.escape(end)}\n",
    "\n",
    text,
    flags=re.S,
)

def closing_brace(source, opening):
    depth = 0
    quote = None
    escaped = False
    comment = False
    for index in range(opening, len(source)):
        char = source[index]
        if comment:
            if char == "\n":
                comment = False
            continue
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char == "#":
            comment = True
        elif char in ("'", '"'):
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    raise RuntimeError("Nginx 配置中的大括号不完整。")

matches = []
for match in re.finditer(r"\bserver\s*\{", text):
    opening = text.find("{", match.start())
    closing = closing_brace(text, opening)
    block = text[match.start():closing + 1]
    names = re.findall(r"\bserver_name\s+([^;]+);", block)
    has_domain = any(domain in name.split() for name in names)
    has_https = bool(re.search(r"\blisten\s+(?:\[::\]:)?443(?:\s|;)", block))
    if has_domain and has_https:
        matches.append((opening, closing))

if len(matches) != 1:
    raise RuntimeError(
        f"应当找到 1 个 {domain}:443 server，实际找到 {len(matches)} 个；未写入配置。"
    )

_, closing = matches[0]
managed = f"""
{begin}
        location = {prefix} {{
            return 301 https://$host{prefix}/;
        }}

        location ^~ {prefix}/ {{
            alias {static_root}/;
            index index.html;
        }}
{end}
"""
text = text[:closing] + managed + text[closing:]
path.write_text(text, encoding="utf-8")
PY

STATE_CHANGED=1
nginx -t -c "${NGINX_CONF}"

echo "停止并禁用 ${XUI_SERVICE}，释放 443..."
systemctl disable --now "${XUI_SERVICE}"

for _ in {1..15}; do
  if ! ss -ltnp | grep -Eq '[:.]443[[:space:]]'; then
    break
  fi
  sleep 1
done
if ss -ltnp | grep -Eq '[:.]443[[:space:]]'; then
  echo "443 仍被以下进程占用："
  ss -ltnp | grep -E '[:.]443[[:space:]]' || true
  false
fi

if command -v restorecon >/dev/null 2>&1; then
  restorecon -RF "${STATIC_ROOT%/current}" >/dev/null 2>&1 || true
fi

systemctl enable nginx.service
systemctl restart nginx.service
if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --permanent --add-service=https
  firewall-cmd --reload
fi

echo "检查本机 HTTPS 路径..."
for _ in {1..15}; do
  if curl --fail --silent --show-error --max-time 5 \
    --noproxy '*' \
    --resolve "${DOMAIN}:443:127.0.0.1" \
    "https://${DOMAIN}${URL_PREFIX}/" >/dev/null; then
    trap - ERR
    echo "绑定成功：https://${DOMAIN}${URL_PREFIX}/"
    echo "Xray/x-ui 已停止并禁用。"
    echo "回滚备份：${BACKUP_FILE}"
    exit 0
  fi
  sleep 1
done

echo "Nginx 已启动，但 HTTPS 页面检查失败。"
systemctl status nginx.service --no-pager -l || true
journalctl -u nginx.service --no-pager -n 50 || true
false
