# 配置文件、server 配置加载与默认值解析

本文说明 Sub2API 后端配置文件的结构、`cmd/server` 如何加载配置、YAML/环境变量/代码默认值的覆盖顺序、bootstrap 阶段的特殊处理，以及启动配置常见故障的定位方法。内容以当前源码为准；源码行号可能随版本变化。

## 1. 配置由谁定义

配置结构和加载实现集中在 [`backend/internal/config/config.go`](../../backend/internal/config/config.go)：

- [`Config`](../../backend/internal/config/config.go#L68) 是应用配置总入口，字段映射到 YAML 根节点。
- 各配置分组使用 `mapstructure` tag 声明键名，如 `Server ServerConfig \`mapstructure:"server"\`` 对应 `server:`。
- [`setDefaults()`](../../backend/internal/config/config.go#L2039) 设置运行时默认值。
- [`Load()`](../../backend/internal/config/config.go#L1823) 和 [`LoadForBootstrap()`](../../backend/internal/config/config.go#L1830) 是两种加载入口。
- [`Validate()`](../../backend/internal/config/config.go#L2713) 做加载后的语义和范围校验。
- 部署示例在 [`deploy/config.example.yaml`](../../deploy/config.example.yaml)，它是可复制修改的示例，不等于所有键的代码默认值。

当前 `Config` 的顶层分组包括：

| YAML 根键 | Go 配置字段 | 主要用途 |
| --- | --- | --- |
| `server` | `Server` | 监听地址、HTTP 超时/header/body 限制、可信代理、h2c。 |
| `log` | `Log` | 日志级别、格式、输出、文件轮转和采样。 |
| `cors` | `CORS` | 允许的 Origin 和凭证策略。 |
| `security` | `Security` | URL allowlist、代理探测、转发 IP、安全响应头、CSP 等。 |
| `billing`、`concurrency`、`run_mode`、`simple_mode` | 对应配置字段 | 计费、限流/并发及服务运行模式。 |
| `database` | `Database` | PostgreSQL 连接和连接池。 |
| `redis` | `Redis` | Redis 连接、TLS、超时和连接池。 |
| `jwt`、`totp`、`webauthn` | 对应配置字段 | token、TOTP 加密和 Passkey/RP 设置。 |
| `gateway` | `Gateway` | 上游协议入口、请求大小、调度、缓存、WebSocket 和其他网关行为。 |
| `ops`、`dashboard_cache`、`dashboard_aggregation`、`usage_cleanup` | 对应配置字段 | 运维监控、聚合、清理及 Dashboard 缓存。 |
| `linuxdo_connect`、`wechat_connect`、`oidc_connect`、`dingtalk_connect`、`github_oauth`、`google_oauth` | 对应配置字段 | 第三方登录及其 client credentials。 |
| `pricing`、`plugins`、`image_storage`、`batch_image`、`update`、`idempotency` | 对应配置字段 | 定价数据、插件、异步图片、升级及幂等。 |
| `default`、`rate_limit`、`api_key_auth_cache`、`subscription_cache`、`token_refresh` 等 | 对应配置字段 | 用户/Key 初始值和缓存、限流、刷新策略。 |

字段的准确名称、类型和子结构以 [`Config`](../../backend/internal/config/config.go#L68) 及相邻的配置结构定义为准。不要仅凭 YAML 注释推断代码是否支持某字段。

## 2. 配置来源和优先级

常规值优先级是：

```text
显式 Viper Set / 特殊环境变量处理
  > 环境变量
  > 配置文件
  > setDefaults() 中的代码默认值
  > Go 类型零值
```

常规环境变量通过 Viper `AutomaticEnv()` 读取，点号替换为下划线，并使用大写环境变量名。例如：

```text
server.port                   -> SERVER_PORT
database.password             -> DATABASE_PASSWORD
gateway.max_body_size         -> GATEWAY_MAX_BODY_SIZE
security.url_allowlist.enabled -> SECURITY_URL_ALLOWLIST_ENABLED
```

配置源初始化在 [`load()`](../../backend/internal/config/config.go#L1834)，配置文件搜寻规则在 [`configureConfigSource()`](../../backend/internal/config/config.go#L2023)：

1. 若设置了 `CONFIG_FILE`，只把它指定为配置文件路径；不会继续尝试其他路径。
2. 否则按以下顺序添加配置目录：
   - `$DATA_DIR`
   - `/app/data`
   - 当前工作目录 `.`
   - `./config`
   - `/etc/sub2api`
3. Viper 查找名为 `config.yaml` / YAML 配置的文件。

配置文件路径和安装数据目录不是完全相同的概念。`CONFIG_FILE` 只覆盖 server 配置读取文件；setup 写入配置时使用 `setup.GetDataDir()` 计算 `config.yaml` 位置，优先采用 `DATA_DIR`，然后尝试可写的 `/app/data`，最后使用当前目录。相关逻辑见 [`setup.GetDataDir()`](../../backend/internal/setup/setup.go#L47) 和 [`setup.GetConfigFilePath()`](../../backend/internal/setup/setup.go#L70)。若运维同时设置 `CONFIG_FILE` 和 `DATA_DIR`，应明确两者用途，避免启动读一个文件而安装流程写入另一个位置。

### 配置文件缺失与损坏

- 默认搜寻路径中没有配置文件：`Load()` 会继续使用默认值和环境变量。
- `CONFIG_FILE` 明确指向不存在的文件：加载返回错误，不会静默回退到默认值；对应测试在 [`config_test.go:366`](../../backend/internal/config/config_test.go#L366)。
- YAML 格式错误或配置文件读取错误：`ReadInConfig()` 返回错误，加载失败。
- `CONFIG_FILE` 的相对路径按进程当前工作目录解析。容器内的工作目录和宿主机路径不相同。

## 3. 环境变量覆盖的注意事项

### 3.1 普通映射

Viper `AutomaticEnv()` 和 `SetEnvKeyReplacer(".", "_")` 提供常见的 `YAML_KEY` 覆盖，大小写不敏感通常由操作系统环境变量命名和 Viper 的环境查找处理共同决定。环境变量值会按目标类型解码；数组一般用逗号分隔，例如：

```bash
SECURITY_FORWARDED_CLIENT_IP_HEADERS=True-Client-IP,X-CDN-Client-IP
```

但不要假设所有 Go 字段都能无条件由 env-only 提供。Viper 的 `Unmarshal` 只解码出现在 `AllKeys()` 集合中的键；`AutomaticEnv()` 本身不会把一个此前从未见过的键新增到该集合。代码通过 `setDefaults()` / [`setEnvReachableDefaults()`](../../backend/internal/config/config.go#L2629) 注册必要键。

已有针对这类问题的系统性测试：[`env_reachability_test.go`](../../backend/internal/config/env_reachability_test.go)。如果新增配置字段要支持“只用环境变量、不提供 YAML 文件”，必须确保该 key 被 Viper 注册，并补充环境变量加载测试。

### 3.2 特殊环境变量和别名

以下变量有显式处理或绑定，应以代码为准：

| 环境变量 | 行为 |
| --- | --- |
| `CONFIG_FILE` | 指定配置文件完整路径，优先于其他搜寻目录。 |
| `DATA_DIR` | 增加配置搜寻目录；也被 setup 用作安装配置/锁文件数据目录。 |
| `TZ` | 非空时显式设置 `timezone`，覆盖 `TIMEZONE`、YAML 和默认值。 |
| `TIMEZONE` | 常规映射到 `timezone`；优先级低于显式处理的 `TZ`。 |
| `ENABLE_SERVER_TIMING` | 显式绑定到 `server.enable_server_timing`。 |
| `SERVER_TRUSTED_PROXIES` | 以逗号分隔解析 CIDR/IP，并特别记录“是否显式配置”，包括显式空值。 |
| `SECURITY_FORWARDED_CLIENT_IP_HEADERS` | 以逗号分隔解析并规范化 header 列表。 |

特殊逻辑位于 [`load()` 的环境绑定和处理段](../../backend/internal/config/config.go#L1834)。Setup 的 `AUTO_SETUP` 是另外一套 bootstrap installer 输入，不等价于普通 `Load()` 的 Viper 配置覆盖，见第 5 节。

### 3.3 哪些配置不适合只靠一个环境变量

- Go map（例如动态映射）通常不能用单个标量环境变量表达。
- `[]struct` 这类嵌套结构数组通常需要 YAML 配置文件。
- scalar slice 可由环境变量解析，但要使用项目实际测试过的格式。

`env_reachability_test.go` 明确把 map 和 `[]struct` 排除在单环境变量可覆盖范围之外。敏感信息可由环境变量提供，但复杂嵌套配置建议放入权限受控的配置文件。

## 4. 默认值如何生效

### 4.1 默认值的权威来源

运行时缺省值在 [`setDefaults()`](../../backend/internal/config/config.go#L2039)，而不是由 YAML 示例文件自动提供。常见默认值举例：

| 配置 | 当前代码默认值 | 说明 |
| --- | --- | --- |
| `run_mode` | `standard` | 空值或非法值在 [`NormalizeRunMode()`](../../backend/internal/config/config.go#L1817) 归一为 `standard`。 |
| `server.host` / `server.port` | `0.0.0.0` / `8080` | Setup 和正常服务共用地址概念，但加载入口不同。 |
| `server.mode` | `release` | 空值在加载后归一为 `debug`；设置默认值存在时通常不会为空。 |
| `server.read_header_timeout` / `max_header_bytes` / `idle_timeout` | 10 秒 / 64 KiB / 120 秒 | 加载后还会经 Validate 做范围校验。 |
| `server.max_request_body_size` | 256 MiB | `0` 表示关闭这一层全局限制；不能与 Gateway route 的 body limit 混为一谈。 |
| `server.h2c.enabled` | `false` | `deploy/config.example.yaml` 当前示例将 h2c 显式设置为 `true`。 |
| `database.host:port`、用户、库 | `localhost:5432`、`postgres`、`sub2api` | 本地开发回退；容器部署应显式使用 Compose service 名称和真实凭据。 |
| `redis.host:port` | `localhost:6379` | 容器中 localhost 指当前容器，不是 Redis service。 |
| `log.level` / `format` | `info` / `console` | 文件和 stdout 是否启用等也有代码默认值。 |
| `timezone` | `Asia/Shanghai` | `TZ` 可覆盖。 |
| `cors.allowed_origins` | 空列表 | 空列表不代表任意 Origin 都允许。 |
| `security.csp.enabled` | `true` | 默认 CSP policy 在 [`DefaultCSPPolicy`](../../backend/internal/config/config.go#L33)。 |
| `security.url_allowlist.enabled` | `false` | 启动会记录 SSRF/URL allowlist 检查关闭的警告；生产部署需理解其安全影响。 |
| `jwt.secret` | 空 | `Load()` 不允许最终为空；不得将代码默认值当作可用 secret。 |
| `totp.encryption_key` | 空后生成随机值 | 自动生成值只对当前进程有效，不作为持久配置保存；若要启用稳定 TOTP 加密，必须配置固定 key。 |

上表不是配置项完整清单。默认数据库/Redis 参数位于 [`setDefaults()` 的数据库与 Redis 段](../../backend/internal/config/config.go#L2218)，server 默认值位于 [`setDefaults()` 的 Server 段](../../backend/internal/config/config.go#L2042)。

### 4.2 示例文件可能有意覆盖代码默认值

部署示例可以包含与代码默认值不同的部署选择。例如当前示例文件：

- 显式启用 h2c（[`config.example.yaml:39`](../../deploy/config.example.yaml#L39)），而代码默认关闭；
- 显式设置 trusted proxy 列表（[`config.example.yaml:31`](../../deploy/config.example.yaml#L31)）；
- 使用较严格的 forwarded-IP ACL 兼容设置（[`config.example.yaml:117`](../../deploy/config.example.yaml#L117)）。

这是“示例配置覆盖默认值”，不是源代码默认值变更。用户复制 YAML 后，这些配置值会优先于代码默认值；如果同时有对应环境变量，则环境变量再覆盖 YAML。

## 5. `cmd/server` 的配置加载生命周期

完整启动主流程见[server 启动架构文档](./server-startup-architecture.md)。配置相关链条如下：

```text
main()
  ├─ NeedsSetup?
  │   ├─ AUTO_SETUP -> 读取数据库/Redis/管理员等 setup 环境变量，安装并写 config.yaml
  │   └─ setup wizard -> GetServerAddress() 轻量读取 host/port
  └─ runMainServer()
      ├─ LoadForBootstrap() -> 早期日志配置、RunMode 警告
      └─ initializeApplication() [Wire]
          └─ ProvideConfig() -> LoadForBootstrap() 再加载一份依赖注入配置
              └─ ProvideEnt()
                  ├─ PostgreSQL 连接与 SQL migrations
                  ├─ 从配置/数据库补齐 JWT secret
                  └─ 完整 cfg.Validate()
```

关键源码：

- `main()` 的 setup 分支：[`cmd/server/main.go:55`](../../backend/cmd/server/main.go#L55)
- setup server 地址轻量读取：[`cmd/server/main.go:97`](../../backend/cmd/server/main.go#L97)
- 正常启动首轮配置读取：[`cmd/server/main.go:134`](../../backend/cmd/server/main.go#L134)
- Wire 注入入口：[`cmd/server/wire.go`](../../backend/cmd/server/wire.go)
- Wire 生成代码调用 `config.ProvideConfig()`：[`cmd/server/wire_gen.go:36`](../../backend/cmd/server/wire_gen.go#L36)
- `ProvideConfig()` 实际委托 `LoadForBootstrap()`：[`internal/config/wire.go:11`](../../backend/internal/config/wire.go#L11)
- PostgreSQL migrations、bootstrap secrets、最终 Validate：[`internal/repository/ent.go:115`](../../backend/internal/repository/ent.go#L115)

### 5.1 为什么启动期间允许 JWT secret 为空

`Load()` 用于需要完整配置的场景，必须提供 `jwt.secret`。`LoadForBootstrap()` 用于启动准备阶段：

1. 若 JWT secret 原本为空，暂时用 32 个零字符替代，以通过同一套 Validate；
2. 校验其他配置；
3. 再将返回给调用方的 `cfg.JWT.Secret` 恢复为空；
4. Ent/PostgreSQL schema migrations 完成后，`ensureBootstrapSecrets()`：
   - 若 YAML/env 提供了 secret，尝试将其写入数据库；若数据库已有另一个值，则采用数据库已有值，以便多实例保持一致；
   - 若配置没有 secret，从数据库读取已有 secret；若还没有，则生成并持久化；
5. `cfg.Validate()` 再执行一次，此时必须有真正的、至少 32 bytes 的 JWT secret。

实现分别见 [`LoadForBootstrap()` 和 `load()`](../../backend/internal/config/config.go#L1827)、[`Validate()` 的 JWT 检查](../../backend/internal/config/config.go#L2786)、[`ensureBootstrapSecrets()`](../../backend/internal/repository/security_secret_bootstrap.go#L27) 和 [`ProvideEnt()` 初始化顺序](../../backend/internal/repository/ent.go#L149)。

**生产建议：**显式注入受密钥管理系统保护的 32+ bytes 随机 `JWT_SECRET`，不要依赖数据库自动生成后再随意重建/迁移数据库。配置的 secret 若与数据库持久化 secret 不一致，启动会警告并使用数据库值；多个副本必须共享一致的数据库和 JWT secret 生命周期。

### 5.2 为什么会读取两次

`runMainServer()` 首次加载配置是为了在初始化完整 DI graph 前配置 logger 并输出 RunMode 警告；随后 Wire 的 `ProvideConfig()` 再加载配置并将其注入 repositories、services、handlers 和 server。第二次加载使用相同环境和配置源，但实际生效的应用配置对象是 Wire graph 内的那一份，且其中的 JWT secret 会在数据库 bootstrap 阶段补齐。

Viper 使用包级默认实例；当前 `load()` 直接修改该实例。应用生产启动通常只按上述流程执行，不应在同一进程中把它当作完全隔离的多租户/多次配置读取器。测试会 `viper.Reset()` 清理状态，示例见 [`config_test.go:18`](../../backend/internal/config/config_test.go#L18)。

### 5.3 Setup server 不是正常配置加载

未完成安装时，`runSetupServer()` 使用 `config.GetServerAddress()` 读取 host/port，代码创建新的 `viper.New()` 实例，只提供 setup listener 所需的少量值，不执行完整 `Config.Validate()`，也不创建正常 Wire 应用图。正常启动则会走 `LoadForBootstrap()`。

因此，setup wizard 能监听在 `SERVER_HOST`/`SERVER_PORT` 不代表完整服务的全部配置已经正确，也不代表数据库/Redis 已连接。AUTO_SETUP 是另一条路径：由 [`AutoSetupFromEnv()`](../../backend/internal/setup/setup.go#L617) 显式读取 `DATABASE_*`、`REDIS_*`、`ADMIN_*`、`SERVER_*`、`JWT_SECRET`，测试依赖并写安装配置。

## 6. 规范化、兼容迁移和验证

配置加载不是简单 YAML 反序列化。`load()` 在 Unmarshal 后还会：

1. 处理显式 trusted proxy 和 forwarded-client-IP 环境变量；
2. 规范化 RunMode、server mode、URL、CORS origins、header allowlists、日志配置等字符串；
3. 读取 `gateway.forced_codex_instructions_template_file` 指向的文件内容；路径错误会导致加载失败；
4. 处理旧配置兼容，例如旧 WeChat 环境变量和旧 Gateway key 到新 key 的迁移；
5. 生成缺省 TOTP encryption key（仅当前启动进程的配置内），并记录警告；
6. 执行 `Validate()`；
7. 对 URL allowlist 关闭、可配置 response header filtering 关闭和弱 JWT secret 等情况输出安全警告。

相关逻辑主要从 [`config.go:1834`](../../backend/internal/config/config.go#L1834) 的 `load()` 开始。非法配置分成两种处理：

- **无法安全继续，直接返回 error**：例如 YAML 读/解析失败、字段无效、必需 JWT secret 缺失（完整 Load）、超出数值范围、URL 格式不合法。
- **有明确兼容/安全回退并告警**：例如非法 UMQ mode 被清空禁用、弱 JWT secret 记录 warning；具体行为需读对应代码，不能假设所有错误都 fail-fast。

`Validate()` 不只校验 server。它还验证插件限制、日志、WebAuthn、限流、OAuth、Gateway、安全 URL、数据库/Redis 等配置。校验失败会包装为 `validate config error: ...`，启动入口显示 `Failed to load config`。

## 7. Server 配置和 HTTP 实际生效方式

[`ServerConfig`](../../backend/internal/config/config.go#L688) 主要包括：

- `host`、`port`：由 [`ServerConfig.Address()`](../../backend/internal/config/config.go#L1544) 生成 `host:port`。
- `mode`：`debug`/`release`，影响 Gin mode；空值另有归一逻辑。
- `read_header_timeout`、`max_header_bytes`、`idle_timeout`：传入标准库 `http.Server`；`WriteTimeout` 和 `ReadTimeout` 不设置，以支持长流式响应/较大请求。
- `trusted_proxies`：显式配置状态由非序列化字段 `TrustedProxiesConfigured` 记录；router 根据该状态调用 Gin 的 trusted proxies 设置。空列表与“完全未配置”语义不同。
- `max_request_body_size`：在 HTTP handler 外使用 `http.MaxBytesHandler` 做全局 body 上限；未设置正值时回退到 `gateway.max_body_size`。
- `h2c`：仅 `enabled: true` 才配置明文 HTTP/2；其参数有单独范围校验。
- `enable_server_timing`：可以用 `ENABLE_SERVER_TIMING` 显式绑定。

配置字段定义在 [`ServerConfig` / `H2CConfig`](../../backend/internal/config/config.go#L688)，校验在 [`Validate()`](../../backend/internal/config/config.go#L2713)，实际 server 与 body 限制装配见[server HTTP provider](../../backend/internal/server/http.go#L113)，trusted proxy 应用见[router provider](../../backend/internal/server/http.go#L93)。

注意区分不同层的同类限制：

```text
http.Server / http.MaxBytesHandler (全局)
  -> server.max_request_body_size，未设置时回退 gateway.max_body_size
      -> gateway route 的 RequestBodyLimit
          -> 特定 endpoint 的更小文本/协议限制
```

出现 413 时需确认是哪一层触发，而不是只查 Gateway handler。

## 8. 安全与运维建议

- 生产环境避免将数据库密码、Redis 密码、OAuth client secret、JWT/TOTP secret 写进公开仓库或命令行参数；通过权限受控的 Secret 注入。
- `DATABASE_HOST=localhost` / `REDIS_HOST=localhost` 在容器中指向当前容器本身；Compose 网络中通常使用数据库/Redis 的 service DNS 名。
- `DATABASE_PASSWORD`、`REDIS_PASSWORD` 等敏感 env 不应通过 `env`、`docker inspect` 截图或公开日志泄漏。
- 配置里的 `server.trusted_proxies` 只写直接连接后端的反向代理；不要信任所有外部可控的 forwarded headers。
- `security.url_allowlist.enabled=false` 会关闭 URL allowlist/SSRF 校验并产生告警。变更此项前须评估用户可配置 URL 的出站风险。
- `run_mode: simple` 会影响计费与额度检查行为；启动日志会警告，不能把它当作单纯 UI/功能开关。
- 修改静态 YAML/env 后通常要重启服务进程才会重新读取；不要假设修改文件会热加载。产品设置页管理的数据库动态配置另走 SettingService/运行时设置机制，不等价于这份静态配置。
- 自动生成的 TOTP key 仅当前进程内有效；需稳定启用 TOTP 时显式设置 `totp.encryption_key`，并在所有副本共享同一密钥。

## 9. 配置问题排查

### 9.1 确认服务到底读了哪个文件

1. 检查 `CONFIG_FILE` 是否设置；非空时只读取那个文件。
2. 未设置时检查 `$DATA_DIR/config.yaml`、`/app/data/config.yaml`、当前目录、`./config`、`/etc/sub2api/config.yaml`。
3. 检查容器内路径和 volume mount，不要用宿主机路径假设容器内可见。
4. 若使用 setup wizard，另检查 `setup.GetDataDir()` 的位置规则；不要让其写入路径与 server 读取路径不一致。

### 9.2 环境变量看似设置却未生效

逐项核对：

1. YAML 路径和目标键拼写正确吗？
2. 环境变量名是否按 `root.sub_key` 转换成 `ROOT_SUB_KEY`？
3. 是否有特殊变量名需要显式 bind（例如 `ENABLE_SERVER_TIMING`）？
4. 该 key 是否在 `setDefaults()` / `setEnvReachableDefaults()` 注册，从而可被 `Unmarshal` 解析？
5. 值的类型格式是否符合字段类型（bool、整数、逗号分隔 scalar slice）？
6. 是否被显式 `CONFIG_FILE` 指向的另一个配置覆盖？
7. 是否存在 env alias / 旧键兼容或规范化逻辑？

新增 env-only 配置后，运行配置包测试，尤其关注 `TestConfigKeysAreEnvReachable` 和具体字段的 `Load...FromEnv` 测试。

### 9.3 常见启动错误

| 日志/现象 | 优先检查 |
| --- | --- |
| `read config error` | `CONFIG_FILE` 指向不存在/不可读文件，YAML 语法错误，挂载路径不对。 |
| `unmarshal config error` | YAML 类型与 Go 字段不匹配；检查 bool/int/list 的格式。 |
| `validate config error: jwt.secret is required` | 完整 `Load()` 场景未提供 secret；正常 server bootstrap 会延后从 DB 补齐，但数据库也必须可用。 |
| `jwt.secret must be at least 32 bytes` | 配置值不足 32 bytes；按 UTF-8 bytes 计数。 |
| `configured JWT secret mismatches persisted value` | DB 中已存在 JWT secret；应用会使用 DB 值，检查副本环境、数据库是否指向预期实例。 |
| 生成 TOTP encryption key 的错误 | 系统随机数生成失败；配置显式 key 可避免本次生成路径，但仍需管理好密钥。 |
| PostgreSQL/Redis 连接失败 | 检查容器 DNS、端口、认证、TLS、Compose network；不是 YAML 解析问题。 |
| 环境变量只在首次安装有效 | 这是 AUTO_SETUP 安装输入；安装成功后运行配置从 `config.yaml`/Viper 环境覆盖重新读取。 |
| listener 地址与预期不同 | 检查 `SERVER_HOST`、`SERVER_PORT`、配置文件位置和 setup/main 使用的是哪种加载路径。 |

## 10. 开发者检查清单

新增或修改配置时：

1. 在正确的 config struct 加字段，补全 `mapstructure` tag；确有需要时才加额外 `yaml`/JSON tag。
2. 在 `setDefaults()` 注册语义合理的默认值；不要为密钥提供固定、众所周知的默认 credential。
3. 判断是否必须支持 env-only。支持时确保 AllKeys 可达，并更新 [`setEnvReachableDefaults()`](../../backend/internal/config/config.go#L2649) 或显式 `BindEnv`。
4. 复杂 `map`、`[]struct` 配置明确说明要求 YAML，不承诺单环境变量表达。
5. 需要归一化或旧配置兼容时放在 `load()` 的规范化阶段，明确新旧键优先顺序。
6. 有安全或跨字段约束时在 `Validate()` 实施，并返回带配置路径的错误。
7. 更新 `deploy/config.example.yaml` 的说明和值；示例值要有意选择，不能误导为 runtime 默认。
8. 为默认值、YAML 覆盖、env 覆盖、非法值及 bootstrap 行为补测试。
9. 在本仓库约束下，如此次只更新 deploy2 文档，源码配置和样例不得顺带修改；任何源码工作要单独遵守对应任务范围。

在 `backend/` 目录运行配置相关测试：

```bash
go test ./internal/config ./internal/repository ./internal/setup
```

## 11. 源码行号导航

| 文件 | 关键区域 |
| --- | --- |
| [`internal/config/config.go:68`](../../backend/internal/config/config.go#L68) | `Config` 顶层配置结构。 |
| [`internal/config/config.go:688`](../../backend/internal/config/config.go#L688) | `ServerConfig`、h2c 配置字段。 |
| [`internal/config/config.go:1544`](../../backend/internal/config/config.go#L1544) | `ServerConfig.Address()` 生成 host:port。 |
| [`internal/config/config.go:1550`](../../backend/internal/config/config.go#L1550) | Database / Redis 配置字段。 |
| [`internal/config/config.go:1823`](../../backend/internal/config/config.go#L1823) | `Load()` / `LoadForBootstrap()`。 |
| [`internal/config/config.go:1834`](../../backend/internal/config/config.go#L1834) | Viper 初始化、文件读取、env 处理、normalize、Validate。 |
| [`internal/config/config.go:2023`](../../backend/internal/config/config.go#L2023) | `CONFIG_FILE` 和配置目录优先顺序。 |
| [`internal/config/config.go:2039`](../../backend/internal/config/config.go#L2039) | 代码默认值。 |
| [`internal/config/config.go:2629`](../../backend/internal/config/config.go#L2629) | env 可达默认值的原因和注册。 |
| [`internal/config/config.go:2713`](../../backend/internal/config/config.go#L2713) | 完整配置校验。 |
| [`internal/config/config.go:3841`](../../backend/internal/config/config.go#L3841) | setup server 轻量读取 host/port。 |
| [`internal/config/wire.go:11`](../../backend/internal/config/wire.go#L11) | Wire 的配置 provider。 |
| [`cmd/server/main.go:134`](../../backend/cmd/server/main.go#L134) | 正常服务启动首轮加载。 |
| [`cmd/server/wire_gen.go:36`](../../backend/cmd/server/wire_gen.go#L36) | Wire graph 再次调用 ProvideConfig。 |
| [`internal/repository/ent.go:149`](../../backend/internal/repository/ent.go#L149) | migrations 后补充 secret 并执行最终校验。 |
| [`internal/repository/security_secret_bootstrap.go:27`](../../backend/internal/repository/security_secret_bootstrap.go#L27) | JWT secret 从配置/数据库确保一致。 |
| [`internal/setup/setup.go:47`](../../backend/internal/setup/setup.go#L47) | Setup 数据目录选择。 |
| [`internal/setup/setup.go:165`](../../backend/internal/setup/setup.go#L165) | 首次安装判断。 |
| [`internal/setup/setup.go:617`](../../backend/internal/setup/setup.go#L617) | AUTO_SETUP 环境变量解析。 |
| [`internal/setup/setup.go:523`](../../backend/internal/setup/setup.go#L523) | Setup 写入 `config.yaml`。 |
