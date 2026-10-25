# deploy2 本地 Docker 管理

`manage.sh` 是面向本地开发与排障的 Docker Compose 管理脚本。同步配置后默认使用本目录的
`docker-compose.dev.yml`；未同步时回退到 [`deploy/docker-compose.dev.yml`](../deploy/docker-compose.dev.yml)。
脚本从当前仓库源码构建应用，并启动应用、PostgreSQL 和 Redis。数据仍保存在
`deploy/data`、`deploy/postgres_data` 和 `deploy/redis_data`，普通重启、重建和 `down` 都不会删除数据。

## 首次启动

```bash
./deploy2/manage.sh sync-config
./deploy2/manage.sh init-env   # deploy2/.env 尚不存在时才需要
./deploy2/manage.sh start
```

`sync-config` 会把 `deploy/docker-compose*.yml` 和 `.env.example` 同步到 `deploy2`。
如果 `deploy/.env` 存在，则仅在 `deploy2/.env` 不存在时复制，并设置权限为 `600`；
已存在的目标环境文件默认不会覆盖。`sync-config --force` 会更新同步的配置，并覆盖目标 `.env`。
环境文件含有密钥，已被 `.gitignore` 忽略，切勿提交或分享。

`init-env` 基于可用的 `.env.example` 创建权限为 `600` 的环境文件，并生成 PostgreSQL、JWT 和 TOTP 密钥；
已有 `.env` 时会拒绝覆盖。启动前会读取 `backend/scripts/resolve-version.sh` 确定后端版本，
并将该版本作为 Docker 构建参数；随后构建应用镜像、启动三个服务、等待健康检查，再验证
PostgreSQL SQL 查询、Redis PING/认证及外网 HTTPS。外网检查默认访问 GitHub；
若环境需走代理或外网不可用，可设置 `NETWORK_TEST_URL` 为可访问的 HTTPS 地址。

`sync-config` 会把 Dockerfile 副本也放入 `deploy2/`，开发 Compose 只引用此副本；
Dockerfile 和 Compose 的改动都可留在本目录。Compose 仍以仓库根目录作为项目路径，
因此构建上下文和数据绑定挂载仍指向现有的项目源代码与 `deploy/` 数据目录。

`backend/cmd` 下 Go 命令的目录说明、参数、配置要求和安全注意事项见
[`docs/README.md`](./docs/README.md)。
生产 Docker 环境不要直接套用本地默认 Compose/project；对应的线上服务检查、依赖联通和一次性运维容器操作见
[`docs/online-docker.md`](./docs/online-docker.md)。

## 命令

```text
init-env               创建本地环境配置和随机密钥
sync-config [--force]  同步 Compose YAML 和 env 文件到 deploy2
check                  检查 deploy2 Compose/Dockerfile 副本与原文件差异
start                  构建并启动全栈，等健康检查并执行连通性诊断
build [SERVICE...]     构建 Compose 镜像，并显示后端版本
build-app              只构建应用镜像，并显示后端版本
rebuild                无缓存重建应用，再强制重建应用容器
restart                重启服务
force-restart          不重新编译，强制重建容器
stop                   停止服务但保留容器和数据
down                   删除容器和网络，但保留数据
status                 查看服务状态、健康状态和资源占用
logs [SERVICE]         查看并持续跟踪日志
pull [SERVICE...]      拉取 Compose 服务镜像
validate               只校验 Compose 配置，不启动服务
doctor                 检查 Docker、Compose、容器健康和服务连通性
connectivity           单独执行 PostgreSQL、Redis、外网检查
check-mirror           检查应用构建与运行时镜像的 Registry manifest
--mirror-list          列出可选镜像源和使用方法
backup-db [FILE]       导出 PostgreSQL 自定义格式备份（文件权限 600）
build-image [TAG]      用仓库 Dockerfile 独立构建镜像，默认 sub2api:local
export-image [TAG] [FILE]
                       导出本地镜像为 Docker tar 归档
version                显示当前检测到的后端版本
exec SERVICE [CMD...]  在服务容器执行命令；未给命令时进入 sh
```

示例：

```bash
./deploy2/manage.sh --force-build start
./deploy2/manage.sh start --pull
./deploy2/manage.sh --wait-timeout 300 start
./deploy2/manage.sh status
./deploy2/manage.sh logs sub2api
./deploy2/manage.sh doctor
./deploy2/manage.sh backup-db ./backups/sub2api.dump
./deploy2/manage.sh exec sub2api sh
./deploy2/manage.sh build-image --force-build sub2api:debug
./deploy2/manage.sh export-image sub2api:debug ./sub2api-debug.tar
```

