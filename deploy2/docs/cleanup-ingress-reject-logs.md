# `backend/cmd/cleanup-ingress-reject-logs`

这是一次性维护命令，用于从 PostgreSQL `ops_error_logs` 清理满足特定条件的历史 ingress/auth 入站拒绝记录。默认只做 dry-run 统计，不删除数据。详细原始说明见 [`backend/cmd/cleanup-ingress-reject-logs/README.md`](../../backend/cmd/cleanup-ingress-reject-logs/README.md)。

源码与测试：

- [`main.go`](../../backend/cmd/cleanup-ingress-reject-logs/main.go)
- [`main_test.go`](../../backend/cmd/cleanup-ingress-reject-logs/main_test.go)

## 运行

从 `backend/` 目录执行。`--before` 必须提供 RFC3339 时间：

```bash
# 第一步必须 dry-run：只扫描和分类，不删除
go run ./cmd/cleanup-ingress-reject-logs \
  --before 2026-07-17T00:00:00Z

# 确认扫描/匹配数据量、截止时间及上线窗口后，才显式执行删除
go run ./cmd/cleanup-ingress-reject-logs \
  --before 2026-07-17T00:00:00Z \
  --execute
```

日期示例仅用于展示格式。请按真实维护窗口选择 cutoff；`created_at < before` 才符合时间条件，恰好等于 cutoff 的记录不会被处理。

## 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--before RFC3339` | 无，必需 | 只处理该时刻之前的候选记录。例：`2026-07-17T00:00:00Z`。 |
| `--execute` | false | 真正删除分类命中的记录；不提供时是只读 dry-run。 |
| `--batch-size N` | `5000` | 每批扫描/删除大小，范围 `1` 到 `5000`。 |

Go 标准 flag 支持 `-before` / `--before` 等形式。配置从后端 bootstrap config 加载；命令通过 `repository.InitEnt` 初始化 PostgreSQL 客户端，要求数据库可连接并能读取/删除目标日志。注意：`InitEnt` 会自动应用待执行的数据库迁移，所以运行清理工具并非只有 DELETE 这一项数据库影响；先确认目标配置、迁移及备份。

## 实际筛选范围

数据库查询先限定候选行：

- `ops_error_logs.id` 按游标递增分批扫描；
- `created_at < --before`；
- `error_phase = 'auth'`；
- `account_id IS NULL`；
- `upstream_status_code IS NULL`；
- `upstream_error_message` 和 `upstream_error_detail` 为空。

对候选的 `error_body` JSON（错误 code 取顶层 `code`；message 依次取顶层 `message`、`error.message`）和 fallback `error_message` 进行精确分类。当前可删除的拒绝类别包括：

| 输出 reason | 识别的 code/典型消息 |
| --- | --- |
| `missing_key` | `API_KEY_REQUIRED` / `API key is required` |
| `invalid_key` | `INVALID_API_KEY` / `Invalid API key` |
| `key_disabled` | `API_KEY_DISABLED` / `API key is disabled` |
| `user_inactive` | `USER_INACTIVE` / `User account is not active` |
| `group_deleted` | `GROUP_DELETED` / `API Key 所属分组已删除` |
| `group_disabled` | `GROUP_DISABLED` / `API Key 所属分组已停用` |
| `group_forbidden` | `GROUP_NOT_ALLOWED` / API Key 所属专属分组不再允许当前用户使用 |
| `group_unassigned` | 对应的“API Key is not assigned to any group…”完整消息 |
| `ip_acl_denied` | `ACCESS_DENIED` / 以 `Access denied. Your IP is ` 开头的消息 |
| `query_key_deprecated` | `api_key_in_query_deprecated` / query 参数 api_key 已弃用消息 |

分类器不匹配的行保留。特别是 `USER_NOT_FOUND`、数据库故障、额度/计费错误和上游错误并不属于本清理范围；测试 [`main_test.go`](../../backend/cmd/cleanup-ingress-reject-logs/main_test.go) 对这些保留行为有保护。

## 输出和安全操作流程

每次运行会输出模式、UTC cutoff、分类器摘要、扫描/匹配/删除条数，以及按 reason 汇总：

```text
mode=dry-run before=... classifier=... scanned=... matched=... deleted=0
reason=invalid_key count=...
```

执行删除后，若有记录被删除，会提示在正常维护时安排 `VACUUM (ANALYZE) ops_error_logs`。删除不会自动 vacuum，也不会清理其他历史数据。

生产执行前：

1. 先备份数据库，并在目标环境用正确的 `DATA_DIR`/配置运行 dry-run。
2. 确认**所有应用实例已升级**，避免旧版本在 cutoff 之前仍写入新的同类记录。
3. 审查 cutoff、`matched` 总数和 reason 分布；输出与预期不符时不要加 `--execute`。
4. 在维护窗口执行 `--execute`，确认 `deleted` 数量。
5. 只有完成 rollout 和清理验证后，才按原 README 的独立流程评估 [`finalize-ingress-reject-cleanup.sql`](../../backend/scripts/finalize-ingress-reject-cleanup.sql)。该 SQL 是另一个可能移除历史 audit 数据/列的操作，不由此命令自动运行。

不要把该命令当作通用日志清理工具；它只针对上述严格定义的历史拒绝记录。
