
# `backend/cmd/server` Wire 依赖装配原理

本文聚焦解释 Google Wire 如何把配置、repository、service、中间件、handler 和 server 组装为可运行的 HTTP 应用。目标是让读者不必从 `main.go` 逐行猜测每个对象在哪里创建、谁依赖谁，以及为什么 `initializeApplication` 看起来没有实现。

服务完整启动、安装模式和关闭流程见[Backend 服务启动流程与架构导读](./server-startup-architecture.md)；HTTP 路由的注册与授权边界见[Backend HTTP 路由注册与模块功能分析](./backend-routing-architecture.md)。

> 本文只描述当前源码中的依赖注入设计。Wire 是编译期代码生成工具，不是运行时容器；ProviderSet 的排列顺序不代表对象创建顺序。

## 1. 先建立正确心智模型

可以把 Wire 看成一个**静态依赖图求解器和 Go 代码生成器**：

1. 每个 provider 是一个普通 Go 函数：参数表示它需要什么，返回值表示它能提供什么。
2. `wire.NewSet` 把 providers 按模块归组，供上层组合。
3. `wire.Build` 声明某个应用入口可用哪些 providers。
4. Wire 从目标类型反向寻找 provider，递归构造依赖关系，并检查缺失、重复或无法匹配的依赖。
5. Wire 生成普通 Go 初始化代码；程序运行时执行生成代码，不会启动一个动态容器去扫描类型或反射注入。

因此，依赖方向不是由 `main.go` 中一串 `NewXxx()` 决定，而是由**目标对象、provider 函数签名以及 ProviderSet 的可见范围**共同决定。

```text
main.go
  └─ initializeApplication(buildInfo)
       └─ wire_gen.go 中 Wire 生成的普通 Go 函数
            ├─ config provider
            ├─ database / Redis / repositories
            ├─ services
            ├─ handlers + auth middleware
            ├─ Gin router
            ├─ net/http.Server
            └─ Application + Cleanup
```

