# Obsidian 云端同步服务（自建）

一套在自有服务器上跑 Obsidian 多端同步的完整方案：CouchDB 作为**主存储**，客户端用 Self-hosted LiveSync 插件读写它。任何一台设备离线都不影响数据，因为数据不在客户端「备份」，客户端只是缓存。

替代的托管方案（Obsidian Sync 官方 / 各类网盘）在**权限管理**和**数据归属**上有取舍，这套方案把两者都握在自己手里。

```
Obsidian 桌面端/手机端
        │  HTTPS + Basic Auth + 端到端加密
        ▼
   nginx (443, Let's Encrypt)
        │  location /couch/ → 127.0.0.1:5984
        ▼
   CouchDB 3.4（Docker，仅监听环回）
   库 obsidiannotes，账号级读写权限
```

## 为什么是 CouchDB + LiveSync

| 方案 | 主存储在服务端 | 账号级权限 | 手机端 | 冲突处理 |
|---|---|---|---|---|
| Live Share（Yjs 中继） | 否，纯转发 | 否 | 否（桌面专用） | CRDT 实时合并 |
| Obsidian Git | 否，本地优先 | 否 | 弱 | 文本冲突 |
| **CouchDB + LiveSync** | **是** | **是**（`_security` + `_design` 校验） | **是** | 自动合并 + `.conflict` 副本 |

代价：服务端只见加密后的哈希文档，无法在服务器上 `ls` 出真实目录。这是端到端加密的必然结果。

> **关于本文档**：仓库里的域名、IP、账号名已替换为 `YOUR_DOMAIN` / `YOUR_SERVER_IP` / `alice` 等占位符。部署时按实际情况替换即可；文档里的原理、参数、报错原文都是实测结果，未做删改。

## 一键部署

一台已解析好域名的全新 VPS 上，一条命令装完 Docker、CouchDB、nginx、证书：

```bash
curl -fsSL https://raw.githubusercontent.com/BandXx/obsidian-sync-service/main/deploy/install.sh \
  | bash -s -- --domain notes.example.com --email you@example.com
```

结束时会打印服务地址、账号名和口令文件位置，并自动跑匿名 401 / 鉴权 200 的验收。
加 `--dry-run` 可以只看它会做什么，不落地。

## 服务器部署（约 10 分钟，手动版）

前置：一台 1C1G 以上的 Linux，域名已解析到它，已装 Docker + Compose 插件。

```bash
# 1. 放脚本
scp -r deploy/ root@YOUR_HOST:/opt/

# 2. 生成口令、拉镜像、起容器、初始化 CouchDB
ssh root@YOUR_HOST 'bash /opt/deploy/bootstrap-server.sh'
# → 口令写在 /opt/couchdb/.env（chmod 600），自己抄走

# 3. 反代 + 证书
cp /opt/deploy/nginx-obsidian-sync.conf /etc/nginx/sites-available/obsidian-sync
# 按需改 server_name，然后
ln -s /etc/nginx/sites-available/obsidian-sync /etc/nginx/sites-enabled/
certbot --nginx -d YOUR_DOMAIN
nginx -t && systemctl reload nginx

# 4. 验收
curl -u alice:PASS https://YOUR_DOMAIN/couch/obsidiannotes/    # 200
curl               https://YOUR_DOMAIN/couch/obsidiannotes/     # 401
```

`nginx-obsidian-sync.conf` 里还带着一个可选的 Live Share 中继（`/ws-mux`、`/control` → 127.0.0.1:3210）。只用 CouchDB 的话删掉这两段即可。

## 客户端配置

1. 装社区插件 **Self-hosted LiveSync**（`obsidian-livesync`，作者 vrtmrz）。
2. 填 5 个值：`https://YOUR_DOMAIN/couch`、库名 `obsidiannotes`、用户名、密码、E2E 口令。
3. 开「隐藏文件同步」「处理大小不匹配的文件」，把「最大文件大小」调到 102400。
4. **「大小写敏感性」必须保持关闭**，理由见 [docs/05-运维与排错.md](docs/05-运维与排错.md)。

也可以直接用 [client/data.json.template](client/data.json.template) 预置，比在界面里逐项点快得多。

## 权限模型

三个角色，全部落在 CouchDB 的 `_security` 与 `_design/permissions` 上，不依赖应用层：

| 角色 | 能做什么 | 实现 |
|---|---|---|
| `_admin` | 全部 | `_security.admins` |
| `sync-user` + `editor` | 读写同步 | `_security.members` |
| `sync-user` + `reader` | 只读，写入被拒 | `validate_doc_update` 抛 `forbidden` |

新增一个只读成员：

```bash
curl -u ADMIN -X PUT https://HOST/couch/_users/org.couchdb.user:guest \
  -H 'Content-Type: application/json' \
  -d '{"name":"guest","type":"user","roles":["sync-user","reader"],"password":"..."}'
```

收回权限：把 `roles` 改掉，或从 `_security.members` 里移出该角色即可。

## 文档

| 文件 | 内容 |
|---|---|
| [docs/01-部署记录.md](docs/01-部署记录.md) | 这台机器的实际部署过程、最终参数、走过的弯路 |
| [docs/02-用户手册.md](docs/02-用户手册.md) | 给使用者看的操作说明与故障速查 |
| [docs/03-同事接入.md](docs/03-同事接入.md) | 新成员从零到同步成功的最短路径 |
| [docs/04-架构图.md](docs/04-架构图.md) | 数据流与组件关系 |
| [docs/05-运维与排错.md](docs/05-运维与排错.md) | **六个真实踩过的坑**，含报错原文与判定顺序 |
| [AGENTS.md](AGENTS.md) | 给 AI 代理/接手者的操作约束：六条不可违反的规则 |

## 已知边界

- 服务器只见哈希文档 ID，`usePathObfuscation` + `encryptInternalMetadata` 打开后尤其如此。想在服务器上按真实路径查看，必须在**空库阶段**就关掉这两项，中途关闭会触发全量重传。
- 端到端加密的口令一旦丢失，服务端数据无法解密。口令要单独留存，不要只存在同步库里。
- 单 CouchDB 实例，没有集群和异地副本。定期 `_all_docs?include_docs=true` 导出到库外。
- 文档大小上限已在服务端放宽到 1GB，但客户端单文件上传仍受网络与内存约束，超大附件建议外置。
