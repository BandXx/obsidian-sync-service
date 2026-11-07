#!/usr/bin/env bash
# 一键部署：在全新 VPS 上把 CouchDB 同步服务跑起来，并配好 HTTPS 反代。
#
#   curl -fsSL https://raw.githubusercontent.com/BandXx/obsidian-sync-service/main/deploy/install.sh \
#     | bash -s -- --domain notes.example.com --email you@example.com
#
# 可选参数：
#   --domain   必填，已解析到本机的域名
#   --email    必填，Let's Encrypt 通知邮箱
#   --mirror   Docker 镜像源，默认 docker.m.daocloud.io（Docker Hub 不可达时用）
#   --db       数据库名，默认 obsidiannotes
#   --dry-run  只打印将执行的动作，不落地
set -euo pipefail

RAW="https://raw.githubusercontent.com/BandXx/obsidian-sync-service/main"
DOMAIN=""; EMAIL=""; MIRROR="docker.m.daocloud.io"; DB="obsidiannotes"; DRY=0
PREFIX=/opt/couchdb

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)   DOMAIN="${2:?}"; shift 2 ;;
    --email)    EMAIL="${2:?}";  shift 2 ;;
    --mirror)   MIRROR="${2:?}"; shift 2 ;;
    --db)       DB="${2:?}";     shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  cat <<'HLP'
一键部署 Obsidian CouchDB 同步服务

  curl -fsSL https://raw.githubusercontent.com/BandXx/obsidian-sync-service/main/deploy/install.sh \
    | bash -s -- --domain notes.example.com --email you@example.com

  --domain  必填，已解析到本机的域名
  --email   必填，Let's Encrypt 通知邮箱
  --mirror  Docker 镜像源，默认 docker.m.daocloud.io
  --db      数据库名，默认 obsidiannotes
  --dry-run 只打印动作，不落地
HLP
                exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

die(){ echo "错误: $*" >&2; exit 1; }
run(){ if [ "$DRY" = 1 ]; then echo "  [dry] $*"; else "$@"; fi; }

[ -n "$DOMAIN" ] || die "缺少 --domain"
[ -n "$EMAIL" ]  || die "缺少 --email"
[ "$(id -u)" = 0 ] || die "需要 root 权限"

echo "==> 目标：https://$DOMAIN/couch   库：$DB"

# ---------- 1. Docker ----------
if ! command -v docker >/dev/null 2>&1; then
  echo "==> 安装 Docker"
  run apt-get update -qq
  run apt-get install -y -qq docker.io docker-compose-v2 curl ca-certificates
  run systemctl enable --now docker
else
  echo "==> Docker 已存在：$(docker --version)"
fi

# ---------- 2. 目录与口令 ----------
echo "==> 准备 $PREFIX"
run mkdir -p "$PREFIX"/{data,etc}
run chown -R 5984:5984 "$PREFIX"/data

if [ ! -f "$PREFIX/.env" ]; then
  gen(){ LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }
  if [ "$DRY" = 1 ]; then
    echo "  [dry] 生成 $PREFIX/.env"
  else
    cat > "$PREFIX/.env" <<ENV
COUCH_USER=livesync
COUCH_PASS=$(gen)
SYNC_USER=alice
SYNC_PASS=$(gen)
RO_PASS=$(gen)
ENV
    chmod 600 "$PREFIX/.env"
  fi
fi

# ---------- 3. 镜像与容器 ----------
echo "==> 拉取 couchdb:3.4"
if ! docker image inspect couchdb:3.4 >/dev/null 2>&1; then
  run docker pull "$MIRROR/library/couchdb:3.4"
  run docker tag  "$MIRROR/library/couchdb:3.4" couchdb:3.4
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/docker-compose.yml" <<'YML'
services:
  couchdb:
    image: couchdb:3.4
    container_name: couchdb-livesync
    user: 5984:5984
    restart: unless-stopped
    environment:
      - COUCHDB_USER=${COUCH_USER}
      - COUCHDB_PASSWORD=${COUCH_PASS}
    volumes:
      - /opt/couchdb/data:/opt/couchdb/data
      - /opt/couchdb/etc:/opt/couchdb/etc/local.d
    ports:
      - 127.0.0.1:5984:5984
    mem_limit: 512m
