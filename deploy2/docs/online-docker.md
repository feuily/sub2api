# 线上 Docker 环境运维

本文说明如何在已运行的**生产 Docker Compose** 环境中查看服务、检查连接，以及运行 `backend/cmd` 下的运维工具。生产命令应在部署服务器上执行，并使用该实例真实的 Compose 文件、环境文件和 Compose project name。

> [`deploy2/manage.sh`](../manage.sh) 默认面向本地开发环境：默认 Compose 是 `deploy2/docker-compose.dev.yml`，默认 project 是 `sub2api-local`，并会从当前源码构建镜像。不要不加参数地在生产机运行它，否则可能操作另一套开发栈或数据。生产环境优先使用部署时原有的 `docker compose` 命令和配置。

## 1. 先确认目标项目

以下示例以仓库的 `deploy/docker-compose.yml` 为例。若生产环境使用不同路径、`.env` 位置或 project name，请替换为部署时实际值。Compose 文件、`--env-file` 和 `-p` 要在每次命令中保持一致：

```bash
cd /path/to/sub2api
COMPOSE_FILE=deploy/docker-compose.yml
ENV_FILE=deploy/.env
PROJECT=production-project

docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" ps
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" logs --tail=200 sub2api
```

检查 `ps` 返回的服务、镜像和 project name 确实是目标生产实例后再继续。不要把 `.env` 内容发到终端记录、工单或聊天中。

## 2. 服务状态、日志、健康检查和重启

生产 Compose 中的服务名是 `sub2api`、`postgres`、`redis`；应用容器默认名为 `sub2api`。Compose project name 仍以部署实际值为准。

```bash
# 观察容器状态
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" ps

# 查看应用日志
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" logs --tail=200 sub2api

# 查看全部服务最近日志
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" logs --tail=100

# 从容器内部检查应用健康端点
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" exec -T sub2api \
  wget -q -T 5 -O /dev/null http://127.0.0.1:8080/health

# 仅重启正在运行的应用容器，不拉镜像、不重建容器
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" restart sub2api
```

若更改了 Compose environment、挂载或其他容器定义，`restart` 不会重新创建容器以加载新定义。审查配置变更后使用：

```bash
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" up -d --no-deps sub2api
```

生产更新镜像前，先确认版本/tag、发布流程和回滚镜像；不要在排障时直接使用 `latest` 覆盖运行版本。数据库和 Redis 不要因为只需重启应用而一并 `down`。

## 3. 在容器内检查依赖联通

Compose 网络中的服务名可用作内部主机名。应用运行镜像包含 `psql` 和 `wget`，但不包含 Redis CLI；PostgreSQL 查询和外网测试可从应用容器执行：

```bash
# PostgreSQL：执行只读 SELECT 1
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" exec -T sub2api \
  sh -ec 'PGPASSWORD="$DATABASE_PASSWORD" psql -h "$DATABASE_HOST" -p "$DATABASE_PORT" -U "$DATABASE_USER" -d "$DATABASE_DBNAME" -Atqc "SELECT 1"'

# Redis：redis 容器自带 redis-cli；Compose 已设置 REDISCLI_AUTH，不把密码放到命令行参数
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" exec -T redis \
  redis-cli -h redis -p 6379 ping

# 从应用容器测试出站 HTTPS；替换为生产网络策略允许访问的地址
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" exec -T sub2api \
  wget -S -T 10 -O /dev/null https://github.com
```

Redis 命令从 Redis 服务容器通过 Compose 网络中的 `redis` 服务名连接并验证认证；它确认 Redis 监听和凭据正常，但不是从应用进程本身发起的连接测试。出站访问失败也可能是 DNS、代理或防火墙策略，并不等于 PostgreSQL/Redis 故障。排查时可查看 `docker compose logs sub2api postgres redis`，再对照 `ps` 中的 health 状态；不要打印完整环境变量或执行会回显凭据的命令。

## 4. `server` 命令在生产容器中的使用

发布镜像内的服务程序位于 `/app/sub2api`，可以只读查看版本：

```bash
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" exec -T sub2api \
  /app/sub2api --version
```

线上服务启停由 Compose 管理，不要在已有生产容器里另启动第二个 server 进程。除首次部署流程外，不要对已有数据运行 `--setup`；安装向导不是修改现有生产数据库配置的通用命令。

## 5. 运行 JWT 签发和日志清理工具

