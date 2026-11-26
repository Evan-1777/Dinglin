# Dinglin 外部接入指南

本文档面向第三方业务系统、CI/CD 流水线与 AI Agent 开发者，说明如何通过 Webhook、REST API、签名回执回调与 MCP（Model Context Protocol）接入 Dinglin 服务。

## 1. 系统交互与前置准备

Dinglin 将外部写入权限与客户端持有者权限严格分离。外部系统仅持有绑定单个消息来源（Source）的凭据，无法访问其他来源的数据或设备控制接口。

<div style="margin:16px 0;padding:16px;border:1px solid #d2d2d7;border-radius:10px;background:#ffffff;color:#1d1d1f;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:13px;line-height:1.5;">
  <div style="font-weight:600;margin-bottom:12px;color:#1d1d1f;">外部接入与回执流转架构</div>
  <div style="display:flex;flex-wrap:wrap;gap:10px;align-items:stretch;">
    <div style="flex:1 1 170px;padding:10px 12px;border:1px solid #e5e5ea;border-radius:8px;background:#f5f5f7;">
      <div style="font-weight:600;font-size:12px;color:#6e6e73;">1. 外部发送端</div>
      <div style="margin-top:6px;">CI/CD Webhook<br/>业务系统 REST API<br/>AI Agent MCP 客户端</div>
    </div>
    <div style="display:flex;align-items:center;color:#86868b;font-weight:600;">&#8594;</div>
    <div style="flex:1.2 1 200px;padding:10px 12px;border:1px solid #007aff;border-radius:8px;background:#f5f9ff;">
      <div style="font-weight:600;font-size:12px;color:#007aff;">2. 鉴权与源隔离网关</div>
      <div style="margin-top:6px;">校验 <code>src_*</code> Bearer Token<br/>强制绑定 <code>source_id</code><br/>幂等去重与 SyncEvent 落库</div>
    </div>
    <div style="display:flex;align-items:center;color:#86868b;font-weight:600;">&#8594;</div>
    <div style="flex:1 1 170px;padding:10px 12px;border:1px solid #e5e5ea;border-radius:8px;background:#f5f5f7;">
      <div style="font-weight:600;font-size:12px;color:#6e6e73;">3. 终端触达通道</div>
      <div style="margin-top:6px;">WebSocket 实时推送<br/>FCM 唤醒 / AlarmManager<br/>Android 锁屏闹铃</div>
    </div>
    <div style="display:flex;align-items:center;color:#86868b;font-weight:600;">&#8594;</div>
    <div style="flex:1 1 180px;padding:10px 12px;border:1px solid #e5e5ea;border-radius:8px;background:#f5f5f7;">
      <div style="font-weight:600;font-size:12px;color:#6e6e73;">4. 回执异步投递</div>
      <div style="margin-top:6px;">用户点击确认 / 延后 / 动作<br/>HMAC-SHA256 签名 POST<br/>失败退避重试（5s / 30s / 120s）</div>
    </div>
  </div>
</div>

### 鉴权层级与权限矩阵