YML
run cp "$TMP/docker-compose.yml" "$PREFIX/docker-compose.yml"

echo "==> 启动容器"
if [ "$DRY" = 0 ]; then ( cd "$PREFIX" && docker compose up -d ); else echo "  [dry] docker compose up -d"; fi

# ---------- 4. CouchDB 初始化 ----------
echo "==> 初始化 CouchDB（单节点 / 鉴权 / CORS / 账号 / 只读权限）"
if [ "$DRY" = 0 ]; then
  # 等端口就绪
  for i in $(seq 1 90); do
    curl -fsS -u "$(grep COUCH_USER "$PREFIX/.env"|cut -d= -f2):$(grep COUCH_PASS "$PREFIX/.env"|cut -d= -f2)" \
      http://127.0.0.1:5984/ >/dev/null 2>&1 && break
    sleep 1
  done
  # 管道执行时本地没有 provision 脚本，从仓库取一份
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || echo .)"
  PROV="$SELF_DIR/provision-couchdb.sh"
  if [ ! -f "$PROV" ]; then
    curl -fsSL "$RAW/deploy/provision-couchdb.sh" -o "$TMP/provision-couchdb.sh"
    PROV="$TMP/provision-couchdb.sh"
  fi
  ENV_FILE="$PREFIX/.env" DB="$DB" bash "$PROV"
else
  echo "  [dry] 调用 provision-couchdb.sh"
fi

# ---------- 5. nginx + 证书 ----------
echo "==> 配置 nginx"
run apt-get install -y -qq nginx certbot python3-certbot-nginx

if [ "$DRY" = 0 ]; then
  cat > /etc/nginx/sites-available/obsidian-sync <<NGX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ { root /var/www/html; }

    location /couch/ {
        proxy_pass http://127.0.0.1:5984/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 512m;
    }
}
NGX
  ln -sf /etc/nginx/sites-available/obsidian-sync /etc/nginx/sites-enabled/obsidian-sync
  nginx -t
  systemctl reload nginx
  certbot --nginx -d "$DOMAIN" --email "$EMAIL" --agree-tos -n --redirect
else
  echo "  [dry] 写 nginx 站点 + certbot"
fi

# ---------- 6. 验收 ----------
echo
echo "==> 验收"
if [ "$DRY" = 0 ]; then
  # shellcheck disable=SC1090
  source "$PREFIX/.env"
  printf '  匿名访问（应为 401）: '
  curl -s -o /dev/null -w '%{http_code}\n' "https://$DOMAIN/couch/$DB/"
  printf '  带鉴权（应为 200）:   '
  curl -s -o /dev/null -w '%{http_code}\n' -u "$SYNC_USER:$SYNC_PASS" "https://$DOMAIN/couch/$DB/"
fi

# 摘要里要显示真实账号名，先在 shell 里取出来（heredoc 是 quoted，不做展开）
ADMIN_NAME="livesync"; SYNC_NAME="alice"
if [ -f "$PREFIX/.env" ]; then
  ADMIN_NAME=$(grep -m1 '^COUCH_USER=' "$PREFIX/.env" 2>/dev/null | cut -d= -f2 || true)
  SYNC_NAME=$(grep  -m1 '^SYNC_USER='  "$PREFIX/.env" 2>/dev/null | cut -d= -f2 || true)
  ADMIN_NAME=${ADMIN_NAME:-livesync}
  SYNC_NAME=${SYNC_NAME:-alice}
fi

cat <<DONE

--------------------------------------------------------------
部署完成。

  服务地址   https://$DOMAIN/couch
  数据库     $DB
  口令文件   $PREFIX/.env   （chmod 600，抄走后可删）
  管理员     $ADMIN_NAME
  普通用户   $SYNC_NAME

客户端（Obsidian + Self-hosted LiveSync）填：
  URI   https://$DOMAIN/couch
  库名  $DB
  账号  见上
  ★ 大小写敏感性必须保持关闭

⚠ 全新空库时，先让客户端完成一次初始化，再手动 PUT _design/permissions，
  否则会卡在「远程数据库较新或已损坏」。原因见 docs/05-运维与排错.md 第 1 节。
--------------------------------------------------------------
DONE