官方运行镜像默认只包含服务入口 `/app/sub2api`，并不包含 Go toolchain，也不包含 `jwtgen` 或 `cleanup-ingress-reject-logs`。不要假设可以在应用容器里直接 `go run`。推荐做法是：

1. 在可信构建环境用**与生产应用完全相同的源码版本**编译 Linux 目标二进制。
2. 在生产服务器审查二进制来源、校验版本/校验和，并设置仅 root 可读的临时目录权限。
3. 用同一生产 Compose 文件、env 文件和 project name，通过一次性 `docker compose run --rm --no-deps` 容器挂载只读二进制。Compose 会让这个工具容器复用应用服务的网络、环境和 `/app/data` 配置卷；工具执行完后容器自动移除。
4. 操作后安全删除主机上的临时二进制。不要挂载源码目录、Docker socket 或整个宿主机目录。

在构建环境（目标架构必须与生产容器匹配）：

```bash
cd /path/to/exact-production-source/backend
mkdir -p ./bin

# 例：Linux amd64；Linux arm64 目标改为 GOARCH=arm64
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ./bin/jwtgen ./cmd/jwtgen
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ./bin/cleanup-ingress-reject-logs ./cmd/cleanup-ingress-reject-logs
```

将生成的两个二进制安全传到生产仓库目录下的 `backend/bin/`，确保它们由可信来源构建，并避免被 Web 服务访问。

签发 JWT 的一次性运行示例：

```bash
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" run --rm --no-deps \
  -v "$PWD/backend/bin/jwtgen:/tmp/jwtgen:ro" \
  --entrypoint /tmp/jwtgen sub2api \
  --email admin@example.com
```

它会输出 JWT 明文。应在受控终端运行，避免录屏、shell 日志和 CI 日志；只授权给确认过身份的目标用户。工具初始化数据库时可能自动应用待执行迁移，执行前应检查生产版本与 schema 兼容性。

清理工具先 dry-run：

```bash
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" run --rm --no-deps \
  -v "$PWD/backend/bin/cleanup-ingress-reject-logs:/tmp/cleanup:ro" \
  --entrypoint /tmp/cleanup sub2api \
  --before 2026-10-25T00:00:00Z
```

检查 cutoff 和匹配数量后，如确需删除，再明确追加 `--execute`：

```bash
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" run --rm --no-deps \
  -v "$PWD/backend/bin/cleanup-ingress-reject-logs:/tmp/cleanup:ro" \
  --entrypoint /tmp/cleanup sub2api \
  --before 2026-10-25T00:00:00Z --execute
```

这是生产数据删除操作：执行前必须验证目标项目和数据库、完成数据库备份、确认所有应用实例已升级，并审核 dry-run 输出。`InitEnt` 可能先应用数据库迁移；若迁移状态或并发安全不明确，应停止操作并按发布/数据库变更流程处理。命令不会替你执行额外的清理 SQL。

## 6. `profit-preview` 在生产环境的用法

`profit-preview` 是离线工具，不连接生产数据库。推荐在受控运维机或发布流水线之外的可信工作站运行，只使用审查过的最小化只读 JSON 导出：

```bash
cd /path/to/exact-production-source/backend
go run ./cmd/profit-preview --input /secure/path/profit-preview-input.json --json
```

不要为了运行它而把账号 token、密码、OAuth 凭据或生产 `.env` 拷贝到开发机或挂入生产容器。输出会包含账号名称/ID、准入结论等运营信息，应按内部数据安全要求保存。输入字段和计算限制见 [`profit-preview.md`](./profit-preview.md)。

## 7. 备份和回滚底线

- 任何会更改生产数据的维护工具都要先做并验证数据库备份；清理工具必须先 dry-run。可使用数据库容器中的 `pg_dump`，并在宿主机创建仅当前用户可读的备份文件：

  ```bash
  umask 077
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" -p "$PROJECT" exec -T postgres \
    sh -ec 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
    > "/secure/backup/sub2api-$(date +%Y%m%d-%H%M%S).dump"
  ```

  备份目录必须预先存在且访问受控；确认命令退出码为 0 和文件非空，并按组织恢复演练/校验流程确认备份可用。不要将转储留在仓库目录。
- `docker compose down -v` 会删除命名卷，可能造成数据库、Redis 和应用数据丢失；不要用于日常重启或排障。
- 不要将生产 `.env`、JWT 输出、数据库转储或预演输入提交到仓库。
- 运行后验证应用 health、数据库和 Redis 健康状态，并检查服务日志；记录所用镜像 digest/tag、源码 commit 和运维结果。