关键入口分别是 `main.go` 对 `initializeApplication` 的调用、`wire.go` 的 injector 声明、以及生成文件中的真实初始化函数（[`main.go:151`](../../backend/cmd/server/main.go#L151)、[`wire.go:34`](../../backend/cmd/server/wire.go#L34)、[`wire_gen.go:32`](../../backend/cmd/server/wire_gen.go#L32)）。

## 2. 为什么 `wire.go` 看起来像“空实现”

`backend/cmd/server/wire.go` 和 `wire_gen.go` 是一对**声明与生成实现**：

| 文件                                                        | 作用                                                                                                                                | 是否手动维护实现                                   |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| [`wire.go:1`](../../backend/cmd/server/wire.go#L1)         | 受 `wireinject` build tag 控制；声明 injector 输入、可用 ProviderSet 和期望输出。文件中也有手写的应用级 provider / cleanup 函数。 | 手动维护 injector 声明及项目自己的 provider 逻辑。 |
| [`wire_gen.go:1`](../../backend/cmd/server/wire_gen.go#L1) | Wire 生成的初始化代码，build tag 为 `!wireinject`。                                                                               | 不手动修改；改声明后重新生成。                     |

在 `wire.go` 中，`initializeApplication` 的函数体写有 `wire.Build(...)`，之后的 `return nil, nil` 是供 injector 声明满足 Go 语法的占位代码，不是正式运行时行为。此文件只在 `wireinject` build tag 下参与编译（[`wire.go:1`](../../backend/cmd/server/wire.go#L1)、[`wire.go:34`](../../backend/cmd/server/wire.go#L34)、[`wire.go:35`](../../backend/cmd/server/wire.go#L35)）。

普通构建不带 `wireinject` tag，使用生成文件中的 `initializeApplication`。生成文件开头明确标识其由 Wire 生成，并使用互补的 `!wireinject` tag（[`wire_gen.go:1`](../../backend/cmd/server/wire_gen.go#L1)、[`wire_gen.go:6`](../../backend/cmd/server/wire_gen.go#L6)、[`wire_gen.go:32`](../../backend/cmd/server/wire_gen.go#L32)）。

不要在 `wire.go` 中把 injector 的占位 `return nil, nil` 当成实际逻辑，也不要直接编辑 `wire_gen.go`；否则手动改动可能在下一次生成时被覆盖。注意 `wire.go` 不全是占位代码：例如 `provideCleanup`、build-info adapter 都是项目手写的真实 provider 实现，应修改其源文件中的逻辑（[`wire.go:66`](../../backend/cmd/server/wire.go#L66)、[`wire.go:84`](../../backend/cmd/server/wire.go#L84)）。

## 3. Provider 是依赖图中的节点

### 3.1 函数参数与返回值就是依赖声明

以配置 provider 为例：它没有入参，返回 `*Config` 和 `error`，表示它能提供配置且构造过程可能失败（[`tconfig/wire.go:6`](../../backend/internal/config/wire.go#L6)、[`config/wire.go:11`](../../backend/internal/config/wire.go#L11)）。

repository provider 展示了依赖的传递关系：

- `ProvideEnt(cfg *config.Config)` 需要配置，提供 `*ent.Client`，并可返回错误（[`repository/wire.go:185`](../../backend/internal/repository/wire.go#L185)）。
- `ProvideSQLDB(client *ent.Client)` 需要 Ent client，提供底层 `*sql.DB`，并显式检查依赖有效性（[`repository/wire.go:211`](../../backend/internal/repository/wire.go#L211)）。
- `ProvideRedis(cfg *config.Config)` 也依赖配置，提供 Redis client（[`repository/wire.go:234`](../../backend/internal/repository/wire.go#L234)）。

Wire 由此能推导出：

```text
*config.Config ──┬──> *ent.Client ──> *sql.DB
                 └──> *redis.Client
```

同理，repository 构造函数通过参数声明对 Ent、SQL、Redis、其他 repository 或配置的依赖；Wire 不需要理解 repository 的业务，只需根据 Go 类型匹配 provider。

### 3.2 ProviderSet 是模块清单，不是执行脚本

`config.ProviderSet` 暴露配置 provider（[`config/wire.go:6`](../../backend/internal/config/wire.go#L6)）；`repository.ProviderSet` 汇总 repositories、缓存、客户端、加密器以及 Ent/SQL/Redis 基础资源（[`repository/wire.go:67`](../../backend/internal/repository/wire.go#L67)）；`service.ProviderSet` 汇总领域服务，并包含接口绑定（[`service/wire.go:859`](../../backend/internal/service/wire.go#L859)、[`service/wire.go:889`](../../backend/internal/service/wire.go#L889)）；`middleware.ProviderSet` 暴露 JWT、管理员、API Key、审计和 Step-up 中间件构造器（[`middleware/wire.go:21`](../../backend/internal/server/middleware/wire.go#L21)）；`handler.ProviderSet` 汇总 HTTP handlers（[`handler/wire.go:235`](../../backend/internal/handler/wire.go#L235)）；`server.ProviderSet` 提供 Router 与标准库 HTTP Server（[`http.go:24`](../../backend/internal/server/http.go#L24)）。

这些集合是供 injector 使用的**声明式 provider 目录**，不是按文本顺序逐条执行的脚本。真正的创建顺序需要满足依赖关系，并由生成代码明确表达。

## 4. 应用级 Injector 如何定义最终目标

应用 injector 在 [`wire.go:34`](../../backend/cmd/server/wire.go#L34) 中声明，唯一显式运行时输入是 `handler.BuildInfo`；其可使用的 ProviderSet 与应用级 provider 集中列在 `wire.Build` 中（[`wire.go:35`](../../backend/cmd/server/wire.go#L35) 至 [`wire.go:60`](../../backend/cmd/server/wire.go#L60)）：

```go
func initializeApplication(buildInfo handler.BuildInfo) (*Application, error) {
    wire.Build(
        config.ProviderSet,
        repository.ProviderSet,
        service.ProviderSet,
        securityaudit.ProviderSet,
        payment.ProviderSet,
        middleware.ProviderSet,
        handler.ProviderSet,
        server.ProviderSet,
        providePrivacyClientFactory,
        provideServiceBuildInfo,
        providePluginHostInfo,
        provideCleanup,
        wire.Struct(new(Application), "Server", "PromptAudit", "PluginManager", "Cleanup"),
    )
    return nil, nil
}
```

这段声明提供了依赖图的**搜索边界**：

- injector 参数 `buildInfo` 是图的外部输入；Wire 不负责生成它。
- 各 `ProviderSet` 提供可选的构造节点。
- `wire.Struct(new(Application), ...)` 告诉 Wire 构造 `Application`，并只填充 `Server`、`PromptAudit`、`PluginManager`、`Cleanup` 四个字段（[`wire.go:27`](../../backend/cmd/server/wire.go#L27)、[`wire.go:61`](../../backend/cmd/server/wire.go#L61)）。
- Wire 根据这些目标字段的类型递归查找 provider，并进一步构造它们所需的依赖。

所以理解依赖图时，应从 `Application` 的目标字段往回追，不需要从 `ProviderSet` 第一行一路读到最后。

## 5. 六层对象是怎样连起来的

### 5.1 配置层：产生共享配置对象

`config.ProviderSet` 暴露 `ProvideConfig`；它通过 `LoadForBootstrap()` 产生 `*config.Config`（[`config/wire.go:6`](../../backend/internal/config/wire.go#L6)、[`config/wire.go:11`](../../backend/internal/config/wire.go#L11)）。该对象被 repository、service、middleware、handler 和 server 的 provider 按需依赖。

### 5.2 Repository 层：基础资源与持久化适配

以数据库和 Redis 为例，生成器先调用 config provider，再将配置传给 `ProvideEnt` 和 `ProvideRedis`；SQL DB 又从 Ent client 派生。普通 repository 构造函数接收这些基础资源，建立具体数据访问对象。仓储集合见 [`repository/wire.go:67`](../../backend/internal/repository/wire.go#L67)。

repository 在依赖图中承担“具体技术实现”的角色，例如 Ent repository 实现持久化、Redis cache 实现缓存接口；service 通常依赖这些对象或抽象接口，不需要自行读取环境变量并创建客户端。

### 5.3 Service 层：将数据与策略组合成业务能力

service provider 的参数通常是 repositories、其他 services、配置以及外部 client；返回领域服务。举例而言，`ProvideSettingService`、`ProvideAPIKeyService` 等构造函数将相应依赖组合成设置和 API Key 业务能力（[`service/wire.go:841`](../../backend/internal/service/wire.go#L841)、[`service/wire.go:859`](../../backend/internal/service/wire.go#L859)）。

Service 是依赖图中最丰富的一层：多个 repository 和 service 可以共享同一份由 Wire 构造的对象。provider 的执行也可能启动后台任务，因此需要检查具体 provider 是否调用 `Start()`；Wire 负责初始化依赖，不会自动替业务模块决定何时 shutdown。

当服务依赖接口时，ProviderSet 可用 `wire.Bind` 声明“哪个具体类型实现哪个接口”，例如将 `*OpenAIGatewayService` 绑定到 `AccountRuntimeBlocker`（[`service/wire.go:889`](../../backend/internal/service/wire.go#L889)）。接口绑定补充的是静态类型关系，不会在运行时做实现类搜索。

### 5.4 Middleware 层：把服务能力包装为 Gin 中间件

中间件 provider 使用已经装配好的 service 作为构造依赖。例如 JWT middleware 构造器需要 Auth、User、Setting 和 Audit 服务，再返回专用的中间件类型（[`jwt_auth.go:14`](../../backend/internal/server/middleware/jwt_auth.go#L14)）。管理员认证和 API Key 认证同样由对应 provider 构造（[`admin_auth.go:16`](../../backend/internal/server/middleware/admin_auth.go#L16)、[`api_key_auth.go:21`](../../backend/internal/server/middleware/api_key_auth.go#L21)）。

Wire 只负责把这些中间件实例传给 server 层；实际把中间件挂到 Gin Engine 或路由组上的动作发生在 `ProvideRouter` / `SetupRouter`，不在 injector 中间件 provider 里。

### 5.5 Handler 层：形成 HTTP 处理能力

Handler provider 将 service 注入 handler。随后 `ProvideHandlers` 把 Auth、User、Gateway、Payment、Admin 等细分 handler 聚合为 `*handler.Handlers`（[`handler/wire.go:183`](../../backend/internal/handler/wire.go#L183)、[`handler/wire.go:235`](../../backend/internal/handler/wire.go#L235)）。

这种聚合结构是依赖注入边界与路由注册代码之间的衔接：Wire 负责构造全部处理器并提供一个总结构；router 再根据业务域从这个结构取出 handler 并注册 route。

### 5.6 Server 层：把 handler 和中间件变成可监听服务

`ProvideRouter` 接收 `*config.Config`、聚合 handlers、多个 middleware 类型、API Key/订阅/Ops/设置服务、composite resolver 和 Redis client，创建 Gin Engine 并执行路由装配（[`http.go:30`](../../backend/internal/server/http.go#L30)）。`ProvideHTTPServer` 再接收配置和 `*gin.Engine`，构造标准库 `*http.Server`（[`http.go:113`](../../backend/internal/server/http.go#L113)）。

关键依赖链可简化为：

```text
Config ───────────────────────────────────────────┐
Repositories ──> Services ──┬──> Middleware ──┐  │
                            └──> Handlers ────┼──┴─> Gin Engine
Config + Gin Engine ───────────────────────────────> http.Server
```

Middleware 和 Handler 都依赖部分 Service，所以两条支路在 server 汇合；它们不是先后加载的独立子系统。

## 6. 用生成代码验证依赖关系

Wire 生成的文件将依赖图展开为普通 Go 语句，阅读时建议选择一个具体类型追踪，而不是试图一次看完数百个局部变量。

生成代码里可以看到以下顺序：

1. `config.ProvideConfig()` 生成配置对象；随后 `repository.ProvideEnt(configConfig)`、SQL DB 与 Redis provider 构造基础设施（[`wire_gen.go:34`](../../backend/cmd/server/wire_gen.go#L34) 至 [`wire_gen.go:55`](../../backend/cmd/server/wire_gen.go#L55)）。
2. 各 repository 以这些基础资源为参数构造，service 再以 repository / service / config 为参数构造。
3. `handler.ProvideHandlers(...)` 产生聚合 handler；JWT、管理员、API Key 等 middleware provider 也从同一依赖图取得所需 service（[`wire_gen.go:331`](../../backend/cmd/server/wire_gen.go#L331) 至 [`wire_gen.go:337`](../../backend/cmd/server/wire_gen.go#L337)）。
4. `server.ProvideRouter(...)` 使用上述对象构造 Gin Engine；`server.ProvideHTTPServer(...)` 将 Engine 包装成 HTTP Server（[`wire_gen.go:338`](../../backend/cmd/server/wire_gen.go#L338)、[`wire_gen.go:339`](../../backend/cmd/server/wire_gen.go#L339)）。
5. Wire 创建 Cleanup 函数，并将 HTTP Server、Prompt Audit、Plugin Manager 和 Cleanup 组装进 `Application` 返回（[`wire_gen.go:359`](../../backend/cmd/server/wire_gen.go#L359) 至 [`wire_gen.go:367`](../../backend/cmd/server/wire_gen.go#L367)）。

局部变量名如 `configConfig` 是生成器为避免命名冲突产生的实现细节，不是领域概念，也不是供业务代码引用的 API。

## 7. `main.go` 中哪些事情不由 Wire 负责

`main.go` 仍是应用生命周期的编排者：

- 在调用 injector 前加载一次 bootstrap 配置，用于日志配置和 RunMode 判断；`initializeApplication` 里的配置 provider 又会为依赖图提供配置（[`main.go:135`](../../backend/cmd/server/main.go#L135)、[`config/wire.go:11`](../../backend/internal/config/wire.go#L11)）。
- 准备 `handler.BuildInfo` 并传入 injector（[`main.go:145`](../../backend/cmd/server/main.go#L145)、[`main.go:151`](../../backend/cmd/server/main.go#L151)）。
- 接收 `Application`，显式启动 Plugin Manager 和 Prompt Audit，再调用 `ListenAndServe`（[`main.go:155`](../../backend/cmd/server/main.go#L155)、[`main.go:173`](../../backend/cmd/server/main.go#L173)）。
- 收到退出信号后先关闭 HTTP Server，函数返回时由 `defer app.Cleanup()` 清理后台服务和基础设施（[`main.go:155`](../../backend/cmd/server/main.go#L155)、[`main.go:190`](../../backend/cmd/server/main.go#L190)）。

换言之，Wire 决定“**构造哪些对象，以及构造所需的依赖**”；main 决定“**何时启动监听、何时响应信号、何时关闭应用**”。某个 provider 也可能在构造时启动 worker，但这属于 provider 自身副作用，并不改变这条边界。

## 8. 改依赖时的实用步骤

### 新增一个依赖到现有 Handler

1. 在对应 handler 的构造函数或专用 `Provide...` 函数中增加强类型参数。
2. 确认该参数类型已有 provider，并且相关 ProviderSet 被应用 injector 纳入。
3. 若参数是接口，检查是否需要在 `service.ProviderSet` 或相应模块声明 `wire.Bind`。
4. 运行 Wire 生成；不要手动补写 `wire_gen.go`。
5. 检查生成失败信息：缺 provider、同类型多个 provider、接口未绑定、provider 返回错误等分别表示不同的图问题。
6. 运行后端最小相关测试/构建，确认生成代码和业务代码均可编译。

### 新增一个后台长生命周期服务

1. 确认构造 provider 是否启动 goroutine、timer、worker、订阅者或连接池。
2. 明确由谁调用 `Start()`，启动失败是否阻断主服务。
3. 若服务需要停止，在应用 cleanup provider 中声明依赖并注册对应 Stop/Close 动作；Wire 会据此把实例提供给 cleanup。
4. 确保应用正常退出时先停止依赖后台服务，再关闭它们依赖的 Redis/数据库连接。

此项目的 `provideCleanup` 汇总长生命周期组件，先并行停止应用层后台服务，再按顺序关闭 Redis 和 Ent 基础设施（[`wire.go:84`](../../backend/cmd/server/wire.go#L84)、[`wire.go:404`](../../backend/cmd/server/wire.go#L404)、[`wire.go:447`](../../backend/cmd/server/wire.go#L447)）。具体清理次序和错误处理应以当前 `provideCleanup` 实现为准。

## 9. 实际应该怎么写、怎么生成

### 9.1 哪些内容手写

通常按以下位置分别维护，**不是把初始化调用抄写到 `wire_gen.go`**：

1. **构造函数 / Provider**：需要创建一个新对象时，在所属模块实现有明确类型签名的构造函数或 `Provide...` 函数。参数写出它依赖的对象，返回值写出它提供的对象；可失败时按 Go 约定返回 `(..., error)`。
2. **模块 ProviderSet**：把该 provider 加入该模块的 `wire.NewSet(...)`。例如 repository、service、middleware 和 handler 都有自己的 ProviderSet（[`repository/wire.go:67`](../../backend/internal/repository/wire.go#L67)、[`service/wire.go:859`](../../backend/internal/service/wire.go#L859)、[`middleware/wire.go:21`](../../backend/internal/server/middleware/wire.go#L21)、[`handler/wire.go:235`](../../backend/internal/handler/wire.go#L235)）。
3. **接口绑定（如需要）**：如果下游参数使用接口类型，而 provider 返回具体实现类型，在合适的 ProviderSet 中显式声明 `wire.Bind`。该项目示例见 [`service/wire.go:889`](../../backend/internal/service/wire.go#L889)。
4. **应用 Injector**：只有新增的模块 ProviderSet 尚未被应用入口纳入时，才需要修改 `cmd/server/wire.go` 的 `wire.Build(...)` 列表。当前主 injector 已包含各层 ProviderSet（[`wire.go:34`](../../backend/cmd/server/wire.go#L34) 至 [`wire.go:60`](../../backend/cmd/server/wire.go#L60)）。
5. **应用生命周期**：如果对象需要显式 `Start` / `Stop`，还要决定启动位置，并把停止逻辑注册到 cleanup。生成依赖代码不会自动推断业务生命周期（[`wire.go:84`](../../backend/cmd/server/wire.go#L84)、[`main.go:155`](../../backend/cmd/server/main.go#L155)）。

例如，一个业务服务需要一个 repository 时，手写构造函数和 ProviderSet 的样式如下。此代码仅演示 Wire 的依赖声明方式，不是要求重复添加同名项目类型：

```go
// service/example.go
func NewExampleService(repo ExampleRepository, cfg *config.Config) *ExampleService {
    return &ExampleService{repo: repo, cfg: cfg}
}

// service/wire.go
var ProviderSet = wire.NewSet(
    NewExampleService,
    // 其他 providers...
)
```

Wire 看见 `NewExampleService` 后，会要求依赖图能提供 `ExampleRepository` 和 `*config.Config`，然后生成调用它的代码。若仓储构造函数产生的是具体类型、而 service 要求接口，应按项目现有接口边界添加对应 `wire.Bind`，而不是在生成文件里做类型转换。

### 9.2 仅重新生成 Server Wire

在仓库根目录执行：

```bash
cd backend
go generate ./cmd/server
```

`wire_gen.go` 文件头的 `go:generate` 指令会运行 `go run -mod=mod github.com/google/wire/cmd/wire`；Wire 模块版本由 `backend/go.mod` 固定为 `v0.7.0`（[`wire_gen.go:3`](../../backend/cmd/server/wire_gen.go#L3)、[`go.mod:26`](../../backend/go.mod#L26)）。`go generate ./cmd/server` 是只针对该包重新生成 Wire 的推荐命令。

也可以直接进入 `backend/cmd/server` 执行指令中同一条命令：

```bash
cd backend/cmd/server
go run -mod=mod github.com/google/wire/cmd/wire
```

不要从仓库根目录随意直接运行 `go run`，因为 Go module 位于 `backend/`；从 `backend/` 使用 `go generate ./cmd/server` 最不容易弄错工作目录。

### 9.3 重新生成全部代码

如果改动同时涉及 Ent schema 和 Wire，或希望执行项目统一生成入口，在 `backend/` 目录运行：

```bash
make generate
```

该 target 会先 `go generate ./ent`，再 `go generate ./cmd/server`，所以它除了 Wire 外还可能更新 Ent 生成代码（[`Makefile:9`](../../backend/Makefile#L9) 至 [`Makefile:11`](../../backend/Makefile#L11)）。仅改 Wire 依赖时，优先使用上一节的定向命令，避免不必要地重生成 Ent。

### 9.4 生成后检查

```bash
cd backend
go test ./cmd/server
git diff --check
git status --short
```

确认 `wire_gen.go` 是生成器更新的结果，并检查变更中没有意外的大范围生成差异。若 Wire 报缺少 provider、重复 provider、接口实现未绑定或依赖环，应先修正构造函数签名 / ProviderSet / `wire.Bind`，再运行生成命令；不要手工修改生成文件绕过图错误。

### 9.5 使用 Wire 的优点与代价

| 方面                       | 说明                                                                                                                                                                                                                                                 |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 优点：依赖关系显式         | provider 的参数和返回类型就是依赖声明；读构造函数签名即可看到对象需要什么，不必搜索隐藏的全局容器或运行时注册。                                                                                                                                      |
| 优点：编译期检查           | Wire 在生成阶段检查依赖图是否可满足，例如缺 provider、类型歧义、接口缺少绑定等；问题通常能在开发/构建阶段暴露，而不是等某个运行分支触发。                                                                                                            |
| 优点：无运行时容器         | 生成物是普通 Go 调用，运行时不需要反射扫描、动态查找或容器启动；最终注入路径可直接在 [`wire_gen.go:32`](../../backend/cmd/server/wire_gen.go#L32) 查看。                                                                                            |
| 优点：模块化组织           | `ProviderSet` 可以按 config、repository、service、middleware、handler、server 分层组合，主 injector 用较少代码声明应用构造边界（[`wire.go:35`](../../backend/cmd/server/wire.go#L35) 至 [`wire.go:60`](../../backend/cmd/server/wire.go#L60)）。 |
| 代价：需要生成步骤         | 改了依赖声明后必须重新生成并提交生成文件；只改普通业务函数而没有改变依赖图时，通常不需要生成。                                                                                                                                                       |
| 代价：要理解两类文件       | 开发者需要分清 `wire.go` 中的 injector 声明与手写 provider，以及 `wire_gen.go` 的生成实现；误改生成物会在重新生成时丢失。                                                                                                                        |
| 代价：ProviderSet 需要维护 | 新 provider 必须进入合适的集合，接口实现有时还需 `wire.Bind`；集合过大、重复提供同一类型或接口边界不清晰时，错误信息也需要理解和定位。                                                                                                             |
| 代价：代码生成物较长       | 依赖图越大，生成的显式局部变量和构造调用越多。生成文件适合核实某条依赖链，不适合作为主要手写维护入口。                                                                                                                                               |
| 不适合的场景               | 如果对象必须根据运行时数据任意选择实现、在进程运行中动态注册/卸载，静态依赖图未必是合适的机制；应将动态选择封装在显式 provider/factory 后，再由 Wire 注入该工厂。                                                                                    |

Wire 不是免费的抽象层：本项目既有 Wire 声明，也要维护生成代码和清理流程。它的主要收益是让大型静态依赖图有类型检查、可复现的构造顺序和集中入口；它不会自动设计分层、启动后台任务或处理关闭。

### 9.6 不使用 Wire 会怎么样

不使用 Wire 不会改变服务的运行时架构，也不会让配置、数据库或 handler 消失；只是需要由开发者手动写出现在生成文件里的构造代码。通常会在一个 `initializeApplication` / `NewApplication` 函数中按拓扑顺序完成：

```go
func initializeApplication(buildInfo handler.BuildInfo) (*Application, error) {
    cfg, err := config.ProvideConfig()
    if err != nil {
        return nil, err
    }

    entClient, err := repository.ProvideEnt(cfg)
    if err != nil {
        return nil, err
    }
    db, err := repository.ProvideSQLDB(entClient)
    if err != nil {
        return nil, err
    }
    redisClient := repository.ProvideRedis(cfg)

    userRepo := repository.NewUserRepository(entClient, db)
    userService := service.NewUserService(userRepo /* other required dependencies */)
    userHandler := handler.NewUserHandler(userService /* other required dependencies */)

    router := buildRouter(cfg, userHandler /* middleware and remaining handlers */)
    httpServer := server.ProvideHTTPServer(cfg, router)
    return &Application{Server: httpServer}, nil
}
```

此示例只展示手动组装的形状；项目实际构造函数往往需要更多依赖，不能将示例当作可直接替换的完整实现。手动装配至少要自己保证：

1. 每个依赖先于使用它的对象创建，构造顺序满足依赖图。
2. 所有 service、middleware、handler 和 server 都收到正确、共享的依赖实例。
3. 构造错误被逐层返回，并在失败时关闭已经创建的 Ent/Redis 等资源，避免初始化中途泄漏。
4. 新增或改动构造函数后，所有手写调用点都同步更新。
5. 长生命周期 worker 的启动、失败处理和停止顺序被正确维护。

Go 编译器仍会检查手写调用的参数和返回类型，因此“不用 Wire”不等于失去 Go 的类型安全；但编译器不会自动替你验证一份集中声明的完整依赖图，也不会指出尚未被调用的新 provider 是否应该接入应用。随着本项目这种跨 config、repository、service、middleware、handler、server 的依赖规模增长，手工初始化函数会逐渐变成很长的构造清单，遗漏依赖、重复创建资源、错误关闭顺序和修改调用点的维护成本都由团队承担。

若移除 Wire，合理做法是保留显式的手写 composition root（组合根），而不是让各模块散落地自行读取全局配置、创建数据库连接或通过 package 全局变量取依赖。也就是说，Wire 解决的是“组合代码如何可靠地产生”，并不取代依赖注入本身。

### 9.7 常见误区

| 误区                                                    | 正确理解                                                                                                    |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| “`main.go` 没创建 repository，所以程序里没有创建。” | 构造发生在生成的 injector 代码中；入口只拿最终的 `Application`。                                          |
| “`wire.go` 只有声明，里面的所有函数都不执行。”      | Injector 的占位函数体不执行；但同文件中的手写 provider（例如 `provideCleanup`）是 Wire 会调用的真实实现。 |
| “ProviderSet 从上到下执行。”                          | ProviderSet 是 provider 目录；生成顺序由依赖图决定。                                                        |
| “Wire 运行时扫描并反射创建对象。”                     | Wire 在生成阶段解析 Go 类型，运行阶段执行静态生成的函数调用。                                               |
| “接口实现会自动被运行时发现。”                        | 通常需要显式 provider 或 `wire.Bind` 建立实现到接口的静态绑定。                                           |
| “Wire 自动负责服务的 Start/Stop。”                    | Wire 只调用 provider；启动策略与 cleanup 仍要由 provider / main / cleanup 代码明确实现。                    |
| “改 `wire_gen.go` 比改 provider 快。”               | 手动改生成文件容易丢失；应修改 injector/provider 后重新生成。                                               |

## 10. 源码索引

以下链接均带源码行号，可从应用入口开始逐层阅读：

| 位置                                                                             | 读什么                                                                |
| -------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| [`main.go:134`](../../backend/cmd/server/main.go#L134)                          | 正式启动：加载配置、调用 injector、启动 server、处理信号和 shutdown。 |
| [`wire.go:27`](../../backend/cmd/server/wire.go#L27)                            | `Application` 的最终出口对象。                                      |
| [`wire.go:34`](../../backend/cmd/server/wire.go#L34)                            | Injector 声明及依赖图入口。                                           |
| [`wire_gen.go:32`](../../backend/cmd/server/wire_gen.go#L32)                    | Wire 生成实现的入口。                                                 |
| [`config/wire.go:6`](../../backend/internal/config/wire.go#L6)                  | Config provider。                                                     |
| [`repository/wire.go:67`](../../backend/internal/repository/wire.go#L67)        | Repository 与基础设施 ProviderSet。                                   |
| [`service/wire.go:859`](../../backend/internal/service/wire.go#L859)            | Service ProviderSet 和接口绑定。                                      |
| [`middleware/wire.go:21`](../../backend/internal/server/middleware/wire.go#L21) | Middleware ProviderSet。                                              |
| [`handler/wire.go:235`](../../backend/internal/handler/wire.go#L235)            | Handler ProviderSet。                                                 |
| [`http.go:24`](../../backend/internal/server/http.go#L24)                       | Server ProviderSet。                                                  |
| [`http.go:30`](../../backend/internal/server/http.go#L30)                       | Gin router 构造和路由装配入口。                                       |
| [`http.go:113`](../../backend/internal/server/http.go#L113)                     | `http.Server` 构造入口。                                            |
| [`router.go:23`](../../backend/internal/server/router.go#L23)                   | 全局中间件与 SetupRouter。                                            |
| [`wire.go:84`](../../backend/cmd/server/wire.go#L84)                            | 手写的应用资源 cleanup provider。                                     |