## 参数与环境变量

`--force-build` 等价于对应用镜像禁用构建缓存；用于 `start` 时会强制重建应用容器。
`--no-cache` 禁用缓存；`--pull` 在构建前拉取基础镜像；`--force-recreate` 强制重建应用容器。
`--proxy URL` 为构建阶段的包管理器和下载命令设置 HTTP(S) 代理（例如
`./deploy2/manage.sh --proxy http://127.0.0.1:10808 start`，也可用 `--proxy "$HTTPS_PROXY"`），代理地址不会打印到日志。
在 macOS 上，脚本会自动将 `127.0.0.1`/`localhost` 改为容器可访问的 `host.docker.internal`。
此选项**不设置 Docker daemon 的 Registry 代理**：拉取 `FROM` 基础镜像时，Docker Desktop daemon 自己访问 Registry，
不会使用这个构建参数。如果错误发生在解析/拉取 `FROM` 阶段，请在 Docker Desktop 的 Settings → Resources → Proxies
配置与宿主机相同的代理，然后重启 Docker Desktop。Dockerfile 不再指定需要额外从 Docker Hub 拉取的语法前端，
减少构建启动时的一次外部镜像解析。

### Registry 镜像源

如果 Docker Hub 仍超时，但替代 Registry 可用，可指定镜像前缀。官方镜像仓库的短名称会自动补上
`/library/`，同时用于 Dockerfile 的 Node/Go/Alpine/PostgreSQL 构建镜像，以及 Compose 中运行时的 PostgreSQL/Redis：

```bash
./deploy2/manage.sh --mirror-list
./deploy2/manage.sh --mirror mirror.gcr.io check-mirror
./deploy2/manage.sh --mirror mirror.gcr.io start
./deploy2/manage.sh check
```

`check` 也可写作 `--check`，例如 `./deploy2/manage.sh --check`。它不需要 Docker；
逐一比较 `deploy2/docker-compose*.yml` 与 `deploy/` 中的原文件，以及 `deploy2/Dockerfile`
与根目录 `Dockerfile`。diff 会忽略同步脚本有意做的转换：开发 Compose 指向 `deploy2/Dockerfile`
并支持镜像前缀，Dockerfile 副本不包含远程 syntax 前端声明。未同步差异会显示统一 diff 并以非零状态退出；
缺失或多出的 Compose 副本也会报告。检查失败后运行 `./deploy2/manage.sh sync-config` 更新副本。

`check-mirror` 只检查镜像 manifest，不下载完整镜像层。也可用 `IMAGE_MIRROR=mirror.gcr.io` 设置默认镜像源。
镜像源必须是可信且 TLS 证书有效的 Registry；不要关闭 TLS 验证。
`--mirror-list` 会列出 Docker Hub 镜像源及其仓库前缀。镜像可用性会因网络和标签变化，
启动前可用 `check-mirror` 检查本项目需要的 Node、Go、Alpine、PostgreSQL 和 Redis manifest。

本机 HTTP 代理加镜像源的组合用法：

```bash
./deploy2/manage.sh start --mirror mirror.gcr.io --proxy http://127.0.0.1:10808
```

脚本只将回环地址在 macOS Docker 构建容器中改成 `host.docker.internal`；Registry 镜像拉取直接走镜像源，不依赖代理转发。
`--wait-timeout N` 设置健康检查等待秒数，`--tail N` 设置日志初始行数。
构建和等待选项可以放在命令前或命令后。同步命令的 `--force` 只用于覆盖 `deploy2/.env`。

可通过 `-f/--file`、`-e/--env-file`、`-p/--project` 覆盖 Compose 文件、环境文件和项目名称：

```bash
./deploy2/manage.sh --file deploy/docker-compose.yml --env-file deploy/.env status
```

也支持 `SUB2API_COMPOSE_FILE`、`ENV_FILE`、`COMPOSE_PROJECT_NAME`、`HEALTH_TIMEOUT`、
`NETWORK_TEST_URL`、`IMAGE_TAG`、`TAIL_LINES`、`GOPROXY`、`GOSUMDB` 和 `NPM_CONFIG_REGISTRY`。
需要 Docker Engine、Docker Compose v2 和 Bash。`rebuild` 只无缓存构建应用服务，
不会重建 PostgreSQL/Redis 镜像；脚本不提供 `down -v` 等删除持久化数据的快捷操作。