<div style="margin:16px 0;padding:16px;border:1px solid #d2d2d7;border-radius:10px;background:#ffffff;color:#1d1d1f;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:13px;line-height:1.5;">
  <div style="font-weight:600;margin-bottom:10px;">两级凭据隔离矩阵</div>
  <table style="width:100%;border-collapse:collapse;font-size:12.5px;">
    <thead>
      <tr style="border-bottom:1px solid #d2d2d7;text-align:left;color:#6e6e73;">
        <th style="padding:8px 10px;">凭据类型</th>
        <th style="padding:8px 10px;">前缀格式</th>
        <th style="padding:8px 10px;">可调用接口范围</th>
        <th style="padding:8px 10px;">隔离边界</th>
      </tr>
    </thead>
    <tbody>
      <tr style="border-bottom:1px solid #ececef;">
        <td style="padding:8px 10px;font-weight:600;">Owner 凭据</td>
        <td style="padding:8px 10px;">Master Key / <code>dev_*</code></td>
        <td style="padding:8px 10px;">来源管理、设备配对、全局同步、回执提交、全局调度与配置</td>
        <td style="padding:8px 10px;">全局持有者权限，不可发放给第三方服务</td>
      </tr>
      <tr style="border-bottom:1px solid #ececef;">
        <td style="padding:8px 10px;font-weight:600;">Webhook Source</td>
        <td style="padding:8px 10px;"><code>src_*</code>（配对 <code>whsec_*</code>）</td>
        <td style="padding:8px 10px;"><code>POST /api/v1/webhook/{slug}</code>、<code>POST /api/v1/notify</code>、<code>GET /api/v1/notifications/{id}/receipts</code></td>
        <td style="padding:8px 10px;">禁止调用 <code>/mcp</code>，仅可查询本来源下发通知的回执</td>
      </tr>
      <tr>
        <td style="padding:8px 10px;font-weight:600;">Agent Source</td>
        <td style="padding:8px 10px;"><code>src_*</code>（<code>kind=agent</code>）</td>
        <td style="padding:8px 10px;">上述 REST / Webhook 接口及 <code>POST /mcp</code>、<code>DELETE /mcp</code></td>
        <td style="padding:8px 10px;">MCP 会话强制绑定 <code>source_id</code>，跨源读写返回拒绝</td>
      </tr>
    </tbody>
  </table>
</div>

### 接入前准备

1. **检查网关连通性**：调用健康检查端点确认服务可用。

```bash
curl -fsS https://dinglin.example.com/healthz
# {"status":"ok","version":"..."}
```

2. **创建消息来源**：在客户端「设置 → 消息来源」右上角新建来源，或使用 Owner 凭据调用管理接口。创建成功后响应体将**一次性**返回完整 `token`（`src_*`）与 `callback_secret`（`whsec_*`）；若凭据遗失，可通过「轮换 Token」重新签发，旧 Token 即刻失效。

- `slug` 约束：匹配正则 `^[a-z0-9][a-z0-9_-]{0,62}$`。
- `kind` 类型：通用服务或流水线选择 `webhook`；需要接入 MCP 工具集的 AI Agent 选择 `agent`。

---

## 2. Webhook 快速接入

适用场景：GitHub Actions、GitLab CI、Prometheus Alertmanager、Grafana 等现成系统，无法自定义标准载荷结构时直接投递。

### 端点与鉴权

- 端点：`POST /api/v1/webhook/{slug}`
- 请求体上限：`1 MiB`，空请求体返回 `400 empty_body`。
- 鉴权方式（二选一）：
  - 请求头：`Authorization: Bearer <src_token>`
  - URL Query 参数：`?token=<src_token>`（仅建议在平台不支持自定义 Header 时使用）
- 匹配校验：Token 对应的来源必须处于启用状态（否则 `403 source_disabled`）且与路径 `{slug}` 一致（否则 `403 slug_mismatch`）。

### 字段自动映射规则

当请求体为合法 JSON 对象（以 `{` 开头且解析成功）时，网关按以下优先级提取字段；未命中则回退为来源名称与原始文本：

| 目标字段 | 候选 JSON 键（按顺序取第一个非空字符串） | 回退或归一化规则 |
|---|---|---|
| `title` | `title`、`summary`、`subject`、`event` | 若上述均为空，则以来源 `name` 填充 |
| `body` | `body`、`message`、`text`、`description`、`content` | 允许为空 |
| `priority` | `priority`、`severity`、`level` | `critical/urgent/high/error/fatal/p0` → `critical`；`silent/low/debug/info` → `silent`；其余 → `normal` |
| `category` | `category`、`type` | 允许为空 |
| `callback_url` | `callback_url` | 允许为空（若为空则在回执阶段继承来源默认 `callback_url`） |
| `actions` | `actions` | 对象数组：`[{id, label, style?, payload?}]` |
| `metadata` | `metadata` | JSON 对象 |
| `idempotency_key` | Header `Idempotency-Key` 优先，其次 JSON `idempotency_key` | 同一 `source_id` 下命中相同键直接去重 |

