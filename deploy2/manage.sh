#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    DEFAULT_ENV_FILE="${SCRIPT_DIR}/.env"
elif [[ -f "${DEPLOY_DIR}/.env" ]]; then
    DEFAULT_ENV_FILE="${DEPLOY_DIR}/.env"
else
    DEFAULT_ENV_FILE="${SCRIPT_DIR}/.env"
fi
if [[ -f "${SCRIPT_DIR}/docker-compose.dev.yml" ]]; then
    DEFAULT_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.dev.yml"
else
    DEFAULT_COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.dev.yml"
fi
ENV_FILE="${ENV_FILE:-${DEFAULT_ENV_FILE}}"
COMPOSE_FILE="${SUB2API_COMPOSE_FILE:-${COMPOSE_FILE:-${DEFAULT_COMPOSE_FILE}}}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-sub2api-local}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
NETWORK_TEST_URL="${NETWORK_TEST_URL:-https://github.com}"
IMAGE_TAG="${IMAGE_TAG:-sub2api:local}"
TAIL_LINES="${TAIL_LINES:-200}"
PROXY_URL="${PROXY_URL:-}"
REGISTRY_PREFIX=""
FORCE_BUILD=false
NO_CACHE=false
PULL_IMAGES=false
FORCE_RECREATE=false
FORCE_SYNC=false
WAIT_TIMEOUT_SET=false
TAIL_SET=false
PROXY_SET=false
MIRROR_SET=false
BUILD_PROXY_ARGS=()

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
RESET=$'\033[0m'

info() { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"; }
success() { printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; }
error() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; }
die() { error "$*"; exit 1; }

usage() {
    cat <<'EOF'
Sub2API local Docker manager

Usage:
  ./deploy2/manage.sh [options] <command> [arguments]

Options:
  -f, --file PATH       Compose file (default: deploy/docker-compose.dev.yml)
  -e, --env-file PATH   Environment file (default: deploy/.env)
  -p, --project NAME    Compose project name (default: sub2api-local)
      --mirror-list     List registry mirror choices and routing format
      --check           Check deploy2 Compose/Dockerfile copies against originals
      --force-build     Rebuild app image without cache
      --no-cache        Disable build cache
      --pull            Pull newer base/service images before building
      --proxy URL       Use an HTTP(S) proxy for image build steps
      --mirror PREFIX   Use a Registry mirror for all Docker Hub base images
      --force-recreate  Recreate containers after start/build
      --wait-timeout N  Health-check wait timeout in seconds
      --tail N          Number of log lines to show
  -h, --help            Show this help

Commands:
  init-env              Create .env from the example with fresh secrets
  sync-config [--force] Copy Compose YAMLs and environment files into deploy2
  check                 Show differences between deploy2 copies and originals
  start                 Build the app and start all services; wait for health
  build                 Build all images configured in the Compose file
  build-app             Build only the application image
  rebuild               Rebuild the application without cache and recreate it
  restart               Restart running services
  force-restart         Recreate services without rebuilding images
  stop                  Stop services without removing containers or data
  down                  Remove containers and network; keep persistent data
  status                Show container state, health, and resource usage
  logs [SERVICE]        Follow logs (default: all services)
  pull [SERVICE]        Pull service images defined by Compose
  validate              Validate Compose configuration without starting it
  doctor                Inspect Docker, Compose, health, and recent failures
  connectivity          Test PostgreSQL, Redis, and outbound HTTPS from app
  check-mirror          Check mirror manifests for app and runtime images
  backup-db [FILE]      Export PostgreSQL database as a custom-format dump
  build-image [TAG]     Build a standalone image from the repository Dockerfile
  export-image [TAG] [FILE]
                        Export an image as a Docker archive
  version               Show the detected backend build version
  exec SERVICE [CMD...] Run a command in a service (default command: sh)

Environment:
  SUB2API_COMPOSE_FILE  Override the Compose file
  ENV_FILE              Override the environment file
  COMPOSE_PROJECT_NAME  Override the Compose project name
  HEALTH_TIMEOUT        Startup health timeout in seconds (default: 180)
  NETWORK_TEST_URL      Outbound test URL (default: https://github.com)
  IMAGE_TAG             Default tag for build-image/export-image (default: sub2api:local)
  PROXY_URL             Optional HTTP(S) proxy for image build steps
  IMAGE_MIRROR          Optional registry prefix, e.g. dockerproxy.net/library
  GOPROXY, GOSUMDB, NPM_CONFIG_REGISTRY
EOF
}

expected_deploy2_copy() {
    local source="$1"
    case "$(basename "$source")" in
        Dockerfile)
            sed '/^# syntax=docker\/dockerfile:1\.7$/d' "$source"
            ;;
        docker-compose.dev.yml)
            sed \
                -e 's#dockerfile: Dockerfile#dockerfile: deploy2/Dockerfile#' \
                -e 's#image: postgres:18-alpine#image: ${SUB2API_REGISTRY_PREFIX:-}postgres:18-alpine#' \
                -e 's#image: redis:8-alpine#image: ${SUB2API_REGISTRY_PREFIX:-}redis:8-alpine#' \
                "$source"
            ;;
        *)
            cat "$source"
            ;;
    esac
}

