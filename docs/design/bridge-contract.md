# 桥 HTTP 契约：错误与能力协商

桥继续使用 `/dsh-go/v1`。认证通过后，`GET /dsh-go/v1/capabilities` 返回协议主版本、桥实现版本和已实现的路由家族。新 App 按 `v` 比较可解析的协议；`bridge` 只供诊断，不能按它推断权限或资源是否存在。

## 响应

```json
{
  "v": 1,
  "bridge": "0.4.0",
  "capabilities": [
    "inventory", "occupancy", "native-ui", "native-stream",
    "native-media", "native-files", "plugin-config", "session-deletion",
    "companion", "companion-prompt-context", "companion-recall", "companion-signals"
  ]
}
```

`bridge` 由桥的 package.json 提供，示例值不是兼容门槛。能力列表为当前实现的固定声明；新增名字可以被旧客户端忽略，已有名字不改变含义。缺少协议响应与 `capabilities: []` 不同：前者是旧桥或无法协商，后者明确没有宣告能力。

| 能力 | 已实现的路由家族 |
|---|---|
| `inventory` | GET/HEAD `/inventory` |
| `occupancy` | POST `/occupancy` |
| `native-ui` | `/contributions`、`/views/...`、`/invoke`、`/assets/...` |
| `native-stream` | WS `/stream`；仍需当前连接 hello/welcome 协商 |
| `native-media` | `/media/...`；仍需有效媒体 lease |
| `native-files` | `/files/{request}/upload`、`/complete`；仍需当前文件选择请求 |
| `plugin-config` | `/plugin-config`、`/plugin-config/{entryId}` |
| `session-deletion` | `/sessions/deletion`、`/sessions/delete` |
| `companion` | companion 状态、events、memories、context、export |
| `companion-prompt-context` | `/companion/prompt-context` |
| `companion-recall` | `/companion/recall` 及 bind/revoke/bindings |
| `companion-signals` | `/companion/signals`、`/companion/signals/stream` |

能力只说明协议代码存在。删除前必须重新读取 `/sessions/deletion` 并取得 `supported: true`；回忆、signals、媒体与文件继续检查其既有运行状态、用户同意、归属和当前代次。固定列表既不授权删除，也不表示已经启用任何插件。端点走已有 Connection 认证和 Host/Origin 守卫，响应 `Cache-Control: no-store`；非 GET 是 405 `method-not-allowed`。

## 错误形状

桥业务错误使用 `{error:{code,message}}`。已有 `v` 保留；plugin-config 的安全字段路径是 `error.path`。原稳定错误码、HTTP 状态以及 session、companion 的命名空间不改。桥总兜底的未知路由是 404 `route-not-found`；路由内资源缺失继续用原来的 `not-found`、`entry-unavailable` 等码。

客户端先读嵌套 `error`，再兼容旧平铺 `{code,message}`。文本或 HTML 仍映射到 `dsh-go/http-<status>`，不直接把 HTML 当作显示消息。

通用认证拒绝保留原传输形状。上游 webserver 可在桥之前拒绝，`zzzz-plugin-config-readability.diff` 仍可回答旧平铺的 `host-unavailable` 503；桥自身的 unavailable 响应为嵌套形式。不能把“业务错误统一”解读为反向代理或上游守卫的每个响应都必定具有 `error`。

## 客户端入口与 404

`DshGoApi.readDshGoBridgeCapabilities()` 返回 `DshGoBridgeCapabilities?`。只有无机器码或 `route-not-found` 的 404 返回 null（旧桥/未协商）。非 404、其他机器码、错误 JSON/字段、未知协议主版本都抛出，不缓存成“不支持”。未知整数主版本产生 `dsh-go/unsupported-version`；缺少或不合法的 `v` 是协议错误。未知能力名允许保留，调用方只识别自己使用的名字。

`readDshGoContributions` 的成功 200 与已有 previous 的 304 均校验 v1，继续走原有单请求与 ETag 路径。成功不先发能力查询，桥实现版本较高或较低也不改变 v1 的解析。

| contributions 结果 | 行为 |
|---|---|
| 200，`v:1` | 正常返回，无额外协商 |
| 304，previous.v 为 1 | 返回同一 previous 对象，无额外协商 |
| 404，嵌套或平铺的资源码 | 原码抛出，无额外协商 |
| 404，`route-not-found` | 返回 null，无额外协商 |
| 404，无码；能力响应 v1 包含 native-ui | 抛原 HTTP 404，不隐藏实现不一致 |
| 404，无码；能力响应 v1 不含 native-ui | 返回 null，明确未宣告 |
| 404，无码；协商端点也无路由 | 返回 null，保持旧桥降级，含义仍是未协商 |
| 协商中 401/403/5xx、其他结构化404、网络异常、未知主版本 | 实际错误向上传播 |

每次需要探测时重新读取，没有进程级缓存或第二套连接状态机。`timeout` 沿用每个 HTTP 请求的超时；无码404时最多再做一次能力请求。显式 `route-not-found` 是当前请求的直接路由缺失证据，当前 API 不接收调用方缓存的协商对象。持有其他代次声明的调用方不应据旧声明覆盖当前结果。

## 新旧双向兼容

| 组合 | 行为 |
|---|---|
| 基底 App + 新桥 | 原成功体/路由不变；基底 plugin-config 解析器已同时支持嵌套和平铺；新增端点不影响旧调用 |
| 新 App + 基底桥 | contributions 的 v1 成功照常；协商端点旧404返回 null；旧平铺错误仍可读取 |
| 新 App + 新桥 | v决定可解析性，列表决定实现是否宣告；资源404不再泛化成旧桥 |
| 新 App + 无桥 Host | 两条端点均旧式404时仍可降级；认证/服务器错误不会误报无桥 |
| 新 App + 未支持的主版本 | 抛 `dsh-go/unsupported-version`，不套用v1默认值 |
| 非 HTTP carrier | 沿用 `dsh-go/unsupported`，不创建旁路连接 |

兼容结论来自本仓库基底解析器；不等于验证了每个历史 APK。`DshGoContributions.fromJson` 仍是供本地数据使用的宽松模型读取器；HTTP 入口负责必需的主版本校验。

## 范围与验证

`client_inventory_api.dart` 在另一条本机工作线：其无条件404降级应按上述规则接入 `readDshGoBridgeCapabilities` 并检查 `inventory`。本补丁只改授权的 `dsh_go_api.dart` 与相关测试，不改本机状态/UI。将来若要缓存，须用现有 Host/mux generation 管理失效；不得永久缓存null。

轻量 `bridge-http-errors.test.mjs` 使用真实 loopback HTTP 与模拟 Cordis/Connection，核对能力列表、已有权限接口仍独立以及401/403/503入口。`route-guard.mjs`、`native-bridge.mjs` 把新路由纳入实际 Host 契约。Dart fake Host 覆盖新旧桥、无能力/未知能力、资源404、协商失败、v检查和不增加成功往返次数。完整 Host 与 Dart 测试结果由实际执行记录确定；单测夹具不替代完整环境。
