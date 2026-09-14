# 验证记录 · 2026-09-14

环境：Xcode 27.0 beta（27A5228h），Swift 6.4，Node 22。应用最低目标为 iOS 18、macOS 15、visionOS 2。构建均关闭代码签名，用于源码集成验证。

| 检查 | 结果 |
| --- | --- |
| AgentWorkspaceKit 单元测试 | 18 项通过 |
| WorkspaceStore 确定性回归 | 12 项通过 |
| Web Node 测试 | 109 项通过 |
| Web TypeScript / ESLint / 生产构建 | 通过 |
| 共享 JS 包独立打包、安装与 require | 通过 |
| 跨语言 fixtures 文件一致性 | 7 份一致 |
| iOS Simulator Debug / Release 构建 | 通过 |
| macOS Debug 构建 | 通过 |
| visionOS Simulator Debug 构建 | 通过 |
| 工程 plist / entitlement / diff 检查 | 通过 |
| iPhone / iPad 模拟器视觉检查 | 已检查，见 UI_REVIEW.md |

状态回归覆盖恢复活动会话、远端历史找回、旧快照不回退、分页、未决请求跨重启恢复、请求中连接消失、切换账号/重新登录、无法读取安全存储时禁止覆盖，以及本机请求 A 与另一设备新请求 B 的并发恢复。

公网只读探测返回：`/healthz` 200、`/api/auth/csrf` 200、`/api/auth/session` 200（未登录）、`/api/workspace` 401。没有使用真实账号进行注册、配对或发送测试。

本次保留部署环境不变。完整真机验收、签名分发以及真实 Agent/原生确认交互尚未执行。Web 的规范化请求指纹修复需要发布本次 Web 更新后生效；Swift 同时保留旧部署的合法参数顺序兼容。