check_copy_diff() {
    local source="$1"
    local copy="$2"
    local label="$3"
    local diff_status
    if [[ ! -f "$source" ]]; then
        error "原文件不存在：$source"
        return 1
    fi
    if [[ ! -f "$copy" ]]; then
        error "deploy2 副本不存在：$copy（请运行 sync-config）"
        return 1
    fi
    if diff -u --label "$label (expected)" --label "$label (deploy2)" \
        <(expected_deploy2_copy "$source") "$copy"; then
        success "${label}：一致"
        return 0
    else
        diff_status=$?
    fi
    if (( diff_status > 1 )); then
        error "${label}：比较失败"
    else
        warn "${label}：存在未同步差异"
    fi
    return 1
}

check_deploy2_copies() {
    local source copy name failed=0
    for source in "$DEPLOY_DIR"/docker-compose*.yml; do
        [[ -f "$source" ]] || continue
        name="$(basename "$source")"
        copy="${SCRIPT_DIR}/${name}"
        if ! check_copy_diff "$source" "$copy" "$name"; then
            failed=1
        fi
    done

    for copy in "$SCRIPT_DIR"/docker-compose*.yml; do
        [[ -f "$copy" ]] || continue
        name="$(basename "$copy")"
        if [[ ! -f "${DEPLOY_DIR}/${name}" ]]; then
            error "deploy2 存在没有对应原文件的 Compose 文件：$copy"
            failed=1
        fi
    done

    if ! check_copy_diff "${REPO_ROOT}/Dockerfile" "${SCRIPT_DIR}/Dockerfile" "Dockerfile"; then
        failed=1
    fi

    if (( failed != 0 )); then
        error "检测到差异或缺失文件；如需重新同步，请运行 ./deploy2/manage.sh sync-config"
        return 1
    fi
    success "deploy2 Compose 文件和 Dockerfile 副本均与原文件同步。"
}

mirror_list() {
    cat <<'EOF'
Registry mirror options (availability and policy depend on your network):

  mirror.gcr.io
    Google Docker Hub pull-through cache. Recommended first alternative;
    it may not cache every tag.
    Prefix: mirror.gcr.io/library/

  docker.m.daocloud.io
    DaoCloud Docker Hub mirror.
    Prefix: docker.m.daocloud.io/library/

  public.ecr.aws/docker
    Amazon ECR Public Docker Hub library namespace.
    Prefix: public.ecr.aws/docker/library/

  dockerproxy.net
    Docker Hub proxy mirror. It can be transiently busy; retry or use another.
    Prefix: dockerproxy.net/library/

All five required manifests (node, golang, alpine, postgres, redis) were
checked on these endpoints on 2026-10-25. Availability can change.
Check a source before building:
  ./deploy2/manage.sh --mirror mirror.gcr.io check-mirror
  ./deploy2/manage.sh --mirror docker.m.daocloud.io check-mirror
  ./deploy2/manage.sh --mirror public.ecr.aws/docker check-mirror
  ./deploy2/manage.sh --mirror dockerproxy.net check-mirror

Build and start:
  ./deploy2/manage.sh --mirror mirror.gcr.io start

Use trusted mirrors only; registry credentials and image integrity are
handled by Docker's normal TLS and signature/digest mechanisms.
EOF
}

compose() {
    SUB2API_REGISTRY_PREFIX="$REGISTRY_PREFIX" docker compose \
        --project-directory "$DEPLOY_DIR" \
        --env-file "$ENV_FILE" \
        --project-name "$PROJECT_NAME" \
        --file "$COMPOSE_FILE" "$@"
}

check_docker() {
    command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 Docker Desktop 或 Docker Engine。"
    docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2（docker compose）。"
    docker info >/dev/null 2>&1 || die "无法连接 Docker daemon；请确认 Docker 正在运行且当前用户有权限。"
}

check_docker_cli() {
    command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 Docker Desktop 或 Docker Engine。"
    docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2（docker compose）。"
}

