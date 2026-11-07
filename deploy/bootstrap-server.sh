#!/usr/bin/env bash
# 首次准备：目录、随机口令、拉镜像（走国内可用镜像源）、启动容器、初始化。
# 适用：Ubuntu 22.04/24.04，已装 docker + compose 插件。
set -euo pipefail

PREFIX=/opt/couchdb
MIRROR=${MIRROR:-docker.m.daocloud.io}

mkdir -p "$PREFIX"/{data,etc}
chown -R 5984:5984 "$PREFIX"/data

if [ ! -f "$PREFIX/.env" ]; then
  gen(){ LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }
  cat > "$PREFIX/.env" <<ENV
COUCH_USER=livesync
COUCH_PASS=$(gen)
SYNC_USER=alice
SYNC_PASS=$(gen)
RO_PASS=$(gen)
ENV
  chmod 600 "$PREFIX/.env"
  echo "已生成 $PREFIX/.env，请自行保存其中的口令。"
fi

# Docker Hub 在部分网络下不可达，先用镜像源拉再打回原名。
if ! docker image inspect couchdb:3.4 >/dev/null 2>&1; then
  docker pull "$MIRROR/library/couchdb:3.4"
  docker tag  "$MIRROR/library/couchdb:3.4" couchdb:3.4
fi

cp -n "$(dirname "$0")/docker-compose.yml" "$PREFIX/docker-compose.yml"
cd "$PREFIX" && docker compose up -d

sleep 5
bash "$(dirname "$0")/provision-couchdb.sh"