若请求体为纯文本而非 JSON（如 `curl -d "Backup finished"`），网关会将 `title` 设为来源名称、`body` 设为请求体全文、`priority` 设为 `normal`。

### Webhook cURL 示例

```bash
# 1. 投递结构化告警 JSON
curl -X POST "https://dinglin.example.com/api/v1/webhook/github-ci" \
  -H "Authorization: Bearer src_your_source_token" \
  -H "Idempotency-Key: run-98421-failed" \
  -H "Content-Type: application/json" \
  -d '{
    "event": "main 分支构建失败",
    "message": "Go 单元测试 TestReceiptCallback 超时退出",
    "severity": "high",
    "actions": [
      {"id": "ack", "label": "确认排查"}
    ]
  }'

# 2. 纯文本直推（使用 Query Token）
curl -X POST "https://dinglin.example.com/api/v1/webhook/cron-backup?token=src_your_source_token" \
  -H "Content-Type: text/plain" \
  -d "pg_dump 每日冷备完成，归档大小 4.2 GiB"
```

---

## 3. 标准 REST API 接入

当发送方由自研程序控制时，推荐直接调用标准通知接口以使用过期时间、幂等控制与完整动作按钮。

### 发送通知：`POST /api/v1/notify`

请求头须携带 `Authorization: Bearer <src_token>` 与 `Content-Type: application/json`，可选携带 `Idempotency-Key`（存在时覆盖 JSON 中的同名字段）。

| 参数名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `title` | `string` | 是 | 通知标题，去除首尾空白后不能为空 |
| `body` | `string` | 否 | 通知正文 |
| `priority` | `string` | 否 | `silent`、`normal`（默认）或 `critical`（强提醒，穿透免打扰并可在 Android 触发全屏闹铃） |
| `category` | `string` | 否 | 自定义业务分类标签 |
| `actions` | `array` | 否 | 快捷回执动作数组，每项包含 `id`、`label` 及可选 `style`、`payload` |
| `expires_at` | `string` | 否 | RFC3339 格式过期时间；优先级高于 `expires_in_sec` |
| `expires_in_sec` | `integer` | 否 | 从服务端接收时刻起计算的过期秒数（大于 0） |
| `callback_url` | `string` | 否 | 单条通知级别的回执回调地址，覆盖来源默认配置 |
| `metadata` | `object` | 否 | 透传的键值元数据，客户端详情侧栏会展示并支持复制 |
| `idempotency_key` | `string` | 否 | 幂等去重键（同一来源下唯一） |

响应语义：
- 首次创建返回 HTTP `201 Created`，`{"notification": { ... }, "deduplicated": false}`。
- 命中相同 `(source_id, idempotency_key)` 返回 HTTP `200 OK`，`{"notification": { ... }, "deduplicated": true}`，不会重复推送或追加同步事件。

### 查询通知回执：`GET /api/v1/notifications/{id}/receipts`

使用同源 `src_*` Bearer Token（或 Owner Token）拉取某条通知下的全部用户动作记录。若当前 `src_*` Token 尝试查询其他来源创建的通知，接口返回 `403 forbidden`。

响应体为 `{"receipts": [ { "id", "notification_id", "device_id", "action_id", "action_label", "payload", "created_at" } ]}`。

### 多语言接入示例（零第三方依赖）

```bash
curl -X POST "https://dinglin.example.com/api/v1/notify" \
  -H "Authorization: Bearer src_your_source_token" \
  -H "Idempotency-Key: deploy-prod-20261126-01" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "生产环境发布审批",
    "body": "订单服务 v2.4.1 已通过预发回归，等待确认发布",
    "priority": "critical",
    "category": "release",
    "expires_in_sec": 3600,
    "actions": [
      {"id": "approve", "label": "批准发布"},
      {"id": "reject", "label": "暂缓"}
    ],
    "metadata": {"service": "order-api", "commit": "8c31f0a"}
  }'
```

