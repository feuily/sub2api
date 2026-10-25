# 新增平台 Platform：完整接入地图与开发步骤

本文回答：新增一个上游 AI 平台时，后端、前端、账号凭证、网关转发、模型/额度/计费和测试分别需要检查什么。目标是把新平台从“能在列表里选到”做到“账号可创建、请求可调度、能正确转发、计费和观测不出错”。

本文只分析现有项目结构，不改 backend/frontend 源码。所有源码链接指向当前仓库，行号会随代码变化。

## 1. 先明确“新增平台”具体指什么

在开始改代码前，把需求归到以下其中一类。不同类别的工作量差异很大：

| 类型 | 典型情况 | 必须解决的问题 |
| --- | --- | --- |
| A. 新平台名，复用已有网关和账号合同 | 新供应商提供标准 OpenAI Chat Completions，使用 API key、固定 base URL，不需要专属余额 API。 | 注册平台、默认端点/账号表单、gateway 调度和最小转发测试。 |
| B. 多协议 API Key provider | 一个 API key provider 可同时接收或转发 OpenAI、Anthropic、Responses 协议，或按模型在多个协议间路由。 | A 类之外，还要 provider profile、协议能力、base URL 和 protocol rules、跨协议转换与回退测试。 |
| C. 有专属生命周期/额度能力的平台 | OAuth、设备登录、token refresh、余额/订阅窗口、模型列表接口、媒体 API 等。 | A/B 类之外，为每项特殊能力增加实现、状态管理、密钥缓存失效、限额与监控语义。 |
| D. 新的客户端/上游协议族 | 现有 Anthropic / OpenAI / Gemini / Antigravity gateway 都无法承载其 endpoint、认证或 payload contract。 | 新增真正的网关服务、HTTP routes、协议适配、错误格式、计费和 observability；仅给 `PlatformSpec.Gateway` 加值不够。 |

**关键区分：**

- `platform` 表示上游账号属于哪个厂商/供应商。
- `account type` 表示认证/凭证生命周期（OAuth、API key、Setup Token、service account 等）。
- `api_protocol` 表示多协议 API Key provider 到上游使用什么协议。
- `gateway` 表示现有哪一个服务负责处理客户端请求。

新增平台通常不需要新增 account type 或客户端路由。只有上游认证/凭证结构确实不同，才实现专用 account type 行为；只有客户端 wire protocol 确实不同，才新建 gateway。

## 2. 当前平台注册架构：单一来源与能力清单

### 2.1 后端平台身份清单

