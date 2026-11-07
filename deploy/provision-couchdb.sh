#!/usr/bin/env bash
# 幂等初始化 CouchDB：单节点、鉴权、CORS、大文档、数据库、账号、只读权限。
# 依赖：curl、python3、一份 /opt/couchdb/.env
set -euo pipefail

ENV_FILE="${ENV_FILE:-/opt/couchdb/.env}"
DB="${DB:-obsidiannotes}"
BASE="http://127.0.0.1:5984"

# shellcheck disable=SC1090
source "$ENV_FILE"
: "${COUCH_USER:?}" "${COUCH_PASS:?}"
ADMIN=(-u "$COUCH_USER:$COUCH_PASS")
CT=(-H 'Content-Type: application/json')

say(){ printf '\n>>> %s\n' "$*"; }

# 0. 等 CouchDB 起来
for i in $(seq 1 60); do
  curl -fsS "${ADMIN[@]}" "$BASE/" >/dev/null 2>&1 && break
  sleep 1
done

# 1. 单节点集群（已初始化会返回 400，忽略）
say "enable_single_node"
curl -sS "${ADMIN[@]}" "${CT[@]}" -X POST "$BASE/_cluster_setup" \
  -d '{"action":"enable_single_node","bind_address":"0.0.0.0","port":5984,"singlenode":true}' \
  | head -c 300; echo

# 2. 运行期配置
# require_valid_user=true 是安全底线：匿名一律 401。
# cors.origins 里 app://obsidian.md 是 Obsidian 桌面端的 origin，漏了会预检失败。
cfg(){
  printf '  %-42s' "$1/$2"
  curl -sS "${ADMIN[@]}" -X PUT "$BASE/_node/_local/_config/$1/$2" \
    -H 'Content-Type: application/json' -d "$3"; echo
}
say "config"
cfg chttpd       require_valid_user      '"true"'
cfg chttpd_auth  require_valid_user      '"true"'
cfg httpd        WWW-Authenticate        '"Basic realm=\"couchdb\""'
cfg httpd        enable_cors             '"true"'
cfg chttpd       enable_cors             '"true"'
cfg chttpd       max_http_request_size   '"4294967296"'
cfg couchdb      max_document_size       '"1073741824"'
cfg cors         credentials             '"true"'
cfg cors         origins                 '"app://obsidian.md,capacitor://localhost,http://localhost"'

# 3. 数据库（已存在返回 412，忽略）
say "database $DB"
curl -sS "${ADMIN[@]}" -X PUT "$BASE/$DB" | head -c 200; echo

# 4. 账号
mkuser(){ # name pass roles_json
  local id="org.couchdb.user:$1" body
  if curl -fsS "${ADMIN[@]}" "$BASE/_users/$id" >/dev/null 2>&1; then
    local rev; rev=$(curl -fsS "${ADMIN[@]}" "$BASE/_users/$id" | python3 -c 'import sys,json;print(json.load(sys.stdin)["_rev"])')
    body=$(printf '{"_id":"%s","_rev":"%s","name":"%s","type":"user","roles":%s,"password":"%s"}' "$id" "$rev" "$1" "$3" "$2")
  else
    body=$(printf '{"_id":"%s","name":"%s","type":"user","roles":%s,"password":"%s"}' "$id" "$1" "$3" "$2")
  fi
  printf '  %-20s' "$1"
  curl -sS "${ADMIN[@]}" "${CT[@]}" -X PUT "$BASE/_users/$id" -d "$body" | head -c 160; echo
}
say "users"
mkuser "$SYNC_USER" "${SYNC_PASS:?}" '["sync-user","editor"]'
mkuser "readonly-test" "${RO_PASS:?}" '["sync-user","reader"]'

# 5. 成员唯一入口：只有 sync-user 角色能读写本库
say "_security"
curl -sS "${ADMIN[@]}" "${CT[@]}" -X PUT "$BASE/$DB/_security" -d "{
  \"admins\":{\"names\":[\"$COUCH_USER\"],\"roles\":[\"_admin\"]},
  \"members\":{\"names\":[],\"roles\":[\"sync-user\"]}
}"; echo

# 6. 只读账号的拦截规则
# 注意顺序：先把 _design/permissions 放进去会让 doc_count>0，
# LiveSync 首次连接会误判「这不是我的库」并拒绝初始化。
# 所以新库务必：先让客户端完成一次初始化，再执行本节（脚本末尾会提示）。
say "_design/permissions"
curl -sS "${ADMIN[@]}" "${CT[@]}" -X PUT "$BASE/$DB/_design/permissions" -d '{
  "validate_doc_update": "function(newDoc, oldDoc, userCtx) { if (userCtx.roles.indexOf(\"_admin\") !== -1) { return; } var isReader = userCtx.roles.indexOf(\"reader\") !== -1; var isEditor = userCtx.roles.indexOf(\"editor\") !== -1; if (isReader && !isEditor) { throw({forbidden: \"read-only account\"}); } }"
}'; echo

cat <<'NOTE'

--------------------------------------------------------------
完成。验收：

  curl -u alice:PASS   -X GET  https://HOST/couch/obsidiannotes/   # 200
  curl                  -X GET  https://HOST/couch/obsidiannotes/   # 401
  curl -u readonly:PASS -X PUT  https://HOST/couch/obsidiannotes/x -d '{}'  # 403 read-only account

⚠ 如果是全新空库：先把 _design/permissions 删掉，让 Obsidian 客户端完成首次
  初始化（生成 obsydian_livesync_version），再重新 PUT 回来。
  原因见 docs/05-运维与排错.md「远程数据库较新或已损坏」。
--------------------------------------------------------------
NOTE
