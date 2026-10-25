# `backend/cmd/jwtgen`

`jwtgen` 是 JWT 签发工具。它读取当前应用配置并连接 PostgreSQL，按邮箱查找用户或选择第一个活动管理员，然后调用应用的认证服务生成 JWT。它**不创建管理员、不修改密码，也不会启动 HTTP 服务**。

源码入口：[`main.go`](../../backend/cmd/jwtgen/main.go)。

## 运行

在 `backend/` 目录执行：

```bash
# 指定登录邮箱
go run ./cmd/jwtgen --email admin@example.com

# 不指定邮箱：选择第一个活动管理员
go run ./cmd/jwtgen

# 编译成单独的运维工具
go build -o ./bin/jwtgen ./cmd/jwtgen
./bin/jwtgen --email admin@example.com
```

也可用 `-email` 形式。省略 email 时，工具使用 repository 的 `GetFirstAdmin` 逻辑选取管理员；需要确定用户时，建议总是显式传入邮箱。

## 参数

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `--email EMAIL` | 空 | 为该邮箱对应用户签发 JWT；省略时选第一个活动管理员。 |

Go 标准 flag 同时支持 `-email` 和 `--email`。`--help`/`-h` 可显示参数帮助。

## 配置要求

工具调用 `config.LoadForBootstrap()` 和 `repository.InitEnt()`，所以需要：

- 后端可读取的应用配置，常见来源是 `config.yaml` / `DATA_DIR` 和环境变量。
- 可连接的 PostgreSQL，数据库 schema 已初始化。
- 目标邮箱对应的用户存在；如操作意图是管理员 token，由操作者自行核实该账号确为管理员。

`InitEnt` 会确保数据库迁移与当前程序 schema 同步；因此即便工具只为签发 token，也可能在数据库上执行待应用迁移。生产操作前应确认配置指向正确数据库，并按组织变更流程运行。

## 输出和凭据安全

指定 `--email` 时，源码按邮箱直接查找用户，并不会额外验证该用户是否为管理员；省略参数才使用 `GetFirstAdmin`。因此显式指定时必须核对邮箱和账号身份，避免意外为普通账号签发 token。

成功时输出三行：

```text
ADMIN_EMAIL=<邮箱>
ADMIN_USER_ID=<用户 ID>
JWT=<签发的 token>
```

JWT 是可用于认证的敏感凭证。不要将输出贴入聊天、工单、Shell history、CI 日志或共享终端录屏；避免使用会把 stdout 长期保存到权限宽松文件的重定向。若 token 被泄露，应按认证密钥/会话策略进行处置。

数据库连接失败、管理员查找失败或签发失败时，程序向 stderr 输出错误并以非零状态结束。

## 线上 Docker 环境

生产应用镜像不包含 `jwtgen`，也没有 Go 编译器。请在与生产相同的可信源码版本编译 Linux 目标二进制，再使用生产 Compose 配置通过临时 `docker compose run` 容器运行；这样会复用应用网络、环境变量和配置卷，而不是把生产数据库暴露到运维主机。完整命令和敏感输出处理见[线上 Docker 运维](./online-docker.md#5-运行-jwt-签发和日志清理工具)。
