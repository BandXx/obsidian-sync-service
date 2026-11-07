# AGENTS.md

给在本仓库里工作的 AI 代理（以及接手的人）看的操作说明。**动手前读完这一页。**

---

## 这个仓库是什么

一套自建 Obsidian 云端同步服务的**可复现部署包**：CouchDB 当主存储，客户端用 Self-hosted LiveSync 插件读写。仓库里只有配置、脚本和文档，没有任何笔记内容。

关键认知：**服务端是数据主体，客户端只是缓存。** 客户端离线不丢数据，卸载重装能全量拉回。任何「备份」讨论都要从这个前提出发。

```
Obsidian 客户端 ──HTTPS + Basic Auth + E2E──► nginx /couch/ ──► CouchDB 127.0.0.1:5984
```

## 目录

| 路径 | 作用 | 改它的前提 |
|---|---|---|
| `deploy/install.sh` | 一键部署（Docker → CouchDB → nginx → 证书 → 验收） | 改完必须在真机 `--dry-run` 跑通 |
| `deploy/provision-couchdb.sh` | 幂等初始化：单节点、鉴权、CORS、库、账号、只读权限 | 每一步都必须可重复执行 |
| `deploy/docker-compose.yml` | 从生产实例导出的原样配置 | 不要加端口暴露 |
| `deploy/nginx-obsidian-sync.conf` | 生产实例的完整站点配置（含可选 Live Share 中继） | `nginx -t` 通过才算改完 |
| `client/data.json.template` | 客户端设置全量预置值 | 改一个键就要同步改文档解释 |
| `docs/01`–`04` | 部署记录、用户手册、同事接入、架构图 | 面向非程序员 |
| `docs/05-运维与排错.md` | 六个真实坑位，含报错原文 | **只增不删**，见下 |

## 不可违反的约束

违反任意一条，同步会以极难诊断的方式失败。

### 1. 空库首次同步前，不要放 `_design/permissions`

LiveSync 初始化时检查 `obsydian_livesync_version`（拼写就是 `obsydian`）。找不到时执行：

```js
if (isErrorOfMissingDoc(e)) {
  const info = await db.info();
  return !(info.doc_count > 0) && await bumpRemoteVersion(...)
}
```

**只要 `doc_count > 0` 就拒绝初始化**，报错是「远程数据库较新或已损坏」。提前放任何设计文档都会触发。
正确顺序：空库 → 客户端跑一次同步 → 出现版本文档 → 再 PUT `_design/permissions`。

### 2. `handleFilenameCaseSensitive` 永远为 `false`

文档 ID = `hashString(hashString(namespace) + ":" + path)`，路径会先转小写。改成 `true` 等于换一套 ID 命名空间，与既有上万文档全部对不上，日志报 `The remote document IDs do not match the configured ID key.`，整场同步被拒。

### 3. CouchDB 只绑 `127.0.0.1`

外部流量必须经 nginx。`docker-compose.yml` 里 `ports: 127.0.0.1:5984:5984` 不要改成 `5984:5984`。
同理 `_cluster_setup` 的 `bind_address` 要传 `0.0.0.0`（容器内），传 `127.0.0.1` 会让端口映射失效。

### 4. `require_valid_user` 必须为 `true`

安全底线。匿名访问一律 401。改这个值等于把库公开。

### 5. nginx 的反代路径

- `location /couch/` + `proxy_pass http://127.0.0.1:5984/;`（**末尾斜杠**，用于剥掉 `/couch` 前缀）
- CouchDB 官方不建议挂在根路径，`/couch/` 是刻意选择
- WebSocket 段（`/ws-mux`、`/control`）必须透传 `Upgrade` 与 `Connection`，并给足 `proxy_read_timeout`

### 6. 不提交敏感值

`.env`、`data.json`、真实域名、服务器 IP、账号名、E2E 口令，**都不进仓库**。文档统一用
`YOUR_DOMAIN` / `YOUR_SERVER_IP` / `alice` / `‹…›` 占位。

改完先自查：

```bash
git log -p --all | grep -ciE '([0-9]{1,3}\.){3}[0-9]{1,3}|password|passphrase' # 只允许 127.0.0.1
```

## 验证方式

判断同步是否真的在工作，**只看服务端的 `update_seq` 增量**，不要看客户端状态栏（那可能属于已停用的其他插件）。

```bash
# 服务器上
curl -s -u ADMIN http://127.0.0.1:5984/DB | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["doc_count"],d["update_seq"])'

# 分类计数：f=文件 h=内容块 i=内部配置
curl -s -u ADMIN 'http://127.0.0.1:5984/DB/_all_docs?limit=5000' | python3 -c "
import sys,json,collections
rows=json.load(sys.stdin)['rows']
print(collections.Counter(r['id'][:2] for r in rows))"
```

`doc_count` 与本地文件数对得上，说明没有丢，问题在客户端的过滤规则，去看 `docs/05` 第 3 节。

## 文档写作规范

- 中文，面向非程序员，少用黑话；每个设置项要解释**它控制什么**，而不是只给值
- **报错原文一字不改**地贴出来，不翻译、不改写 —— 别人是靠这段字符串搜到这里的
- 结论要有依据：写「实测 20 秒内增量到 seq 122→124」，不写「同步正常」
- 不确定的地方写明「未验证」，不要用推测填空

## 常见误改

| 改法 | 后果 |
|---|---|
| 把 `/couch/` 改成 `/` | 客户端填 URI 后 404，且 CORS 的 origin 规则要重写 |
| 给 `provision` 加 `_security` 之外的成员约束 | 新账号能登录但读写全 403 |
| 调大 `mem_limit` 无上限 | 1.6G 小机器会 OOM，CouchDB 512m 足够支撑千万级文档 |
| 在 `docs/05` 里删掉「已解决」的坑 | 下次重装会再踩一遍 |
