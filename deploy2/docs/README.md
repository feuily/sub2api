# Backend 命令行工具索引

本文档说明仓库 [`backend/cmd/`](../../backend/cmd/) 下的命令入口、子目录、源码文件和常用操作。内容按当前源码整理；执行前请先阅读对应命令的安全注意事项。

线上 Docker 操作说明（包括 Compose 项目选择、容器内联通测试和一次性工具容器）见[线上 Docker 运维](./online-docker.md)。

## 命令目录

| 目录 | 用途 | 需要数据库 | 主要风险/注意事项 |
| --- | --- | --- | --- |
| [`server/`](./server.md) | 启动 Sub2API HTTP 服务、首次安装与版本信息 | 正常服务需要 PostgreSQL、Redis | 首次安装和迁移会写数据库及配置 |
| [`jwtgen/`](./jwtgen.md) | 为指定用户或首个活动管理员签发 JWT | PostgreSQL | 输出的 JWT 是敏感凭证；指定邮箱时不会校验管理员身份 |
| [`profit-preview/`](./profit-preview.md) | 根据只读 JSON 离线预演利润控制准入 | 否 | 输入中不应包含账号凭据等敏感信息 |
| [`cleanup-ingress-reject-logs/`](./cleanup-ingress-reject-logs.md) | 清理历史 ingress/auth 拒绝日志 | PostgreSQL | 默认 dry-run；`--execute` 会删除日志 |

## 从哪里执行

这些 Go 命令属于 `backend` Go module。通常先进入后端目录：

```bash
cd backend
go run ./cmd/server --version
```

也可以从仓库根目录使用 `go -C`（需要支持此选项的 Go 版本）：

```bash
go -C backend run ./cmd/server --version
```

运行时需要有 Go 工具链和项目依赖。生产 Docker 镜像主要打包服务二进制，不是完整 Go 开发环境；`jwtgen`、`profit-preview` 和 `cleanup-ingress-reject-logs` 需要从源码运行，或单独编译后再执行。

## 构建、生成和测试

在 `backend/` 目录：

```bash
# 构建服务二进制
make build

# 重新生成 Ent / Wire 代码
make generate

# 运行后端测试
make test

# 运行 cmd 下所有命令包的测试
go test ./cmd/...
```

版本号解析规则由 [`backend/scripts/resolve-version.sh`](../../backend/scripts/resolve-version.sh) 实现：若当前 Git checkout 恰好位于符合规则的版本 tag，优先使用 tag；否则读取 `cmd/server/VERSION`。服务的 `--version` 还会显示构建提交和构建时间。

## 配置与数据目录

除 `profit-preview` 外，多个命令使用 `internal/config.LoadForBootstrap()` 加载应用配置。配置来源及默认值以 [`backend/internal/config/`](../../backend/internal/config/) 为准，主要包括配置 YAML、环境变量和 `DATA_DIR`。

首次安装相关文件通常位于数据目录：

- `config.yaml`：安装后服务配置。
- `.installed`：安装完成锁文件，避免意外重新进入安装流程。
- Docker 下通常使用 `/app/data`；可通过 `DATA_DIR` 指定其他位置。

不要把真实数据库密码、管理员密码、JWT 或含有账号凭据的导出文件提交到仓库。