```go
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

func sendDinglin(endpoint, token string) error {
	payload := map[string]any{
		"title":           "生产环境发布审批",
		"body":            "订单服务 v2.4.1 已通过预发回归",
		"priority":        "critical",
		"idempotency_key": "deploy-prod-20261126-01",
		"actions": []map[string]string{
			{"id": "approve", "label": "批准发布"},
			{"id": "reject", "label": "暂缓"},
		},
	}
	raw, _ := json.Marshal(payload)

	req, err := http.NewRequest(http.MethodPost, endpoint+"/api/v1/notify", bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status: %d", resp.StatusCode)
	}
	return nil
}
```

```python
import json
import urllib.request

def send_dinglin(base_url: str, token: str) -> dict:
    payload = {
        "title": "数据库主从延迟告警",
        "body": "replica-02 复制延迟 14 秒",
        "priority": "critical",
        "idempotency_key": "db-lag-replica02-20261126",
        "actions": [{"id": "ack", "label": "已介入"}],
    }
    req = urllib.request.Request(
        url=f"{base_url.rstrip('/')}/api/v1/notify",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))
```

```javascript
async function sendDinglin(baseUrl, token) {
  const res = await fetch(`${baseUrl.replace(/\/+$/, "")}/api/v1/notify`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": "application/json",
      "Idempotency-Key": "job-sync-20261126",
    },
    body: JSON.stringify({
      title: "批处理任务已完成",
      body: "共处理 12,480 条记录，耗时 38 秒",
      priority: "normal",
    }),
  });
  if (!res.ok) {
    throw new Error(`Dinglin HTTP ${res.status}: ${await res.text()}`);
  }
  return res.json();
}
```

---

## 4. 回执回调与 HMAC-SHA256 验签

用户在客户端或锁屏界面执行 `ack`、`dismiss`、`snooze` 或自定义 `actions` 时（`read` 纯已读状态变更不触发回调），若通知本身配置了 `callback_url` 或所属来源配置了默认 `callback_url`，后台回调队列会异步发起 POST 请求。

<div style="margin:16px 0;padding:16px;border:1px solid #d2d2d7;border-radius:10px;background:#ffffff;color:#1d1d1f;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:13px;line-height:1.5;">
  <div style="font-weight:600;margin-bottom:10px;">回执签名投递与退避重试流程</div>
  <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(175px,1fr));gap:10px;">
    <div style="padding:10px;border:1px solid #e5e5ea;border-radius:8px;background:#f5f5f7;">
      <div style="font-weight:600;font-size:12px;color:#6e6e73;">步骤 1 · 入队</div>
      <div style="margin-top:4px;">非 <code>read</code> 动作写入 <code>callback_jobs</code>，绑定来源签名密钥 <code>whsec_*</code>。</div>
    </div>
    <div style="padding:10px;border:1px solid #e5e5ea;border-radius:8px;background:#f5f5f7;">
      <div style="font-weight:600;font-size:12px;color:#6e6e73;">步骤 2 · 计算签名</div>
      <div style="margin-top:4px;">取秒级 Unix 时间戳 <code>ts</code>，对 <code>ts + "." + rawBody</code> 计算 HMAC-SHA256 十六进制摘要。</div>
    </div>
    <div style="padding:10px;border:1px solid #e5e5ea;border-radius:8px;background:#f5f5f7;">
      <div style="font-weight:600;font-size:12px;color:#6e6e73;">步骤 3 · 响应判定</div>
      <div style="margin-top:4px;">接收方返回 HTTP <code>2xx</code> 即标记 <code>delivered</code>；请求超时上限为 10 秒。</div>
    </div>
    <div style="padding:10px;border:1px solid #e5e5ea;border-radius:8px;background:#f5f5f7;">
      <div style="font-weight:600;font-size:12px;color:#6e6e73;">步骤 4 · 退避重试</div>
      <div style="margin-top:4px;">非 2xx 或网络失败后依次等待 <code>5s</code> → <code>30s</code> → <code>120s</code> 重试，耗尽后标记 <code>failed</code>。</div>
    </div>
  </div>
</div>

### 回调请求头与载荷格式