1. 在 [`backend/internal/domain/constants.go:21`](../../backend/internal/domain/constants.go#L21) 增加平台 ID 常量。ID 是存入数据库、API、日志、缓存和配置中的稳定标识；使用小写、稳定、不可随展示名称变更的值。
2. 在 [`backend/internal/domain/platforms.go:37`](../../backend/internal/domain/platforms.go#L37) 的 `platformList` 增加一条 `PlatformSpec`：
   - `ID`：与常量严格一致；
   - `DisplayName`：用户看到的名字；
   - `Gateway`：只能选当前已有 gateway enum，除非同时实现新 gateway；
   - `CNProvider`：仅属于该共享国产 provider 行为组时设为 true；
   - `LiteLLMProvider`：确有对应价格目录 provider 时填写；没有就留空，不要猜别名。
3. 了解 `Platforms()`、`LookupPlatform()`、`IsConcretePlatform()`、`IsGroupPlatform()`、`UsesOpenAIGateway()` 由这份清单派生。具体平台可用于账号/分组/target/quota；`composite` 是特殊分组类型，不是具体 provider。见 [`platforms.go:62-85`](../../backend/internal/domain/platforms.go#L62)。
4. 组合分组 precedence 在 [`platforms.go:110`](../../backend/internal/domain/platforms.go#L110) 生成：现有前三个历史优先项保持在前，其余登记的平台按目录顺序追加。若新平台会参与 Composite 解析，要确认模型/价格/映射的相同名称是否造成歧义，以及现有默认顺序是否符合产品预期。

`PlatformGateway` 定义目前只有 Anthropic、OpenAI、Gemini、Antigravity 四族，见 [`platforms.go:10`](../../backend/internal/domain/platforms.go#L10)。不能给新 provider 随便填“最像”的 gateway 后就认为 payload、认证和能力完全兼容；先确认该 gateway 的 handler、账号筛选和上游构造逻辑是否支持它。

### 2.2 平台目录会自动派生的部分

[`service/platform_catalog.go:45`](../../backend/internal/service/platform_catalog.go#L45) 的 `BuildPlatformCatalog()` 从 domain 平台清单生成平台 catalog，并合并 `ProviderProfile`。它覆盖平台 ID、显示名、gateway、LiteLLM provider、multi-protocol profile 等。

下面这些机制已经以平台清单为基础，不应再创建一份新的硬编码平台表：

- 分组/组合路由 target 的具体平台校验；
- 用户 platform quota 的合法平台；
- 组合平台枚举、展示顺序和若干平台快照遍历；
- OpenAI gateway 平台归属检查；
- 前端内置 catalog 的基础选项及通用展示名。

但“由清单派生”不等于“新平台的所有能力都自动实现”。OAuth refresh、余额探测、模型同步、专用凭证表单、媒体、订阅窗口等仍由专用代码显式分派。

### 2.3 测试中的平台清单基准

- [`backend/internal/domain/platforms_test.go`](../../backend/internal/domain/platforms_test.go)：当前断言 legacy 展示顺序、Composite 顺序、gateway 分组、CN provider 和定价 provider。新平台加入后更新相应期望值；不要通过删掉断言让测试通过。
- [`backend/internal/service/platform_list_test.go`](../../backend/internal/service/platform_list_test.go)：当前用旧实现结果作等价基准，覆盖 quota list、scheduler snapshot、Composite matching、CN provider、多协议 provider、header override/upstream billing probe 等谓词。只更新与新平台业务相符的期望。
- [`backend/internal/service/platform_catalog_test.go:123`](../../backend/internal/service/platform_catalog_test.go#L123)：前端 JSON 内置 catalog 与后端生成物的一致性测试。

## 3. 按场景实施：从平台登记到可用账号

### 3.1 A 类：复用 OpenAI-compatible gateway 的 API-key provider

这是标准 OpenAI `/v1/chat/completions` provider 的常见最小完整路径：

1. 在 domain 常量与 `platformList` 注册稳定平台 ID，Gateway 选 `PlatformGatewayOpenAI`。
2. 在 [`service/account.go:317`](../../backend/internal/service/account.go#L317) 确认其 `IsOpenAICompatible()` 能由 domain gateway 分类识别；在 [`service/openai_gateway_scheduling.go:294`](../../backend/internal/service/openai_gateway_scheduling.go#L294) 确认平台规范化/调度不会把该 ID 降级为 OpenAI。
3. 决定其账号凭证 schema：至少要明确 `api_key`、`base_url`、model map、header override 等字段是否适用。通用 OpenAI-compatible 账号往往可复用 `AccountTypeAPIKey`，但要让 [`GetOpenAIBaseURL()`](../../backend/internal/service/account.go#L1509) 对新平台返回正确上游 base，不要默认落到 `https://api.openai.com`。
4. 让 gateway account selector 能按 group 的具体平台选择新平台账号；OpenAI gateway 可复用的前提是 handler 通过 `domain.UsesOpenAIGateway` 等谓词处理，不是只匹配 `PlatformOpenAI`。核对 [`gateway_scheduling.go`](../../backend/internal/service/gateway_scheduling.go)、[`openai_gateway_scheduling.go`](../../backend/internal/service/openai_gateway_scheduling.go) 和 [`handler/openai_gateway_handler.go:335`](../../backend/internal/handler/openai_gateway_handler.go#L335)。
5. 补账号创建表单的 provider 选择和 credential payload。`CreateAccountModal.vue` 的主平台选择区目前是专门列出的按钮；“多协议 provider”额外区域才从 catalog 动态生成，见 [`CreateAccountModal.vue:72`](../../frontend/src/components/account/CreateAccountModal.vue#L72) 和 [`CreateAccountModal.vue:4426`](../../frontend/src/components/account/CreateAccountModal.vue#L4426)。
6. 为 token、base URL、上游 header 和 endpoint 构造补服务测试，证明新平台走正确 provider 地址而不是 OpenAI 默认值。

可复用的是网关族共性，不是厂商差异。如果该 provider 的认证 header、默认路径、请求/响应格式或 model endpoint 有偏差，必须显式实现和测试差异。

### 3.2 B 类：加入多协议 ProviderProfile

多协议 API Key provider 在 [`backend/internal/service/provider_profile.go:32`](../../backend/internal/service/provider_profile.go#L32) 定义 `ProviderProfile`，在 [`provider_profile.go:90`](../../backend/internal/service/provider_profile.go#L90) 登记 profile。profile 描述：

- `DefaultMode` 与 `Modes`：默认接入模式和可选模式；
- 每种 mode 的 `BaseURLs`：按 `chat_completions` / `responses` / `anthropic` 声明官方地址；
- `Routing`：`by_inbound`（单一 provider 按入站协议）或 `by_model`（模型聚合平台按模型）；
- `ProtocolRules`：按模型选协议，首条命中生效；
- `ResponsesPath`：上游 Responses URL 特例；
- `ModelCatalog`：上游 `/models` 是否提供每模型 supported endpoints；
- `DefaultTestModel`：连接测试没给模型时用哪个轻量测试模型。

该 profile 同时驱动 `IsMultiProtocolAPIKeyProvider()`、账号协议解析、平台 catalog、多协议账号表单和一些通用转发行为。Profile 只能表示静态端点/协议能力，余额查询、quota 解析、OAuth、头部身份、专属 API 参数等动态或业务能力仍在专用代码中实现。

新增 profile 时至少确认：

1. 每个模式是否真的提供每个协议；不支持的协议不要登记假 base URL。
2. `by_inbound` 与 `by_model` 选择是否符合 provider 模型实际可用范围。
3. adaptive 请求在目标协议不支持时的回退是否安全，绝不能把不兼容请求体硬发到错误 endpoint。
4. 自定义 `base_url` 和官方默认 URL 的语义是否一致；是否需要协议专属 `api_base_urls`。
5. Responses path 是否为 `/v1/responses`、`/responses` 或其他版本化路径。
6. protocol rules 中模型匹配、顺序、`protocols` 列表和 wildcard 行为是否有测试。
7. `ModelCatalog: true` 时，上游 models payload 的 supported endpoints 确实可信且归一逻辑已覆盖。

相关 helper 在 [`account.go:1554`](../../backend/internal/service/account.go#L1554)、[`account.go:1606`](../../backend/internal/service/account.go#L1606)、[`account.go:1654`](../../backend/internal/service/account.go#L1654)，profile 的用户可见形状由 [`platform_catalog.go`](../../backend/internal/service/platform_catalog.go) 导出。

前端通用多协议账号表单可以从内置 catalog 自动渲染 profile，但以下行为目前仍有平台专属条件，不能假设 profile 登记后完全免改 UI：

- `isCNProviderPlatform()` 显式识别 Kimi/Zhipu/DeepSeek/MiniMax：[`credentialsBuilder.ts:270`](../../frontend/src/components/account/credentialsBuilder.ts#L270)。
- OpenCode 单独的模式、preset 和行为分支：[`credentialsBuilder.ts:343`](../../frontend/src/components/account/credentialsBuilder.ts#L343)。
- `OFFICIAL_ACCOUNT_API_PLATFORMS` 及特定官方连接检查：[`credentialsBuilder.ts:549`](../../frontend/src/components/account/credentialsBuilder.ts#L549)。
- 表单将 Generic Multi-Protocol 与 CN/OpenCode 特殊路径分开：[`CreateAccountModal.vue:4418`](../../frontend/src/components/account/CreateAccountModal.vue#L4418)。

不要将新的聚合 provider 误标为 CN provider 来“借用”UI；提炼共享行为或新增明确的 generic feature capability，测试之后再接入。

### 3.3 C 类：OAuth、refresh、额度和专属探测

若平台需要有状态认证或额度能力，按功能逐条检查：

| 能力 | 需要检查的实现点 | 典型遗漏后果 |
| --- | --- | --- |
| OAuth/设备授权 | Admin account create/OAuth handler、授权 state/PKCE、callback routes、provider API client、credential sanitize/store、账号过期/刷新服务。 | UI 可以显示 OAuth 按钮但后端没有安全闭环；callback state/CSRF 错误。 |
| Access token cache | token provider、缓存 key、token expiry、并发刷新锁、`CompositeTokenCacheInvalidator`。当前平台缓存失效按平台显式 switch，见 [`token_cache_invalidator.go:24`](../../backend/internal/service/token_cache_invalidator.go#L24)。 | 用户改 token 后仍使用旧缓存，或刷新竞态写回旧凭证。 |
| Usage/quota endpoint | `AccountUsageService` 分派、DTO/error 语义、速率限制/缓存、quota source 和管理员连接测试。 | 账号被错误标记故障或额度一直为 0/旧值。 |
| 余额/Coding Plan | balance/quota service 路由、模式字段、订阅窗口/重置时间解析、账号冷却/自动停调逻辑。 | 余额用尽仍持续调度，或正常账号永久停用。 |
| Channel monitor | 创建时 capability 校验和运行时 fetch 路由必须一一对应，见 [`monitorAccountQuotaCapability()`](../../backend/internal/service/channel_monitor_validate.go#L218)、[`fetchUncached()`](../../backend/internal/service/channel_monitor_quota_fetcher.go#L201)。 | 建立一个永远无法成功的 monitor，显示持续 error/降级状态。 |
| Scheduling thresholds | `AllowedSchedulingThresholdPlatforms`、[`account_scheduling_threshold_eval.go:54`](../../backend/internal/service/account_scheduling_threshold_eval.go#L54)、window candidates、reset timestamp/timezone。 | threshold UI 可配置但调度不暂停，或对错误窗口暂停。 |
| Model sync | [`buildUpstreamModelsRequest()`](../../backend/internal/service/upstream_models.go#L904)、provider-specific auth、base URL、响应 JSON 解码/分页/metadata。Catalog `supportsUpstreamModelSync()` 需要相符，见 [`platformCatalog.ts:89`](../../frontend/src/constants/platformCatalog.ts#L89)。 | 管理员点同步模型时报不支持、401、返回错平台模型。 |
| Pricing sync | `PlatformSpec.LiteLLMProvider`、pricing provider 解析和模型名称归一。前端根据非空 `litellm_provider` 决定是否展示定价同步，见 [`platformCatalog.ts:96`](../../frontend/src/constants/platformCatalog.ts#L96)。 | UI 显示功能但无价格数据，或映射到不相关 provider 的价格。 |
| 特殊能力/计费窗口 | `model_rate_limit.go`、upstream billing probe、usage snapshot、`channel_monitor`、特定服务与 repository 的显式分支。 | 服务可转发但不具备正确限流、扣费或管理面状态。 |

`service/account_service.go:226` 的 `Create()` 还有显式平台约束（例如 TypeSafe 只允许 API key）。新增平台需问：账号类型是否有硬约束？若有，在 service 层拒绝不合法组合；不能只在前端隐藏按钮，因为 API 可以被直接调用。

### 3.4 D 类：新增真正的 Gateway 协议族

先尝试证明现有 Gateway 可否承载该协议。若确实需要新 handler/service，需同时接通完整请求生命周期：

1. 在 [`domain/platforms.go`](../../backend/internal/domain/platforms.go) 定义新的 `PlatformGateway` 值和路由能力。
2. 新增 gateway service/handler 及 protocol request/response adapter；复用现有 `GatewayService`、`OpenAIGatewayService` 等的调度、billing、usage、retry/failover、cancel/stream 机制时要明确接口边界。
3. 在 [`server/routes/gateway.go`](../../backend/internal/server/routes/gateway.go) 注册其 HTTP endpoint、body limit、API key auth、request correlation、Ops error logging、group model allowlist、Composite route rewrite 和 group assignment。逐项确定顺序与协议错误 envelope。
4. 更新 server Wire provider/handler struct 注入（如需新 service）；重新生成 Wire 代码，不要手改 `wire_gen.go`。
5. 让 group platform、Composite target、admin platform validation 和 API contract tests 认可该网关平台。
6. 加 streaming、上下文取消、HTTP disconnect、重试、幂等/计费、usage parse、错误透传和 endpoint/model compatibility tests。
7. 更新 proxy/cors/body limits、websocket/h2c 兼容约束（如果适用），不要默认现有 route 的所有 header 都适合新协议。

新增“上游 provider platform”但客户端仍调用现有 OpenAI/Anthropic/Gemini API 时，通常不需要新 `/v1...` routes；新 `/v1` endpoint 只用于确有新客户端协议或产品 API 的情况。

## 4. 账号、调度、持久化：必须验证的边界

### 4.1 DB 字段是 string，但业务白名单仍然存在

Account 与 Group 的 Ent `platform` 是字符串字段：

- [`ent/schema/account.go:64`](../../backend/ent/schema/account.go#L64)
- [`ent/schema/group.go:84`](../../backend/ent/schema/group.go#L84)

因此，新增普通 platform ID 通常**不需要添加数据库 enum 或 platform CHECK migration**。但这不表示无需后端校验：

- Admin request validator 在 [`handler/admin/platform_validation.go`](../../backend/internal/handler/admin/platform_validation.go) 调用 `domain.IsConcretePlatform/IsGroupPlatform`；
- user platform quota schema 在 [`ent/schema/user_platform_quota.go:38`](../../backend/ent/schema/user_platform_quota.go#L38) 使用 `domain.IsConcretePlatform`；
- API/服务层仍可能有 account type、功能权限、reporting 或 subscription 的额外约束。

若新平台引入新的数据库字段、索引、状态表或凭证结构，仍需相应 Ent schema/migration；“platform 是 string”不能作为绕过数据迁移的理由。

### 4.2 帐号与分组的匹配必须准确

- 账号创建字段 [`CreateAccountRequest`](../../backend/internal/service/account_service.go#L177)，service 创建在 [`AccountService.Create()`](../../backend/internal/service/account_service.go#L226)。
- Group 与 account platform 用于调度选择，需测试新平台 group 只选新平台账号、Composite group 是否按预期查找。
- `NormalizeOpenAICompatiblePlatform()` 对非 OpenAI-gateway ID 归一成 OpenAI；新平台若走 OpenAI gateway，需 domain 清单分类正确。
- 针对相同模型名的多 provider 要测试 Composite owner resolution 和歧义拒绝，避免请求落入另一个平台账号。
- 新 ID 拼写/大小写必须一致。当前 domain `LookupPlatform()` 是精确字符串查找；不要依赖前后端自动大小写转换。

### 4.3 数据和缓存键要包含平台维度

排查新平台是否正确穿过以下流水线：

```text
Account.platform
  -> group.platform / composite target
  -> scheduler account filter + model capability
  -> upstream host/protocol/auth
  -> usage & billing attribution
  -> scheduler snapshots / quota caches / ops aggregation
```

检查缓存/Redis key、usage log `effective_platform`、平台维度统计 SQL、scheduler snapshot 的遍历与 repository 的 SQL allowlist。中央清单已自动派生若干列表，但 raw SQL、查询条件、Redis key namespace 和专用统计仍可能是显式白名单。特别注意 OpenCode usage 的 SQL 镜像和其他跨平台“挂载”能力，如 [`opencode_go_usage.go`](../../backend/internal/service/opencode_go_usage.go) 的平台 allowlist。

除非新平台本身提供上游行为，避免仅因 platform ID 新增而复用其他 provider 的 OAuth token cache key、余额缓存 key 或运维平台标签。

## 5. 前端需要核对的文件

| 文件 | 要改/验证什么 |
| --- | --- |
| [`frontend/src/components/account/CreateAccountModal.vue`](../../frontend/src/components/account/CreateAccountModal.vue) | 当前基础 provider 按钮是显式列举；新增平台必须出现在正确 UI 区域，账号类型、授权方式和 credential 输入要匹配。若属于 generic multi-protocol provider，确认动态区域能覆盖，而不是误入 CN/OpenCode 专用分支。 |
| [`frontend/src/components/account/credentialsBuilder.ts`](../../frontend/src/components/account/credentialsBuilder.ts) | 账号 create/edit credentials 序列化、默认 URL、模式、adaptive protocol、base URL 预设和 header override 资格。前后端必须读写同一 JSON key、同一 URL 语义。 |
| [`frontend/src/constants/platformCatalog.builtin.json`](../../frontend/src/constants/platformCatalog.builtin.json) | 后端 catalog 的前端内置副本；更新 `domain/platforms.go` 或 provider profile 后必须同步生成。 |
| [`frontend/src/constants/platformCatalog.ts`](../../frontend/src/constants/platformCatalog.ts) | 通用 catalog helper；如果新平台适配现有 schema，通常不必改；如果新增加 capability 字段或 gateway 类型，需更新类型和 helper。 |
| [`frontend/src/types/index.ts:940`](../../frontend/src/types/index.ts#L940) | `KnownAccountPlatform` 为前端专属界面/内置平台类型；类型是开放字符串，因此通常新 ID 不会让 API 类型失效，但新平台要使用专属 UI 类型/判断时应登记。 |
| [`frontend/src/components/common/PlatformIcon.vue`](../../frontend/src/components/common/PlatformIcon.vue) | 新品牌 logo 的显式 SVG；未增加时会使用 generic fallback，不应让图标遗漏阻断基本功能。 |
| [`frontend/src/utils/platformColors.ts`](../../frontend/src/utils/platformColors.ts) | 专属颜色映射；未加入平台会使用 neutral default。新增完整 UI 表现时更新枚举、badge/light/border 等表，并保证 record key 集合一致。 |
| `frontend/src/components/account/*` 与 `frontend/src/views/admin/*` | 账号编辑、平台筛选、渠道列表、分组模型/平台控件中是否有显式判断。按平台 ID 搜索并逐个判断是展示、授权还是业务逻辑。 |
| `frontend/src/i18n/locales/{en,zh}/...` | 若新平台带专属表单、错误、帮助文本或计划/模式 label，更新中英文键；仅 catalog display name 的情况不一定需要 i18n。 |

`PlatformIcon` 的未知平台 fallback 与 `platformColors` 的 server-only fallback 让动态 catalog 尽量可显示，但账号创建主选择控件并非完全由 catalog 自动生成。不能只更新 JSON 就认为用户能创建新平台账号。

## 6. 常见“平台能选但不能用”的坑

1. **只添加常量/目录项**：group 和 quota 校验可能通过，但账号表单、上游 endpoint、auth header、model sync 都未实现。
2. **错误复用 OpenAI gateway**：payload 表面相似但 Responses/Chat Completions 参数、SSE event、模型字段、认证 header、路径版本不一致。
3. **上游 base URL 拼接错误**：配置值可能是 origin、`/v1`、`/api/v4` 或协议专属 base。重复追加 `/v1` 或漏 `/models`、`/responses` 会导致连接失败。覆盖官方 URL 和自定义 URL 两种测试。
4. **默认模型测试会扣费**：连接测试默认模型要选轻量、低成本、无副作用模型，并确认不要执行昂贵图片/视频生成。
5. **多协议 adaptive 过度宣称**：profile 声明了某协议，就会让通用转发尝试它；只在上游实测支持时添加。确认协议回退不吞掉不兼容 payload。
6. **前端 JSON 未生成**：运行时接口在线时可能看起来正常，但页面首次加载、API 失败或测试环境仍依赖 builtin JSON。
7. **模式只加在 UI**：`account_mode` 的默认、后端 profile、使用额度探测和账号编辑回显必须一致；未经支持的 mode 应明确定义 fallback 或拒绝。
8. **`CNProvider` 标签滥用**：会改变国产余额/额度/UI 分支，而不只是显示一个分类标签。
9. **只改调度、不改 quota/usage**：请求转发正常，但管理页额度、用户平台用量、自动停调、收入/成本统计仍会错误。
10. **遗漏模型同步/定价能力判断**：按钮可见但上游不支持 `/models`，或 LiteLLM provider 名映射错误。
11. **遗漏凭证脱敏**：账号列表/导出/审计/错误日志可能把 API key、refresh token 或 OAuth client secret 暴露。
12. **OAuth 缓存失效遗漏**：token refresh 成功但缓存 key 未清理，后续请求继续用旧 token。
13. **平台 alias 不兼容**：账号、分组、quota、Composite route 和请求日志使用不同 ID，造成 scheduler 找不到账号或数据统计分裂。
14. **同名模型平台歧义**：Composite fallback 猜到旧平台，导致新 provider 的账号不可路由或意外越权路由；加 ambiguous model 测试。
15. **把平台加入 quota 不等于用户已得到平台额度**：平台额度设置与 usage 记录平台键、预算窗口、reset semantics、UI 展示必须一致。
16. **迁移策略不清楚**：新 ID 的版本发布不能自动把历史别名数据变成新平台；若要迁移既有账号/分组/日志，需要幂等、可回滚的数据迁移，而不是只加平台清单。

## 7. 推荐开发步骤

### 阶段 1：整理 provider contract

先写一页实现前检查（可作为 issue 描述，不一定另建文件）：

- 官方 API 文档中的 host、path、HTTP method、auth scheme、请求/响应格式；
- streaming/SSE 格式、错误 envelope、retry-after / rate limit headers；
- 可用 account type 与 token 生命周期；
- Models endpoint、pagination、模型 metadata、轻量 test model；
- usage/balance/subscription quota API、窗口/reset timezone；
- 平台是否有图像、音频、视频、tool call、reasoning、cache 等能力；
- API key 与数据是否有区域/组织/项目隔离要求；
- `platform ID`、展示名、gateway family、是否多协议以及 model protocol routing 策略。

### 阶段 2：实现最小后端闭环

1. domain constants + `platformList`；
2. gateway 分类和 account URL/auth/credentials contract；
3. 账号创建 API 的平台/type 校验和凭证脱敏；
4. scheduler 精确匹配与真实一次请求测试；
5. 配额/计费/usage/错误分类；若不支持某能力，明确表示 unsupported，而不是返回假成功或零余额；
6. 若有 profile，加入 `ProviderProfile` 并验证所有 mode/protocol 组合。

### 阶段 3：前端可用性

1. 更新后端 catalog/profile；
2. 新增或复用账号 create/edit UI；
3. 检查 icon/color/badge、平台筛选、group selector、target selector、model sync 和 pricing sync；
4. 同步 builtin catalog JSON；
5. 测试提交字段、编辑回显、取消/清空字段、错误提示和 key redaction。

### 阶段 4：全仓副作用和生命周期审计

在 `backend/` 搜平台条件与硬编码：

```bash
rg -n 'Platform[A-Z]|platform ==|switch .*platform|case .*Platform' internal
rg -n '"anthropic"|"openai"|"gemini"|"grok"|"kimi"|"deepseek"' internal --glob '*.go'
```

在 `frontend/` 查新旧平台 ID、账号 form 和展示逻辑：

```bash
rg -n 'anthropic|openai|gemini|antigravity|grok|kimi|deepseek|opencode_go' frontend/src
```

每个搜索命中都分类为：通用平台目录、某 gateway 家族、provider 专属能力、历史兼容/迁移、UI 展示。只修改确实要覆盖新平台的行为，不要机械地把所有现有 `switch` 都加新 case。

### 阶段 5：测试与生成

建议按修改面运行：

```bash
cd backend
go test -tags unit ./internal/domain ./internal/service ./internal/handler/... ./internal/server/routes/...
```

针对新增能力追加具体包测试；有 PostgreSQL/Redis 集成依赖时再运行对应 integration suite。平台 catalog 更新时，按测试注释执行：

```bash
UPDATE_PLATFORM_CATALOG=1 go test -tags unit ./internal/service/ -run '^TestFrontendBuiltinPlatformCatalogInSync$'
go test -tags unit ./internal/service/ -run '^TestFrontendBuiltinPlatformCatalogInSync$'
```

第一条会写入 `frontend/src/constants/platformCatalog.builtin.json`，第二条验证代码生成结果一致。改动 Wire provider 时运行项目的生成命令（`make generate`）更新生成代码，不直接编辑 `wire_gen.go`。前端改动运行相应 Vitest、lint 和 type-check。

## 8. 必须覆盖的测试矩阵

| 维度 | 至少覆盖 |
| --- | --- |
| Catalog | ID 唯一、display name 非空、gateway 合法、platform IDs 顺序、composite precedence。 |
| Create/edit account | 合法/非法 account type、必要 credential 缺失、URL 默认/自定义、保存/回显、secret redaction。 |
| Scheduling | 指定平台分组只选该平台；Composite 有/无显式路由和模型冲突。 |
| Upstream request | 正确 base/path、auth header、协议、query/body、proxy/TLS profile、请求取消。 |
| Streaming | 首包、分块事件、结束事件、上游断连、客户端取消、usage 与错误传递。 |
| Failover/retry | 认证错误与额度错误分类、不可重试错误不重试、重试不会重复扣费。 |
| Billing/usage | prompt/completion/cache/tool/image 等 token/cost 归属平台一致；计费前置和结算值正确。 |
| Quota/monitor | 无额度源时显式 unsupported；余额、窗口、reset time、冷却和自动暂停正确。 |
| Model catalog/pricing | unsupported 按钮隐藏或给清晰提示；分页/空结果/异常 JSON/模型 metadata 正确。 |
| Cache/ops | cache key 包含正确平台/账号维度；刷新后失效；日志无 secret；统计 SQL 包含新平台。 |
| Frontend | platform selector、icon fallback、badge/color、form validation、i18n、API error。 |

测试不应只断言“请求返回 200”。还要断言实际命中的 account ID、上游完整 URL、授权 header 名、转发协议、记录的 platform、结算 cost、usage total 和 reset timestamp。

## 9. 快速定位/代码地图

| 能力/职责 | 源码位置 |
| --- | --- |
| Platform ID 常量 | [`internal/domain/constants.go:21`](../../backend/internal/domain/constants.go#L21) |
| 平台清单和 gateway family | [`internal/domain/platforms.go:10`](../../backend/internal/domain/platforms.go#L10)、[`platforms.go:37`](../../backend/internal/domain/platforms.go#L37) |
| Concrete/group platform 判断 | [`internal/domain/platforms.go:69`](../../backend/internal/domain/platforms.go#L69) |
| Composite fallback 顺序 | [`internal/domain/platforms.go:110`](../../backend/internal/domain/platforms.go#L110) |
| 服务层平台 aliases、quota/scheduler 列表 | [`internal/service/domain_constants.go:34`](../../backend/internal/service/domain_constants.go#L34)、[`domain_constants.go:130`](../../backend/internal/service/domain_constants.go#L130) |
| 多协议 profile | [`internal/service/provider_profile.go:32`](../../backend/internal/service/provider_profile.go#L32)、[`provider_profile.go:90`](../../backend/internal/service/provider_profile.go#L90) |
| Account 类型/URL/protocol helpers | [`internal/service/account.go:317`](../../backend/internal/service/account.go#L317)、[`account.go:1509`](../../backend/internal/service/account.go#L1509)、[`account.go:1554`](../../backend/internal/service/account.go#L1554) |
| Account create contract | [`internal/service/account_service.go:177`](../../backend/internal/service/account_service.go#L177)、[`account_service.go:226`](../../backend/internal/service/account_service.go#L226) |
| Admin platform validator | [`internal/handler/admin/platform_validation.go`](../../backend/internal/handler/admin/platform_validation.go) |
| OpenAI family scheduling normalize | [`internal/service/openai_gateway_scheduling.go:294`](../../backend/internal/service/openai_gateway_scheduling.go#L294) |
| 上游 models request builder | [`internal/service/upstream_models.go:904`](../../backend/internal/service/upstream_models.go#L904) |
| Channel monitor capability 和 fetch | [`internal/service/channel_monitor_validate.go:218`](../../backend/internal/service/channel_monitor_validate.go#L218)、[`channel_monitor_quota_fetcher.go:201`](../../backend/internal/service/channel_monitor_quota_fetcher.go#L201) |
| Token cache invalidation | [`internal/service/token_cache_invalidator.go:24`](../../backend/internal/service/token_cache_invalidator.go#L24) |
| Account model rate limit special cases | [`internal/service/model_rate_limit.go:66`](../../backend/internal/service/model_rate_limit.go#L66) |
| Quota DB string validation | [`ent/schema/user_platform_quota.go:38`](../../backend/ent/schema/user_platform_quota.go#L38) |
| Catalog generated for frontend | [`internal/service/platform_catalog.go:45`](../../backend/internal/service/platform_catalog.go#L45) |
| Catalog sync generator test | [`internal/service/platform_catalog_test.go:123`](../../backend/internal/service/platform_catalog_test.go#L123) |
| Frontend platform options | [`frontend/src/constants/platformCatalog.ts:79`](../../frontend/src/constants/platformCatalog.ts#L79)、[`platforms.ts:17`](../../frontend/src/constants/platforms.ts#L17) |
| Frontend account create provider selection | [`frontend/src/components/account/CreateAccountModal.vue:72`](../../frontend/src/components/account/CreateAccountModal.vue#L72) |
| Frontend credential serialization/profile behavior | [`frontend/src/components/account/credentialsBuilder.ts:254`](../../frontend/src/components/account/credentialsBuilder.ts#L254) |
| Platform icon and unknown fallback | [`frontend/src/components/common/PlatformIcon.vue`](../../frontend/src/components/common/PlatformIcon.vue) |
| Platform colors and neutral fallback | [`frontend/src/utils/platformColors.ts`](../../frontend/src/utils/platformColors.ts) |

## 10. 深入审查补充：容易漏掉的横切面

平台登记和请求转发能跑通，不代表这个平台已完整接入。继续沿账号数据、配置与统计链路审查后，还应检查以下容易被“主路径测试”遗漏的地方。

### 10.1 平台能力并非全部由平台目录自动推导

`domain` 平台目录确实能派生部分清单，但不少产品能力刻意采用小范围白名单或 `switch`，需要按平台实际能力逐个决策，不能把平台 ID 简单追加到所有列表。

| 能力面 | 当前实现/默认行为 | 新平台接入时要做的判断 |
| --- | --- | --- |
| 用户平台额度 | `AllowedQuotaPlatforms` 从具体平台目录派生；系统默认平台额度也遍历该列表。见 [`domain_constants.go:130`](../../backend/internal/service/domain_constants.go#L130)、[`setting_features.go:1117`](../../backend/internal/service/setting_features.go#L1117)。 | 额度可按平台计量不等于平台有上游额度 API。验证额度配置、预扣/后扣、reset 语义和计费平台是否一致。 |
| 调度阈值 | 平台列表是独立白名单，按平台的窗口额度能力选取，不是所有平台自动开启。见 [`domain_constants.go:137`](../../backend/internal/service/domain_constants.go#L137)、[`account_scheduling_threshold_eval.go:55`](../../backend/internal/service/account_scheduling_threshold_eval.go#L55)。 | 只有上游提供可靠用量窗口或余额信号时才加入；定义窗口重置、阈值含义、缺数据策略和恢复条件。 |
| Scheduler snapshot | 快照桶基于 `CompositePrecedencePlatformIDs()` 建立，每个 concrete platform 至少有 single/forced 模式，部分平台另有 mixed 模式。见 [`scheduler_snapshot_service.go:829`](../../backend/internal/service/scheduler_snapshot_service.go#L829)、[`scheduler_snapshot_service.go:849`](../../backend/internal/service/scheduler_snapshot_service.go#L849)。 | 确认新平台出现在 canonical precedence 清单及生命周期事件重建路径；扩展后验证旧快照清理、启动重建和未知平台回退。 |
| 默认模型候选 | 按平台分派到不同的静态模型清单，未显式支持的分支会落入默认 provider 候选。见 [`admin_group.go:280`](../../backend/internal/service/admin_group.go#L280)。 | 添加官方默认模型来源；检查空列表、模型映射和 group 初始模型，否则管理端下拉框可能显示错误平台模型。 |
| 简单模式默认分组 | 启动时仅为指定平台创建默认组，当前清单不是从 concrete platform 自动生成。见 [`simple_mode_default_groups.go:14`](../../backend/internal/repository/simple_mode_default_groups.go#L14)、[`simple_mode_default_groups.go:25`](../../backend/internal/repository/simple_mode_default_groups.go#L25)。 | 判断简单模式是否承诺该平台开箱可用；如是，加入默认组初始化及幂等/并发启动测试。 |
| 兜底模型 | 目前仅 OpenAI、Anthropic、Gemini、Antigravity 有独立兜底模型配置；其他平台返回空值。见 [`setting_features.go:651`](../../backend/internal/service/setting_features.go#L651)。 | 明确 fallback 是否适用于该 provider、配置项和默认值；还要验证模型替换不会跨越平台或协议。 |
| 图片/批量图片 | 新建 group 的图片能力默认值和批量图片门槛是不同判断；批量图片目前仅 Gemini。见 [`admin_group.go:318`](../../backend/internal/service/admin_group.go#L318)、[`admin_group.go:536`](../../backend/internal/service/admin_group.go#L536)。 | 根据上游端点能力分别设置，不要因平台支持普通图片就默认开启批量生成。 |
| 利润控制 | 利润控制只允许有限平台，其他平台会被规范化为关闭。见 [`group.go:449`](../../backend/internal/service/group.go#L449)、[`group.go:464`](../../backend/internal/service/group.go#L464)。 | 验证成本/售价来源和计价单位后再加入；仅增加 UI 开关不会让后端生效。 |
| OpenAI 专有 group 能力 | fast mode、Codex、reasoning 等 group 操作对平台有独立限制。见 [`admin_group.go:364`](../../backend/internal/service/admin_group.go#L364)、[`admin_group.go:642`](../../backend/internal/service/admin_group.go#L642)、[`openai_reasoning_effort_policy.go:141`](../../backend/internal/service/openai_reasoning_effort_policy.go#L141)。 | 复用 OpenAI gateway 并不自动意味着可复用 Codex/fast/reasoning 的账号语义；确认账号凭证和上游能力一致再扩展白名单。 |

平台额度清单、调度阈值、快照平台、默认模型、默认分组和 fallback 是不同目的的集合。新增平台时应分别回答“是否需要此能力”，而不是维护一个看似通用的 `all platforms` 列表。

### 10.2 Composite 路由与模型推断是独立契约

Composite 组要把请求映射到具体 provider。系统可从已知模型名前缀推断平台，但未知/歧义模型会返回未识别，避免猜测路由；显式 Composite 路由则携带目标平台、上游模型和 endpoint。参考 [`composite_platform.go:91`](../../backend/internal/service/composite_platform.go#L91)、[`admin_group.go:256`](../../backend/internal/service/admin_group.go#L256)。

新平台的模型 ID 若可能通过 Composite 暴露，必须决定是：

1. 通过显式路由配置目标平台和上游模型；还是
2. 将稳定且无歧义的公共模型前缀加入推断，并为大小写、`provider/model`、模型别名和冲突增加测试。

同时检查 `WithCompositeRouteDecision` 写入的 resolved platform 是否贯穿到用量归因、用户平台额度、后扣和日志。`QuotaPlatform()` 会优先使用请求上下文里解析出的 concrete platform，见 [`composite_platform.go:35`](../../backend/internal/service/composite_platform.go#L35)、[`gateway_usage_billing.go:108`](../../backend/internal/service/gateway_usage_billing.go#L108)。Usage analytics 的 SQL 又有自己的有效平台表达式，Composite 分组按账号平台统计，见 [`usage_log_repo.go:32`](../../backend/internal/repository/usage_log_repo.go#L32)。必须用实际的 Composite 请求验证账单、quota 和报表一致，而不只是验证路由成功。

### 10.3 凭证安全是“存储、返回、更新、备份”四条链

| 生命周期 | 行为 | 新平台应检查 |
| --- | --- | --- |
| 存储清洗 | `SanitizeStoredCredentials()` 删除 password、SSO 和 cookie 等不应持久化的值。见 [`credentials_sanitize.go:3`](../../backend/internal/service/credentials_sanitize.go#L3)。 | 若 OAuth 换取 token 后还有一次性密码、cookie、授权码或 session jar，必须在创建、更新、导入、OAuth apply 等所有入口清理。 |
| API 响应脱敏 | `SensitiveCredentialKeys` 驱动 DTO 脱敏和敏感字段合并；前端缺失敏感字段时更新不会误删已存值。见 [`account_credentials_redact.go:5`](../../backend/internal/service/account_credentials_redact.go#L5)、[`account_credentials_redact.go:26`](../../backend/internal/service/account_credentials_redact.go#L26)、[`credentials_redact.go:11`](../../backend/internal/handler/dto/credentials_redact.go#L11)。 | 新凭证字段若不是已知通用 key，检查所有列表/详情/自定义管理员 DTO、审计日志和全量 PUT 更新合并；不能只隐藏表单输入框。 |
| 管理员备份 | Account 导出有意包含 credentials 原文，是敏感的完整备份行为。见 [`account_data.go:54`](../../backend/internal/handler/admin/account_data.go#L54)、[`account_data.go:100`](../../backend/internal/handler/admin/account_data.go#L100)。 | 导出文件应按密钥材料保护；新增平台的凭证结构须保证导入/导出往返。不要把备份 JSON 附在 issue、聊天记录或日志里。 |
| 导入/重建 | 导入校验只接受 OAuth、Setup Token、API Key、Upstream 四种类型；OpenAI OAuth 的 ID token enrichment、Antigravity 隐私设置等也是平台专用后处理。见 [`account_data.go:682`](../../backend/internal/handler/admin/account_data.go#L682)、[`account_data.go:723`](../../backend/internal/handler/admin/account_data.go#L723)、[`account_data.go:464`](../../backend/internal/handler/admin/account_data.go#L464)。 | 若新平台需要 Bedrock/Service Account 等新 account type，或者有导入后的验证、隐私、探测动作，更新备份格式/校验/副作用及对应测试。 |
| Token cache | OAuth refresh token 缓存删除使用单独的 invalidation 分派。见 [`token_cache_invalidator.go:24`](../../backend/internal/service/token_cache_invalidator.go#L24)。 | 明确 token cache namespace、账号删除/换 token/重新授权后的失效方式；否则可能继续使用旧凭证。 |

“敏感值不会返回 API”与“管理员备份不包含敏感值”并非同一个承诺。平台作者要核对产品预期，并保持创建、更新、重授权、导入、编辑、日志和导出的语义一致。

### 10.4 产品级 side effects 和共享配置也要评估

- **账户导入不是任意 account type 的通用还原器。** 上述类型限制意味着即使服务本身已支持某种账号类型，备份导入也可能拒绝它。增加新类型时补往返测试；不要因 `platform` 字段只是非空校验就误认为任意平台/类型组合均有效。
- **模型 fallback、定价和模型同步互不等价。** Default model candidate、上游 model sync、LiteLLM provider 映射、平台 pricing-sync capability 是不同入口。新增平台要分别决定是否有官方模型列表、pricing provider、自动同步及用户自定义映射；未支持时 UI 应禁用/说明，而不是返回空成功。
- **quota 与上游余额监控不同。** 用户 platform quota 是本项目的计费/访问限制；channel monitor 和账号 quota 是从上游读取余额/窗口。对没有可靠额度源的平台明确标为 unsupported，不要伪造 0 余额或复用别的平台 reset 规则。
- **导入后异步任务可能平台专用。** 例如隐私设置、quota probe、上游账单/计划探测；新增平台若有副作用，处理超时、并发、代理、失败记录和重复导入。
- **增删改平台时验证未知值行为。** 平台目录通常用于识别和展示，但数据库旧记录、未知平台和迁移数据仍可能存在。保证 unknown provider 有可理解的错误/中性展示，不要因默认 `switch` 分支误判成 Anthropic 或任一已知 provider。
- **产品设置要拆开检验。** 全局默认平台额度按 concrete ID 派生，但 fallback、自动停调、利润控制、图像能力等是独立策略。管理页配置可保存不等于运行时服务实际读取该配置。

### 10.5 新增平台的最终遗漏审计

在准备合并前，对以下每项记录“支持 / 明确不支持 / 暂不适用”，而不是只写“已接入”：

- [ ] 平台目录：ID、显示名、gateway family、provider profile、协议和模型发现入口。
- [ ] Account：合法 account type 组合、必填凭证、base URL、endpoint、代理/TLS、token refresh 和删除。
- [ ] 凭证：存储清洗、DTO/审计脱敏、敏感字段编辑合并、备份导入/导出。
- [ ] 路由：单平台、强制路由、Composite 显式/推断路由、model mapping 和失败/重试语义。
- [ ] 计费：模型价格、token/tool/image 计量、折扣、用户平台 quota、usage log 归因和 SQL 聚合。
- [ ] 调度：账号候选过滤、阈值/冷却、scheduler snapshot 初始化与失效、并发边界。
- [ ] 上游状态：channel monitor capability/fetch、账号额度、reset time、计划/账单 probe、自动暂停。
- [ ] 管理端：create/edit/test/re-auth、model/pricing sync、账号详情/列表、quota 和 monitor 展示。
- [ ] 产品策略：简单模式默认组、默认模型、fallback、平台额度配置、利润控制、图像/批量图像和专有 group 开关。
- [ ] 可观测性：错误分类、请求 ID、平台标签、审计日志、指标、未知平台告警和 secret redaction。
- [ ] 测试与兼容：单测、路由/计费集成测试、catalog 同步、导入导出往返、迁移/旧数据及真实上游 sandbox。

检查时可从这些横切词再搜索一次，而不只搜平台 ID：

```bash
rg -n 'platform|Platform|credentials|quota|fallback|snapshot|monitor|pricing|export|import' backend/internal/service backend/internal/repository backend/internal/handler/admin
rg -n 'platform|Platform|quota|monitor|pricing|credentials|reauth|fallback' frontend/src
```

第二轮搜索的关键是逐项分类命中：通用平台目录、协议/gateway 家族能力、平台专有能力、数据迁移/历史兼容、仅 UI 展示。仅当语义适配时才加新平台，避免扩大原本故意受限的能力范围。
