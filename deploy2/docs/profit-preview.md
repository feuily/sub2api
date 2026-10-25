# `backend/cmd/profit-preview`

`profit-preview` 用本地 JSON 数据调用生产共用的 `PreviewProfitAdmission` 逻辑，离线预演分组利润门对账号和模型的准入影响。它不连接生产数据库、不修改分组，也不调用上游。源码与测试：

- [`main.go`](../../backend/cmd/profit-preview/main.go)
- [`main_test.go`](../../backend/cmd/profit-preview/main_test.go)
- 共用判定实现：[`internal/service/profit_preview.go`](../../backend/internal/service/profit_preview.go)

## 运行

在 `backend/` 目录执行：

```bash
go run ./cmd/profit-preview --input ./profit-preview-input.json

# 假定当前关闭的、支持利润控制的平台分组会按保存配置启用利润门
go run ./cmd/profit-preview --input ./profit-preview-input.json --assume-enabled

# 输出完整 JSON 报告，便于后续程序处理
go run ./cmd/profit-preview --input ./profit-preview-input.json --json > ./profit-preview-report.json
```

`--json` 写 JSON 到 stdout，错误写 stderr。默认是面向人工查看的表格。`--input` 缺失、JSON 不合法、没有分组或分组缺少必需字段时以非零状态退出。

## 参数

| 参数 | 必需 | 作用 |
| --- | --- | --- |
| `--input FILE` | 是 | 输入 JSON 文件路径。 |
| `--assume-enabled` | 否 | 当前关闭的受支持平台分组也按保存的利润配置计算。用于“先关组、预演、逐组重开”类部署评估。 |
| `--json` | 否 | 输出带缩进的 JSON 报告；默认输出可读表格。 |

## 输入格式

顶层必须包含非空 `groups` 数组。每个数组元素是一组分组配置、已筛选账号、用户倍率覆盖和模型清单：

```json
{
  "groups": [
    {
      "group": {
        "id": 10,
        "name": "OpenAI 标准组",
        "platform": "openai",
        "rate_multiplier": 0.8,
        "subscription_type": "standard",
        "profit_control_enabled": true,
        "profit_min_margin": 0.1,
        "profit_safety_buffer": 0.02,
        "peak_rate_enabled": false,
        "peak_start": "",
        "peak_end": "",
        "peak_rate_multiplier": 1
      },
      "accounts": [
        {
          "id": 101,
          "name": "账号 A",
          "platform": "openai",
          "type": "apikey",
          "rate_multiplier": 0.5,
          "extra": {},
          "model_mapping": {}
        }
      ],
      "user_overrides": {
        "2001": 0.6,
        "2002": null
      },
      "models": ["gpt-example"]
    }
  ]
}
```

字段与处理规则：

- `group.id` 必须大于 0；`group.platform` 必须非空。其余利润与峰值配置应与目标分组真实保存值一致。
- 输入结构不包含分组状态字段；工具会把传入分组视为 active。不要把它用来模拟停用/删除分组的调度效果。
- `accounts` 应只放入目标分组中绑定且状态可调度的账号。账号 `rate_multiplier` 可为 `null`，此时是无效倍率，不要用 `0` 代替“未配置”。
- `extra` 用于反映上游计费倍率同步/探测元数据。探测状态仅产生解释性 warning，不改变准入结论。
- `model_mapping` 是模型名映射；会被装入账号 credentials 以复用 `IsModelSupported` 判定。
- `user_overrides` 的 key 是十进制用户 ID 字符串，值是倍率；`null` 和无效用户 ID 会被忽略。至少提供实际存在的低倍率覆盖，才能得到有意义的最坏情况 D。
- `models` 是该组近期主力模型清单。报告的剩余账号数只统计利润门准入且支持该模型的账号，不模拟健康状态、冷却、限流或并发槽位。

输入应来自经过审查的**只读、最小化导出**。本工具不需要账号密码、OAuth token、API key、数据库 DSN 或完整账号 credentials；不要把这些秘密复制进导出 JSON。

## 判定口径

程序在运行时使用当前时间，因此峰值倍率可能影响这次结果。对分组：

```text
peak = group.PeakMultiplierAt(运行时刻)
default D = group.rate_multiplier × peak
minimum D = min(group.rate_multiplier, 所有有效用户覆盖倍率) × peak
deduction = profit_min_margin + profit_safety_buffer
threshold = clamp(D × (1 - deduction))
```

账号倍率记为 `U`。利润门实际生效时，账号倍率必须有效，且不超过相应阈值（线上共享 epsilon 语义）；超出阈值时归类为 `rejected_threshold`，缺失/非法倍率归类为 `rejected_invalid_account_rate`。未生效的门按准入处理。平台是否支持及 Composite 分组行为由共享服务代码决定，不要在导出侧自行近似重算。

报告同时给出：

- 默认 D 下和最低有效 D 下的阈值、账号判定及模型准入账号数。
- 账号倍率来源（手工或上游探测同步）和探测告警。
- `rejected_under_min_d`：默认 D 下可准入、但在最低有效 D 用户覆盖下会被排除的账号。
- 默认 D 下无可用账号的模型，以及仅在最低 D 情况下归零的模型告警。

## 建议工作流

1. 从目标环境读取配置，构造只读最小 JSON；记录导出时间和环境，不包含秘密。
2. 先按真实启用状态运行；再按计划评估 `--assume-enabled` 场景。
3. 人工审查准入/拒绝数量、模型归零和探测告警，结合健康度、限流及容量做额外评估。
4. 本工具只产生预演报告；上线配置仍须通过管理界面/API 和变更流程操作。