- 请求头：
  - `Content-Type: application/json`
  - `X-Dinglin-Event: receipt.created`
  - `X-Dinglin-Timestamp`: 秒级 Unix 时间戳字符串（例如 `1795667400`）
  - `X-Dinglin-Signature`: 形如 `sha256=<lowercase_hex>`
- 请求体 JSON 示例：

```json
{
  "event": "receipt.created",
  "notification_id": "9f8e7d6c5b4a3210fedcba9876543210",
  "receipt_id": "0123456789abcdef0123456789abcdef",
  "action_id": "approve",
  "action_label": "批准发布",
  "payload": null,
  "created_at": "2026-11-26T04:30:00Z"
}
```

### 验签公式与示例

使用创建来源时获得的 `whsec_*` 作为密钥，对 `timestamp + "." + rawBody` 的原始字节计算 HMAC-SHA256 并使用常量时间比对，同时校验时间戳偏差以防重放。

```go
func VerifyDinglinSignature(secret, timestampHeader, sigHeader string, rawBody []byte) bool {
	ts, err := strconv.ParseInt(timestampHeader, 10, 64)
	if err != nil {
		return false
	}
	if delta := time.Now().Unix() - ts; delta < -300 || delta > 300 {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(timestampHeader))
	mac.Write([]byte("."))
	mac.Write(rawBody)
	expected := "sha256=" + hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(expected), []byte(sigHeader))
}
```

```python
import hashlib
import hmac
import time

def verify_dinglin_signature(secret: str, ts_header: str, sig_header: str, raw_body: bytes) -> bool:
    try:
        ts = int(ts_header)
    except ValueError:
        return False
    if abs(time.time() - ts) > 300:
        return False
    msg = ts_header.encode("utf-8") + b"." + raw_body
    expected = "sha256=" + hmac.new(secret.encode("utf-8"), msg, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, sig_header)
```

---

## 5. AI Agent / MCP 接入

只有 `kind="agent"` 的来源 Token 可以访问 MCP 端点；`kind="webhook"` 的凭据调用 MCP 会收到 HTTP `403 agent_required`。

### 方式 A：Streamable HTTP 协议（`POST /mcp`、`DELETE /mcp`）

- 支持协议版本：`2025-03-26`，JSON-RPC `2.0`。
- 会话生命周期：
  1. 客户端携带 `Authorization: Bearer <src_token>` 发送 `initialize` 请求，服务端在响应头返回 `Mcp-Session-Id`。
  2. 后续所有 `ping`、`tools/list`、`tools/call` 请求均须携带相同的 `Mcp-Session-Id` 与所属来源 Token，否则返回 `400 missing_session` 或 `404 session_not_found`。
  3. 无 `id` 或方法名以 `notifications/` 开头的通知消息返回 HTTP `202 Accepted`。
  4. 任务结束时可调用 `DELETE /mcp`（携带 `Mcp-Session-Id`）主动注销会话，返回 `204 No Content`。

客户端配置示例（支持 Streamable HTTP 的 MCP 宿主）：

```json
{
  "mcpServers": {
    "dinglin": {
      "type": "streamable-http",
      "url": "https://dinglin.example.com/mcp",
      "headers": {
        "Authorization": "Bearer src_your_agent_token"
      }
    }
  }
}
```

### 方式 B：本地桥接 `dinglin mcp-stdio`

当 Claude Desktop、Cursor 或本地 CLI 工具仅支持 Stdio MCP 时，可直接复用 `dinglin` 二进制提供的子命令将标准输入/输出 JSON-RPC 转发至远端 `/mcp`（自动管理 `Mcp-Session-Id`）。支持命令行参数或环境变量两种传参方式：

- `--server` / `DINGLIN_SERVER_URL`：远端 `/mcp` 完整地址（如 `https://dinglin.example.com/mcp`）。
- `--token` / `DINGLIN_MCP_TOKEN`：Agent 来源的 `src_*` Token。

```json
{
  "mcpServers": {
    "dinglin": {
      "command": "dinglin",
      "args": [
        "mcp-stdio",
        "--server",
        "https://dinglin.example.com/mcp",
        "--token",
        "src_your_agent_token"
      ]
    }
  }
}
```