check_env() {
    [[ -f "$ENV_FILE" ]] || die "环境文件不存在：$ENV_FILE。先运行 ./deploy2/manage.sh init-env"
    [[ -r "$ENV_FILE" ]] || die "环境文件不可读：$ENV_FILE"
    grep -q '^POSTGRES_PASSWORD=.' "$ENV_FILE" || die "POSTGRES_PASSWORD 为空，请编辑 $ENV_FILE"
    if grep -q '^POSTGRES_PASSWORD=change_this_secure_password$' "$ENV_FILE"; then
        die "请先将 $ENV_FILE 中的示例 PostgreSQL 密码替换为强密码"
    fi
}

check_compose_file() {
    [[ -f "$COMPOSE_FILE" ]] || die "Compose 文件不存在：$COMPOSE_FILE"
}

prepare() {
    check_docker
    check_env
    check_compose_file
}

prepare_config() {
    check_docker_cli
    check_env
    check_compose_file
}

compose_config() {
    compose config --quiet || die "Compose 配置无效，请检查 $ENV_FILE 和 $COMPOSE_FILE"
}

init_env() {
    [[ -f "$ENV_FILE" ]] && die "环境文件已存在，不会覆盖：$ENV_FILE"
    local env_template="${SCRIPT_DIR}/.env.example"
    [[ -f "$env_template" ]] || env_template="${DEPLOY_DIR}/.env.example"
    [[ -f "$env_template" ]] || die "找不到环境模板：${DEPLOY_DIR}/.env.example"
    command -v openssl >/dev/null 2>&1 || die "init-env 需要 openssl 来生成密钥"

    umask 077
    mkdir -p "$(dirname "$ENV_FILE")"
    cp "$env_template" "$ENV_FILE"
    local postgres_password jwt_secret totp_key
    postgres_password="$(openssl rand -hex 32)"
    jwt_secret="$(openssl rand -hex 32)"
    totp_key="$(openssl rand -hex 32)"

    sed -i.bak \
        -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${postgres_password}/" \
        -e "s/^JWT_SECRET=.*/JWT_SECRET=${jwt_secret}/" \
        -e "s/^TOTP_ENCRYPTION_KEY=.*/TOTP_ENCRYPTION_KEY=${totp_key}/" \
        "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
    chmod 600 "$ENV_FILE"
    mkdir -p "${DEPLOY_DIR}/data" "${DEPLOY_DIR}/postgres_data" "${DEPLOY_DIR}/redis_data"
    success "已创建 $ENV_FILE（权限 600），随机密钥不会显示在终端。"
    info "可按需编辑配置，然后运行 ./deploy2/manage.sh start"
}

sync_config() {
    local source destination temporary
    check_force_sync_args "$@"
    mkdir -p "$SCRIPT_DIR"
    for source in "$DEPLOY_DIR"/docker-compose*.yml; do
        [[ -f "$source" ]] || continue
        destination="${SCRIPT_DIR}/$(basename "$source")"
        if [[ "$(basename "$source")" == "docker-compose.dev.yml" ]]; then
            temporary="${destination}.tmp.$$"
            sed \
                -e 's#dockerfile: Dockerfile#dockerfile: deploy2/Dockerfile#' \
                -e 's#image: postgres:18-alpine#image: ${SUB2API_REGISTRY_PREFIX:-}postgres:18-alpine#' \
                -e 's#image: redis:8-alpine#image: ${SUB2API_REGISTRY_PREFIX:-}redis:8-alpine#' \
                "$source" > "$temporary"
            mv "$temporary" "$destination"
        else
            cp "$source" "$destination"
        fi
        info "已同步 $(basename "$source")"
    done

    grep -v '^# syntax=docker/dockerfile:1\.7$' "${REPO_ROOT}/Dockerfile" > "${SCRIPT_DIR}/Dockerfile"
    chmod 644 "${SCRIPT_DIR}/Dockerfile"
    info "已同步 Dockerfile 副本（使用本地 BuildKit 前端，不额外拉取 syntax 镜像）"

    cp "${DEPLOY_DIR}/.env.example" "${SCRIPT_DIR}/.env.example"
    chmod 644 "${SCRIPT_DIR}/.env.example"
    info "已同步 .env.example"

    if [[ -f "${DEPLOY_DIR}/.env" ]]; then
        destination="${SCRIPT_DIR}/.env"
        if [[ -e "$destination" && "$FORCE_SYNC" != true ]]; then
            warn "保留已存在的 ${SCRIPT_DIR}/.env；如确认覆盖请使用 sync-config --force"
        else
            (umask 077; cp "${DEPLOY_DIR}/.env" "$destination")
            chmod 600 "$destination"
            info "已复制真实环境文件（权限 600；文件内容不会显示）"
        fi
    else
        warn "deploy/.env 不存在，只同步了 .env.example；可运行 init-env 生成本地环境文件"
    fi
    success "配置文件已同步到 ${SCRIPT_DIR}"
}

