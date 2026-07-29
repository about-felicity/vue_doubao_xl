#!/usr/bin/env bash
# 限制 1any.top：仅保留两个客户面板路径，关闭该域名上的其他 Web 路径。

set -Eeuo pipefail

DOMAIN="${DOMAIN:-1any.top}"
URL_PREFIX="${URL_PREFIX:-/customXL}"
EXTRA_PREFIX="${EXTRA_PREFIX:-/custombjp}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"
BACKUP_DIR="${BACKUP_DIR:-/root/vue_doubao_xl_backups}"
BACKUP_FILE="${BACKUP_DIR}/nginx.conf.lock.$(date +%Y%m%d%H%M%S).bak"
STATE_CHANGED=0

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash lock_1any_to_customxl.sh"
  exit 1
fi
if [[ ! "${URL_PREFIX}" =~ ^/[A-Za-z0-9._~-]+$ ]]; then
  echo "URL_PREFIX 必须是类似 /customXL 的单层安全路径。"
  exit 1
fi
if [[ ! "${EXTRA_PREFIX}" =~ ^/[A-Za-z0-9._~-]+$ ]]; then
  echo "EXTRA_PREFIX 必须是类似 /custombjp 的单层安全路径。"
  exit 1
fi
if [[ ! "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "DOMAIN 格式不正确。"
  exit 1
fi
if [[ ! -f "${NGINX_CONF}" ]]; then
  echo "没有找到 Nginx 配置：${NGINX_CONF}"
  exit 1
fi
if ! systemctl is-active --quiet nginx.service; then
  echo "系统 Nginx 当前没有运行，请先执行 bind_customxl_https.sh。"
  exit 1
fi

install -d -m 0700 "${BACKUP_DIR}"
cp -a -- "${NGINX_CONF}" "${BACKUP_FILE}"
echo "Nginx 配置备份：${BACKUP_FILE}"

rollback() {
  local exit_code=$?
  trap - ERR
  if (( STATE_CHANGED )); then
    echo "限制失败，正在恢复原配置..."
    cp -a -- "${BACKUP_FILE}" "${NGINX_CONF}" || true
    nginx -t -c "${NGINX_CONF}" >/dev/null 2>&1 || true
    systemctl restart nginx.service >/dev/null 2>&1 || true
  fi
  exit "${exit_code}"
}
trap rollback ERR

export DOMAIN URL_PREFIX EXTRA_PREFIX NGINX_CONF
python3 <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ["NGINX_CONF"])
domain = os.environ["DOMAIN"]
prefix = os.environ["URL_PREFIX"]
extra_prefix = os.environ["EXTRA_PREFIX"]
text = path.read_text(encoding="utf-8")

begin = "        # BEGIN CUSTOMXL ONLY"
end = "        # END CUSTOMXL ONLY"
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

opening, _ = matches[0]
managed = f"""
{begin}
        # 域名只允许两个客户面板路径；403 不会触发现有的 404 error_page 内部跳转。
        if ($uri !~ "^(?:{re.escape(prefix)}|{re.escape(extra_prefix)})(?:/|$)") {{
            return 403;
        }}
{end}
"""
text = text[:opening + 1] + managed + text[opening + 1:]
path.write_text(text, encoding="utf-8")
PY

STATE_CHANGED=1
nginx -t -c "${NGINX_CONF}"
systemctl restart nginx.service

echo "验证保留路径..."
custom_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --max-time 8 --noproxy '*' --resolve "${DOMAIN}:443:127.0.0.1" \
  "https://${DOMAIN}${URL_PREFIX}/")"
if [[ "${custom_code}" != "200" ]]; then
  echo "${URL_PREFIX}/ 返回 ${custom_code}，预期为 200。"
  false
fi

for blocked_path in / /agent /agent-api/ /api/ /data/videos/; do
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 8 --noproxy '*' --resolve "${DOMAIN}:443:127.0.0.1" \
    "https://${DOMAIN}${blocked_path}")"
  if [[ "${code}" != "403" ]]; then
    echo "${blocked_path} 返回 ${code}，预期为 403。"
    false
  fi
done

trap - ERR
echo "限制成功：仅保留 https://${DOMAIN}${URL_PREFIX}/"
echo "其他域名路径已关闭；后台进程本身未被删除或停止。"
echo "回滚备份：${BACKUP_FILE}"
