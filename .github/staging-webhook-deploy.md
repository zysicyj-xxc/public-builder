# Staging webhook deploy

测试环境部署只走本仓库。手动 `workflow_dispatch` 拉私仓指定提交，构建 staging 包，再 POST 到 daymica-staging-deployer 的公网入口。不加入 `poll-private-gates`。不改生产工作流，不改 .1、frpc 或前置代理。

## 请求

- 方法、地址：`POST https://test-daymica.zysicyj.top/__staging-deploy`
- 鉴权：`Authorization: Bearer`，值是 `secrets.STAGING_WEBHOOK_DEPLOY_KEY`。没有 HMAC。
- 密钥和源站地址不进 `curl` 的 argv。它们写在 `--config -` 的 stdin 里。公开日志不打印这两项；步骤开头用 `::add-mask::`，脚本里没有 `set -x`。
- 大包若走 ESA，大约 12 秒会 504。必须用 `secrets.STAGING_ORIGIN_IP`：

  `resolve = "test-daymica.zysicyj.top:443:<IP>"`

  GitHub hosted runner 不直连 deployer 的 18089。它访问该主机名的 443，由 `--resolve` 指到源站。`STAGING_ORIGIN_IP` 填这个 443 地址，不要填 18089。
- multipart 顺序：`sha`（40 位小写 hex），然后 `archive`（`staging-<sha>.tar.gz`）。不传 `nginx`。
- 包：gzip tar；压缩后 ≤200MiB；解压后 ≤400MiB。只允许 `daymica-server`、`seed-e2e-account`、`prod-sql-gate` 和 `web/`。必须同时有 `daymica-server` 和 `web/index.html`。不能有软链接、硬链接或路径穿越。公开侧在发出请求前检查；私仓 `scripts/ci/staging-deploy.sh build` 负责编译。只调用 `build`，不调用它的 `deploy`。
- curl `--connect-timeout 15`，`--max-time 150`。接收端安装后会重启后端，并最多等 45 秒看 `/version` 是否为本 sha，超时自行回滚。前置代理的读超时大约 120 秒，所以客户端要盖住这段等待，而不是用默认的无限制。
- 返回码：200 已安装；400 包不合规；401 鉴权失败；409 有部署在跑（退避重试，最多 6 次，间隔 5/10/20/30/30 秒）；413 包太大；500 已自动回滚；502 和 504 不重试。其它码也不重试。200 的 JSON 若带 `commit`，必须等于本次 sha。

## 日志

公开日志只有 `PASS` / `FAIL`。构建输出写在 runner 临时文件里，失败且配置了已有的 `GATE_LOG_KEY` 时才加密上传。本工作流在 `purge-gate-logs.sh` 的清单里，因为 runner 会 checkout 私仓。

## 密钥

| 名称 | 作用 |
|---|---|
| `PRIVATE_REPO_ACCESS_TOKEN` | 已有。只用于 checkout 私仓 |
| `STAGING_WEBHOOK_DEPLOY_KEY` | Bearer。不要改名 |
| `STAGING_ORIGIN_IP` | `--resolve` 的 IPv4。不要改名 |
| `GATE_LOG_KEY` | 已有。只加密失败详情，可以不配 |

不新增 PAT。不读取、不打印密钥的值。