check_force_sync_args() {
    (($# == 0)) || die "sync-config 只支持 --force 选项"
}

check_command_options() {
    local command="$1"
    case "$command" in
        start)
            [[ "$TAIL_SET" == false ]] || die "--tail 不适用于 start"
            ;;
        build|build-app|rebuild|restart|force-restart|build-image|pull)
            [[ "$FORCE_RECREATE" == false ]] || die "--force-recreate 不适用于 $command"
            [[ "$WAIT_TIMEOUT_SET" == false ]] || die "--wait-timeout 不适用于 $command"
            [[ "$TAIL_SET" == false ]] || die "--tail 不适用于 $command"
            ;;
        logs)
            [[ "$FORCE_BUILD" == false && "$NO_CACHE" == false && "$PULL_IMAGES" == false && "$FORCE_RECREATE" == false ]] ||
                die "构建和重建选项不适用于 logs"
            [[ "$WAIT_TIMEOUT_SET" == false ]] || die "--wait-timeout 不适用于 logs"
            ;;
        sync-config)
            [[ "$FORCE_BUILD" == false && "$NO_CACHE" == false && "$PULL_IMAGES" == false && "$FORCE_RECREATE" == false ]] ||
                die "构建和重建选项不适用于 sync-config"
            [[ "$WAIT_TIMEOUT_SET" == false && "$TAIL_SET" == false ]] ||
                die "等待和日志选项不适用于 sync-config"
            ;;
        *)
            [[ "$FORCE_BUILD" == false && "$NO_CACHE" == false && "$PULL_IMAGES" == false && "$FORCE_RECREATE" == false ]] ||
                die "构建和重建选项不适用于 $command"
            [[ "$WAIT_TIMEOUT_SET" == false && "$TAIL_SET" == false ]] ||
                die "等待和日志选项不适用于 $command"
            ;;
    esac
}

backend_version() {
    local version
    version="$("${REPO_ROOT}/backend/scripts/resolve-version.sh")" ||
        die "无法检测 backend 版本（backend/scripts/resolve-version.sh 执行失败）"
    [[ -n "$version" ]] || die "backend 版本为空"
    printf '%s\n' "$version"
}

build_compose_services() {
    local version
    local -a build_args
    version="$(backend_version)"
    info "检测到 backend 版本：${version}"
    build_args=(build --build-arg "VERSION=${version}")
    [[ "$NO_CACHE" == true ]] && build_args+=(--no-cache)
    [[ "$PULL_IMAGES" == true ]] && build_args+=(--pull)
    if [[ "$MIRROR_SET" == true ]]; then
        build_args+=(
            --build-arg "NODE_IMAGE=${REGISTRY_PREFIX}node:24-alpine"
            --build-arg "GOLANG_IMAGE=${REGISTRY_PREFIX}golang:1.27.3-alpine"
            --build-arg "ALPINE_IMAGE=${REGISTRY_PREFIX}alpine:3.21"
            --build-arg "POSTGRES_IMAGE=${REGISTRY_PREFIX}postgres:18-alpine"
        )
    fi
    if [[ "$PROXY_SET" == true ]]; then
        build_args+=("${BUILD_PROXY_ARGS[@]}")
    fi
    compose "${build_args[@]}" "$@"
}