### MCP 工具清单（7 个工具与来源隔离规则）

| 工具名 | 参数 Schema（`*` 为必填） | 返回说明与 `source_id` 隔离约束 |
|---|---|---|
| `send_notification` | `title*`, `body`, `priority`, `category`, `expires_in_sec`, `idempotency_key`, `callback_url`, `actions` | 自动绑定当前 Agent `source_id`，返回 `notification` 与 `deduplicated` |
| `get_notification_receipts` | `notification_id*` | 仅限查询本 Agent 发出的通知；跨源访问返回错误 `forbidden` |
| `list_notifications` | `q`, `priority`, `status`（`unread/read/acked/snoozed/dismissed`）, `limit`（1–200） | 服务端强制过滤为当前 `source_id`，不返回其他来源消息 |
| `create_schedule` | `kind*`（`scheduled_notification/alarm/countdown`）, `title*`, `schedule_type*`（`once/cron/duration`）, `body`, `priority`, `fire_at`（RFC3339）, `cron_expr`, `timezone`, `duration_sec`, `snooze_minutes` | 创建归属于当前 Agent `source_id` 的调度并同步端侧 |
| `list_schedules` | `kind`, `enabled_only` | 仅列出归属当前 `source_id` 的调度 |
| `update_schedule` | `id*`, `title`, `enabled`, `fire_at`（RFC3339）, `cron_expr`, `snooze_minutes`, `countdown_action`（`start/pause/resume/reset/cancel`） | 先校验 `schedule.source_id == src.ID`，跨源返回 `forbidden` |
| `delete_schedule` | `id*` | 校验归属后删除调度并下发端侧取消同步 |

---

## 6. 错误响应与部署建议

### 错误响应格式与状态码速查表

除 JSON-RPC 方法调用内部错误按 MCP 规范返回 `isError: true` 或 `-32601/-32602` 外，HTTP 层错误统一返回 `{"error":{"code":"...","message":"..."}}`：

| HTTP 状态码 | 典型 `error.code` | 触发原因 | 处理建议 |
|---|---|---|---|
| `400` | `invalid_json` / `validation_error` / `empty_body` / `missing_session` | JSON 语法错误、缺失必填字段、非法的 `priority` 或缺少 `Mcp-Session-Id` | 检查请求载荷格式与必需 Header |
| `401` | `unauthorized` | 缺失或无效的 Bearer / Query Token | 核对 `src_*` Token，或检查是否因轮换失效 |
| `403` | `source_disabled` / `slug_mismatch` / `agent_required` / `forbidden` | 来源被禁用、Webhook slug 与凭据不匹配、用 Webhook 凭据调 MCP 或跨源查询回执 | 确认来源类型与启用状态，仅访问本源资源 |
| `404` | `not_found` / `session_not_found` | 通知不存在或 `Mcp-Session-Id` 已失效/重启丢失 | 重新发起 MCP `initialize` 建立会话或核对 ID |
| `409` | `slug_exists` | 创建来源时 `slug` 与现有记录冲突 | 更换唯一 `slug` |
| `500` | `notify_error` / `db_error` | 服务端内部存储或运行时异常 | 查看网关日志并借助 `Idempotency-Key` 安全重试 |

### 生产部署建议

- 将 Dinglin 网关置于 Nginx、Caddy 或 Cloudflare Tunnel 等反向代理之后启用 HTTPS（TLS），避免 `Authorization` 与 `whsec_*` 签名链路在公网明文传输；若启用代理缓冲，请为 `/api/v1/ws` 关闭缓冲并开启 WebSocket 升级头转发。
- 业务侧接收回执回调时，建议先验证 `X-Dinglin-Timestamp`（例如限制在 300 秒窗口内）再使用常量时间比对验证 `X-Dinglin-Signature`。
- 所有重试逻辑均应携带稳定的 `Idempotency-Key`（例如任务流水号或构建 ID），确保网络超时重发不会在用户终端重复弹出告警或响铃。
