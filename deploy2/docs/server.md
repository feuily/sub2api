# `backend/cmd/server`

这是 Sub2API 后端服务主入口，负责首次安装分流、应用依赖初始化、HTTP 服务启动、可选后台组件启动和优雅关停。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| [`main.go`](../../backend/cmd/server/main.go) | 进程入口；解析 CLI flags；选择版本输出、交互安装、自动安装或正常运行；处理服务退出信号。 |
| [`wire.go`](../../backend/cmd/server/wire.go) | Google Wire 的依赖注入定义；声明应用对象、provider sets、构建信息和清理流程。 |
| [`wire_gen.go`](../../backend/cmd/server/wire_gen.go) | Wire 根据 `wire.go` 生成的注入代码。不要手动编辑。 |
| [`VERSION`](../../backend/cmd/server/VERSION) | 源码构建时使用的默认版本号；精确 Git release tag 优先级更高。 |
| [`wire_gen_test.go`](../../backend/cmd/server/wire_gen_test.go) | 验证构建信息 provider、清理函数等生成代码行为。 |

`main.go` 中的 `Version`、`Commit`、`Date`、`BuildType` 可由构建参数写入。版本默认从 `VERSION` 嵌入二进制；`BuildType` 默认为 `source`。

## 运行方式

在 `backend/` 目录：

```bash
# 显示版本和构建信息后退出
go run ./cmd/server --version

# 无配置时启动首次安装 Web 向导
go run ./cmd/server

# 直接在终端执行交互式安装向导
go run ./cmd/server --setup

# 编译服务
make build
./bin/server --version
./bin/server
```

Go 标准库 `flag` 支持 `-version`/`--version` 和 `-setup`/`--setup` 形式。可通过 `--help` 查看标准 flag 帮助。

从仓库根目录也可执行：

```bash
go -C backend run ./cmd/server --version
```

### `--version`

打印 `Sub2API <版本> (commit: <提交>, built: <时间>)` 后退出，不初始化服务依赖。手动构建时如需在链接阶段写入版本信息，后端 Makefile 已通过 `VERSION`/`LDFLAGS` 处理；Docker/release 构建也会注入相应 build metadata。

### `--setup`

运行终端安装向导，交互输入 PostgreSQL、Redis、管理员及服务配置。向导会验证输入和数据库/Redis 连通性；用户确认安装后会初始化迁移、创建初始管理员（只在适合的空库状态下创建）、写入配置和安装锁文件。

此命令不是“重置配置”功能：系统已安装时会拒绝重新安装。操作前确认当前目录/`DATA_DIR` 指向目标实例，并为数据库做好备份。管理员密码不会回显输入。

### 无参数启动

服务按以下分支启动：

1. 若 `NeedsSetup()` 判断尚未安装且 `SKIP_SETUP` 未开启：
   - `AUTO_SETUP=true` 时从环境变量执行自动安装；
   - 否则启动 Web 安装向导并等待浏览器完成配置。
2. 安装完成或已配置后，加载运行配置、构建依赖、启动 HTTP 服务。
3. 启动插件管理器和 Prompt Audit 等可选组件；个别可降级组件启动失败会记录日志，服务按代码策略继续或以失败终止。
4. 等待 `SIGINT`/`SIGTERM`，关闭 HTTP listener，并调用 `Cleanup` 停止后台 workers、服务和基础设施连接。

正常服务至少需要可用的 PostgreSQL、Redis 和应用配置。Docker Compose 开发部署会用 `AUTO_SETUP=true` 并通过环境变量配置数据库、Redis 和端口。二进制部署通常先用 Web/CLI 向导创建 `config.yaml`。

线上 Docker 环境的状态、日志、依赖连通性、重启及版本检查命令见[线上 Docker 运维](./online-docker.md#线上-docker-环境运维)。生产启停应通过部署时使用的 Compose project 管理；不要在容器里额外启动一个服务进程。

## 常用运行配置

以下是理解启动行为的重要变量，完整变量定义和优先级以配置模块及部署模板为准：

| 变量 | 用途 |
| --- | --- |
| `DATA_DIR` | 配置 YAML、安装锁及本地数据的目录。未设置时 Docker 环境优先使用可写的 `/app/data`，否则使用当前工作目录。 |
| `SERVER_HOST`、`SERVER_PORT` | 首次安装服务地址/端口；应用主配置也可定义 server address。 |
| `AUTO_SETUP` | 容器自动安装开关。设置为 true 后使用环境变量初始化数据库、Redis 和管理员。 |
| `SKIP_SETUP` | `true`、`1` 或 `yes` 时跳过首次安装检测；不是数据库初始化或迁移的替代品。 |
| `DATABASE_*` | PostgreSQL 主机、端口、用户、密码、库名和连接设置。 |
| `REDIS_*` | Redis 主机、端口、凭据、DB 和 TLS 设置。 |
| `ADMIN_EMAIL`、`ADMIN_PASSWORD` | 自动安装创建首位管理员的凭据。应显式提供并妥善保管；若自动安装缺少密码，系统会生成一次性密码并输出到日志。 |
| `JWT_SECRET` | 固定 JWT 签名密钥；生产环境应持久配置，避免重启后登录 token 失效。 |

配置细节见 [`deploy/.env.example`](../../deploy/.env.example)、[`deploy/config.example.yaml`](../../deploy/config.example.yaml) 及配置实现；不要把含秘密的真实配置写进本文档。

## Wire 依赖注入代码

`wire.go` 是生成器输入，主要工作：

- 汇总 `config`、`repository`、`service`、`securityaudit`、`payment`、middleware、handler 和 server 的 provider sets。
- 将服务版本/构建类型传入 HTTP handler 和插件宿主。
- 构造 `Application`，包括 HTTP server、可选 Prompt Audit/插件管理器以及统一 `Cleanup`。
- 声明多个应用服务停止流程；应用层清理并行执行，Redis/Ent 等基础设施最后按顺序关闭，并有 10 秒清理超时。

修改 provider 后在 `backend/` 目录执行：

```bash
go generate ./cmd/server
```

生成结果提交在 `wire_gen.go`。不要在生成文件中手工添加依赖或改清理流程。

更完整的 `cmd/server` 调用链、模块装配、路由/middleware、后台任务生命周期和新功能开发指南，见[启动流程与架构导读](./server-startup-architecture.md)。
中间件的全局执行顺序、认证和权限模型、Gateway 中间件链及扩展方式，另见[Server 中间件架构说明](./server-middleware.md)。
配置来源优先级、默认值解析、JWT bootstrap 和 server 配置校验过程见[配置加载与默认值解析](./server-config-loading.md)。