configure_build_proxy() {
    [[ -n "$PROXY_URL" ]] || return 0
    [[ "$PROXY_URL" == http://* || "$PROXY_URL" == https://* ]] ||
        die "--proxy 只支持 http:// 或 https:// 代理地址"
    if [[ "$(uname -s)" == Darwin ]]; then
        local original_proxy="$PROXY_URL"
        PROXY_URL="${PROXY_URL/http:\/\/127.0.0.1/http:\/\/host.docker.internal}"
        PROXY_URL="${PROXY_URL/http:\/\/localhost/http:\/\/host.docker.internal}"
        PROXY_URL="${PROXY_URL/https:\/\/127.0.0.1/https:\/\/host.docker.internal}"
        PROXY_URL="${PROXY_URL/https:\/\/localhost/https:\/\/host.docker.internal}"
        if [[ "$PROXY_URL" != "$original_proxy" ]]; then
            info "已将本机回环代理地址转换为容器可访问的 host.docker.internal 地址"
        fi
    fi
    export HTTP_PROXY="$PROXY_URL"
    export HTTPS_PROXY="$PROXY_URL"
    export http_proxy="$PROXY_URL"
    export https_proxy="$PROXY_URL"
    BUILD_PROXY_ARGS=(
        --build-arg HTTP_PROXY
        --build-arg HTTPS_PROXY
        --build-arg http_proxy
        --build-arg https_proxy
    )
    if [[ -n "${NO_PROXY:-}" ]]; then
        BUILD_PROXY_ARGS+=(--build-arg NO_PROXY)
    fi
    if [[ -n "${no_proxy:-}" ]]; then
        BUILD_PROXY_ARGS+=(--build-arg no_proxy)
    fi
    info "已为 Docker 构建配置 HTTP(S) 代理（代理地址不回显）"
    if [[ "$MIRROR_SET" != true ]]; then
        warn "此代理仅用于 Dockerfile 构建步骤；拉取 FROM 镜像仍由 Docker daemon 访问 Registry。"
    fi
}

configure_registry_mirror() {
    [[ "$REGISTRY_PREFIX" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._-]+)*$ ]] ||
        die "--mirror 需要不带 scheme 的 Registry 前缀，例如 dockerproxy.net 或 mirror.example.com/docker"
    REGISTRY_PREFIX="${REGISTRY_PREFIX%/}"
    if [[ "$REGISTRY_PREFIX" != */* ]]; then
        REGISTRY_PREFIX+="/library"
    fi
    REGISTRY_PREFIX+="/"
    export SUB2API_REGISTRY_PREFIX="$REGISTRY_PREFIX"
    MIRROR_SET=true
    info "基础镜像 Registry 前缀：${REGISTRY_PREFIX}"
}

check_mirror() {
    check_docker
    [[ "$MIRROR_SET" == true ]] || die "check-mirror 需要 --mirror PREFIX"
    local image
    local -a images=(
        node:24-alpine
        golang:1.27.3-alpine
        alpine:3.21
        postgres:18-alpine
        redis:8-alpine
    )
    info "检查镜像源 manifest（只查询清单，不下载镜像层）..."
    for image in "${images[@]}"; do
        if docker buildx imagetools inspect "${REGISTRY_PREFIX}${image}" >/dev/null; then
            success "${REGISTRY_PREFIX}${image}"
        else
            error "镜像源不可用或缺少该镜像：${REGISTRY_PREFIX}${image}"
            return 1
        fi
    done
}

service_health() {
    local service="$1" container_id health state
    container_id="$(compose ps -q "$service" 2>/dev/null || true)"
    if [[ -z "$container_id" ]]; then
        printf '%-12s %s\n' "$service" "未创建"
        return 1
    fi
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container_id" 2>/dev/null || true)"
    state="$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
    if [[ "$health" == "healthy" ]]; then
        printf '%-12s %s (%s)\n' "$service" "$health" "$state"
        return 0
    fi
    printf '%-12s %s (%s)\n' "$service" "${health:-unknown}" "${state:-unknown}"
    [[ "$state" == "running" && "$health" == "no-healthcheck" ]]
}

wait_for_health() {
    [[ "$HEALTH_TIMEOUT" =~ ^(0|[1-9][0-9]{0,4})$ ]] ||
        die "HEALTH_TIMEOUT 必须是 1 到 99999 之间的整数"
    (( HEALTH_TIMEOUT > 0 )) || die "HEALTH_TIMEOUT 必须大于 0"
    local deadline=$((SECONDS + HEALTH_TIMEOUT)) service all_healthy
    info "等待服务健康（最多 ${HEALTH_TIMEOUT}s）..."
    while (( SECONDS < deadline )); do
        all_healthy=true
        for service in sub2api postgres redis; do
            if ! service_health "$service" >/dev/null; then
                all_healthy=false
            fi
        done
        if [[ "$all_healthy" == true ]]; then
            success "所有服务已通过健康检查。"
            return 0
        fi
        sleep 3
    done

    error "等待服务健康超时。当前状态："
    for service in sub2api postgres redis; do service_health "$service" || true; done
    compose ps
    compose logs --tail=80
    return 1
}

run_connectivity() {
    local failed=0
    info "从应用容器测试依赖和外网连接..."

    if compose exec -T sub2api sh -ec \
        'PGPASSWORD="$DATABASE_PASSWORD" psql -v ON_ERROR_STOP=1 -h "$DATABASE_HOST" -p "$DATABASE_PORT" -U "$DATABASE_USER" -d "$DATABASE_DBNAME" -Atqc "SELECT 1" | grep -qx 1'; then
        success "PostgreSQL：DNS、TCP、认证及 SQL 查询正常"
    else
        error "PostgreSQL：连接或 SQL 检查失败"
        failed=1
    fi

    if compose exec -T redis sh -ec \
        'if [ -n "${REDISCLI_AUTH:-}" ]; then redis-cli -h redis -p 6379 ping; else unset REDISCLI_AUTH; redis-cli -h redis -p 6379 ping; fi | grep -qx PONG'; then
        success "Redis：Docker DNS、TCP 和 Redis PING/认证正常"
    else
        error "Redis：DNS、TCP、认证或 PING 检查失败"
        failed=1
    fi

    if compose exec -T -e NETWORK_TEST_URL="$NETWORK_TEST_URL" sub2api sh -ec \
        'wget -q --spider -T 10 "$NETWORK_TEST_URL"'; then
        success "外网 HTTPS：${NETWORK_TEST_URL}"
    else
        error "外网 HTTPS：无法访问 ${NETWORK_TEST_URL}；请检查 DNS、防火墙、代理配置"
        failed=1
    fi
    return "$failed"
}

backup_database() {
    local output="${1:-${PWD}/sub2api-postgres-$(date +%Y%m%d-%H%M%S).dump}"
    local temporary="${output}.tmp.$$"
    prepare
    compose_config
    compose ps --status running --services | grep -qx postgres ||
        die "PostgreSQL 服务未运行；请先运行 start"
    mkdir -p "$(dirname "$output")"
    info "正在导出 PostgreSQL 数据库到：$output"
    if compose exec -T postgres sh -ec \
        'PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dump --format=custom --no-owner --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' >"$temporary"; then
        chmod 600 "$temporary"
        mv "$temporary" "$output"
        success "数据库备份完成（权限 600）：$output"
    else
        rm -f "$temporary"
        die "数据库备份失败；已清理不完整文件"
    fi
}

show_status() {
    prepare
    compose ps
    printf '\n'
    for service in sub2api postgres redis; do service_health "$service" || true; done
    printf '\n'
    local ids
    ids="$(compose ps -q)"
    if [[ -n "$ids" ]]; then
        docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}' $ids 2>/dev/null ||
            docker stats --no-stream $ids
    fi
    printf '\n访问地址： http://localhost:%s\n' "$(grep '^SERVER_PORT=' "$ENV_FILE" | tail -n 1 | cut -d= -f2- || printf '8080')"
}

doctor() {
    prepare
    info "Docker daemon"
    docker version --format 'Client {{.Client.Version}} / Server {{.Server.Version}}' || return 1
    info "Compose 配置校验"
    compose_config
    success "Compose 配置有效"
    info "容器状态"
    compose ps
    local unhealthy=0 service container_id health
    for service in sub2api postgres redis; do
        service_health "$service" || unhealthy=1
        container_id="$(compose ps -q "$service" 2>/dev/null || true)"
        if [[ -n "$container_id" ]]; then
            health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container_id" 2>/dev/null || true)"
            if [[ "$health" == "unhealthy" ]]; then
                warn "$service 最近的健康检查输出："
                docker inspect --format '{{range .State.Health.Log}}{{printf "%s exit=%d %s\n" .End .ExitCode .Output}}{{end}}' "$container_id"
                compose logs --no-color --tail=80 "$service"
            fi
        fi
    done
    if (( unhealthy != 0 )); then
        warn "至少一个服务未运行或未健康；请结合上方检查结果排查。"
    fi
    run_connectivity || unhealthy=1
    return "$unhealthy"
}

build_standalone_image() {
    local tag="${1:-$IMAGE_TAG}"
    local version
    check_docker
    version="$(backend_version)"
    info "检测到 backend 版本：${version}"
    info "构建独立镜像：$tag"
    local -a build_args=(build)
    [[ "$NO_CACHE" == true ]] && build_args+=(--no-cache)
    [[ "$PULL_IMAGES" == true ]] && build_args+=(--pull)
    build_args+=(
        --build-arg "VERSION=${version}"
        --build-arg "GOPROXY=${GOPROXY:-https://goproxy.cn,direct}"
        --build-arg "GOSUMDB=${GOSUMDB:-sum.golang.google.cn}"
        --build-arg "NPM_CONFIG_REGISTRY=${NPM_CONFIG_REGISTRY:-https://registry.npmmirror.com}"
    )
    if [[ "$MIRROR_SET" == true ]]; then
        build_args+=(
            --build-arg "NODE_IMAGE=${REGISTRY_PREFIX}node:24-alpine"
            --build-arg "GOLANG_IMAGE=${REGISTRY_PREFIX}golang:1.27.3-alpine"
            --build-arg "ALPINE_IMAGE=${REGISTRY_PREFIX}alpine:3.21"
            --build-arg "POSTGRES_IMAGE=${REGISTRY_PREFIX}postgres:18-alpine"
        )
    fi
    if [[ "$PROXY_SET" == true ]]; then
        build_args+=("${BUILD_PROXY_ARGS[@]}")
    fi
    build_args+=(
        --tag "$tag"
        --file "${SCRIPT_DIR}/Dockerfile"
        "$REPO_ROOT"
    )
    docker "${build_args[@]}"
    success "镜像构建完成：$tag"
}

export_image() {
    local tag="${1:-$IMAGE_TAG}"
    local output="${2:-${PWD}/${tag//\//_}-$(date +%Y%m%d-%H%M%S).tar}"
    check_docker
    docker image inspect "$tag" >/dev/null 2>&1 || die "本地镜像不存在：$tag（先运行 build-image）"
    docker save --output "$output" "$tag"
    success "镜像已导出：$output"
}

main() {
    local compose_file_set=false
    while (($#)); do
        case "$1" in
            --check)
                shift
                (($# == 0)) || die "--check 不接受其他参数"
                check_deploy2_copies
                return $?
                ;;
            --mirror-list)
                mirror_list
                return 0
                ;;
            -f|--file)
                (($# >= 2)) || die "$1 需要一个路径"
                COMPOSE_FILE="$2"
                [[ "$COMPOSE_FILE" = /* ]] || COMPOSE_FILE="${PWD}/${COMPOSE_FILE}"
                compose_file_set=true
                shift 2
                ;;
            --mirror)
                (($# >= 2)) || die "$1 需要 Registry 地址前缀"
                REGISTRY_PREFIX="$2"
                MIRROR_SET=true
                shift 2
                ;;
            -e|--env-file)
                (($# >= 2)) || die "$1 需要一个路径"
                ENV_FILE="$2"
                [[ "$ENV_FILE" = /* ]] || ENV_FILE="${PWD}/${ENV_FILE}"
                shift 2
                ;;
            --mirror)
                (($# >= 2)) || die "$1 需要 Registry 地址前缀"
                REGISTRY_PREFIX="$2"
                MIRROR_SET=true
                shift 2
                ;;
            -p|--project)
                (($# >= 2)) || die "$1 需要一个名称"
                PROJECT_NAME="$2"
                shift 2
                ;;
            --force-build) FORCE_BUILD=true; NO_CACHE=true; shift ;;
            --no-cache) NO_CACHE=true; shift ;;
            --pull) PULL_IMAGES=true; shift ;;
            --proxy)
                (($# >= 2)) || die "$1 需要代理 URL"
                PROXY_URL="$2"
                PROXY_SET=true
                shift 2
                ;;
            --force-recreate) FORCE_RECREATE=true; shift ;;
            --wait-timeout)
                (($# >= 2)) || die "$1 需要秒数"
                HEALTH_TIMEOUT="$2"
                WAIT_TIMEOUT_SET=true
                shift 2
                ;;
            --tail)
                (($# >= 2)) || die "$1 需要行数"
                TAIL_LINES="$2"
                TAIL_SET=true
                shift 2
                ;;
            -h|--help) usage; return 0 ;;
            --) shift; break ;;
            -*) die "未知选项：$1" ;;
            *) break ;;
        esac
    done

    local command="${1:-help}"
    shift || true
    while (($#)); do
        case "$1" in
            --force-build) FORCE_BUILD=true; NO_CACHE=true; shift ;;
            --no-cache) NO_CACHE=true; shift ;;
            --pull) PULL_IMAGES=true; shift ;;
            --proxy)
                (($# >= 2)) || die "$1 需要代理 URL"
                PROXY_URL="$2"
                PROXY_SET=true
                shift 2
                ;;
            --force-recreate) FORCE_RECREATE=true; shift ;;
            --force)
                [[ "$command" == sync-config ]] || die "--force 仅适用于 sync-config"
                FORCE_SYNC=true
                shift
                ;;
            --wait-timeout)
                (($# >= 2)) || die "$1 需要秒数"
                HEALTH_TIMEOUT="$2"
                WAIT_TIMEOUT_SET=true
                shift 2
                ;;
            --tail)
                (($# >= 2)) || die "$1 需要行数"
                TAIL_LINES="$2"
                TAIL_SET=true
                shift 2
                ;;
            *) break ;;
        esac
    done
    if [[ "$compose_file_set" == false && -n "${SUB2API_COMPOSE_FILE:-}" ]]; then
        COMPOSE_FILE="$SUB2API_COMPOSE_FILE"
        [[ "$COMPOSE_FILE" = /* ]] || COMPOSE_FILE="${PWD}/${COMPOSE_FILE}"
    fi

    check_command_options "$command"

    if [[ "$MIRROR_SET" == true ]]; then
        case "$command" in
            start|build|build-app|rebuild|restart|force-restart|build-image|pull|check-mirror) ;;
            *) die "--mirror 仅适用于构建或拉取镜像的命令" ;;
        esac
        configure_registry_mirror
    elif [[ -n "${IMAGE_MIRROR:-}" ]]; then
        REGISTRY_PREFIX="$IMAGE_MIRROR"
        case "$command" in
            start|build|build-app|rebuild|restart|force-restart|build-image|pull|check-mirror)
                configure_registry_mirror
                ;;
            *) die "IMAGE_MIRROR 仅适用于构建或拉取镜像的命令" ;;
        esac
    fi

    case "$command" in
        start|build|build-app|rebuild|restart|force-restart|build-image)
            if [[ -n "$PROXY_URL" ]]; then
                PROXY_SET=true
                configure_build_proxy
            fi
            ;;
        *)
            [[ "$PROXY_SET" == false ]] || die "--proxy 仅适用于会执行镜像构建的命令"
            ;;
    esac

    case "$command" in
        help)
            (($# == 0)) || die "help 不接受位置参数"
            usage
            ;;
        mirror-list)
            (($# == 0)) || die "mirror-list 不接受位置参数"
            mirror_list
            ;;
        check)
            (($# == 0)) || die "check 不接受位置参数"
            check_deploy2_copies
            ;;
        init-env)
            (($# == 0)) || die "init-env 不接受位置参数"
            init_env
            ;;
        sync-config) sync_config "$@" ;;
        version)
            (($# == 0)) || die "version 不接受位置参数"
            printf 'backend version: %s\n' "$(backend_version)"
            ;;
        start)
            (($# == 0)) || die "start 不接受位置参数"
            prepare
            compose_config
            build_compose_services sub2api
            local -a up_args=(-d)
            [[ "$FORCE_BUILD" == true || "$NO_CACHE" == true || "$PULL_IMAGES" == true || "$FORCE_RECREATE" == true ]] &&
                up_args+=(--force-recreate sub2api)
            compose up "${up_args[@]}"
            wait_for_health
            run_connectivity
            ;;
        build)
            prepare; compose_config; build_compose_services "$@"
            ;;
        build-app)
            (($# == 0)) || die "build-app 不接受位置参数"
            prepare; compose_config; build_compose_services sub2api
            ;;
        rebuild)
            (($# == 0)) || die "rebuild 不接受位置参数"
            prepare; compose_config
            NO_CACHE=true
            build_compose_services sub2api
            compose up -d --force-recreate sub2api
            wait_for_health
            run_connectivity
            ;;
        restart)
            prepare
            if [[ "$FORCE_BUILD" == true || "$NO_CACHE" == true || "$PULL_IMAGES" == true ]]; then
                build_compose_services sub2api
                compose up -d --force-recreate sub2api
            elif [[ "$FORCE_RECREATE" == true ]]; then
                compose up -d --force-recreate "$@"
            else
                compose restart "$@"
            fi
            wait_for_health
            run_connectivity
            ;;
        force-restart)
            prepare
            if [[ "$FORCE_BUILD" == true || "$NO_CACHE" == true || "$PULL_IMAGES" == true ]]; then
                build_compose_services sub2api
            fi
            compose up -d --force-recreate "$@"
            wait_for_health
            run_connectivity
            ;;
        pull)
            prepare
            compose pull "$@"
            ;;
        validate)
            prepare_config
            compose_config
            success "Compose 配置有效"
            ;;
        check-mirror)
            (($# == 0)) || die "check-mirror 不接受位置参数"
            check_mirror
            ;;
        backup-db) backup_database "${1:-}" ;;
        stop)
            (($# == 0)) || die "stop 不接受参数"
            prepare
            compose stop
            ;;
        down)
            (($# == 0)) || die "down 不接受参数；脚本会保留数据卷和持久化目录"
            prepare
            compose down
            ;;
        status)
            (($# == 0)) || die "status 不接受位置参数"
            show_status
            ;;
        logs)
            prepare
            if (($#)); then compose logs --tail="$TAIL_LINES" --follow "$@"
            else compose logs --tail="$TAIL_LINES" --follow; fi
            ;;
        doctor)
            (($# == 0)) || die "doctor 不接受位置参数"
            doctor
            ;;
        connectivity)
            (($# == 0)) || die "connectivity 不接受位置参数"
            prepare
            run_connectivity
            ;;
        build-image)
            (($# <= 1)) || die "build-image 最多接受一个 TAG"
            build_standalone_image "${1:-$IMAGE_TAG}"
            ;;
        export-image)
            (($# <= 2)) || die "export-image 最多接受 TAG 和 FILE"
            export_image "${1:-$IMAGE_TAG}" "${2:-}"
            ;;
        exec)
            prepare
            (($# >= 1)) || die "用法：exec SERVICE [COMMAND...]"
            local service="$1"
            shift
            if (($#)); then compose exec "$service" "$@"
            else compose exec "$service" sh; fi
            ;;
        *) usage >&2; die "未知命令：$command" ;;
    esac
}

main "$@"
