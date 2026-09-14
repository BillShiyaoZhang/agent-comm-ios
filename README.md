# Agent Workspace · Apple 客户端

适配 `agent-collaboration-deploy` 2026-09-14 远程工作台与账号同步架构。支持 iOS 18+、macOS 15+、visionOS 2+；同一份 SwiftUI 界面在手机使用三个标签页，在宽屏使用侧栏。

## 使用

1. 使用 Xcode 打开 `agent comm ios.xcodeproj`，选择 `agent comm ios` scheme。
2. 登录现有工作区账号。默认地址为 `https://agent-communication.online`；自托管地址必须是 Web/nginx 的根地址，并与服务端 `NEXTAUTH_URL` 同源。
3. 在工作台保存 Agent 名称及 URN，创建或恢复账号的控制台身份。
4. 在 **Agent 本机**完成控制台配对，并配置 connector 的允许列表与 remote 功能。保存连接或注册身份本身不授予访问权。
5. 验证连接后，查看已同步的联系人、协作事项、收件箱；继续历史对话，或发起新对话。

配对与运行时安装以 deploy 仓库的 `agent-comm-platform/agent-comm/python/README.md` 和 connector 文档为准。审批继续在 Agent 原生渠道完成。客户端不提供已经从服务端删除的独立交易、服务调用、联系人写入或 Web 审批功能。

手机上的 `localhost` 是手机本身；局域网调试应使用电脑的私有地址。客户端只允许 HTTPS 公网地址及明确的本地 HTTP 地址，拒绝重定向。应用保留 ATS 的本地自托管兼容配置，由统一网络客户端限制 HTTP 的地址范围。macOS target 包含网络客户端 sandbox entitlement。

## 可复用模块

| 模块 | 职责 | 使用者 |
| --- | --- | --- |
| [`Packages/AgentWorkspaceKit`](Packages/AgentWorkspaceKit/README.md) | Foundation 模型、NextAuth 会话、HTTP/RPC、请求关联检查、合并与配对规则、Keychain 存储 | iOS、macOS、visionOS 及其他 Swift 客户端 |
| deploy 的 `agent-collaboration-web/packages/client-contract` | 不依赖 Next/React 的 JS 客户端、协议验证、同步策略、类型、JSON Schema 和跨语言 fixtures | 已由 Web 使用；可供桌面、Android/其他语言客户端实现对照 |
| `WorkspaceStore` | 页面状态、前台同步、会话恢复、发送日志与 UI 动作 | Apple 应用层 |

网络层对接 Web 的账号会话与工作区接口；Web 继续负责与 platform/helper/runtime 的签名和加密传输。Agent 身份私钥不进入手机。详见 [架构与兼容说明](docs/ARCHITECTURE.md)。

## 同步与恢复

- 前台约每 4 秒读取账号工作区，后台停止设备轮询；服务端原有同步继续运行。回到前台立即读取。
- 更新失败保留本次会话已加载的数据；快照以服务端时间判断新旧，已结束回合不会被旧缓存改回处理中。
- 手机使用账号保存的历史会话，支持按 ID 找回对话及加载更早回合。
- Cookie、草稿和发送前日志存入设备 Keychain。草稿和日志按服务器及账号隔离，重新登录/切换服务器会使旧请求失效。
- 发送前先保存请求编号。超时或中断保留同一编号，可读取对话核实或重试同一个请求；不会自动重发写入。
- 确认受理只代表 Agent 接收了回合；完成结果来自后续同步。协作动作被本机队列接收也不等于对方同意或事项完成。
- 冷启动恢复完整历史需要工作区网络连接；完整历史保存在服务端加密账号副本，本机不额外持久化全量聊天快照。

## 验证

```sh
swift test --package-path Packages/AgentWorkspaceKit
bash scripts/check-workspace-store.sh
bash scripts/check-contract-fixtures.sh
xcodebuild -project 'agent comm ios.xcodeproj' -scheme 'agent comm ios' \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project 'agent comm ios.xcodeproj' -scheme 'agent comm ios' \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

如本机 `xcode-select` 指向 Command Line Tools，请为命令设置 `DEVELOPER_DIR` 指向完整 Xcode 的 `Contents/Developer`。受限构建环境的缓存参数见包内 README。

Swift 包测试通过 URLProtocol 模拟认证、Cookie、Origin、分页、请求回执、超时与取消；Store 回归脚本编译真实 Store，替换网络与安全存储以测试会话切换、分页及发送恢复。两者均不访问真实账号。跨语言 fixtures 来自 deploy 共享包，更新协议时应同时更新并比较两端文件。

Debug 构建支持以下只读 UI 演示启动参数：

- `--demo-workspace`：工作台示例数据。
- 追加 `--demo-messages` 或 `--demo-collaboration`：直接预览对应页面。
- `--preview-login`：仅显示登录布局，不尝试恢复会话。

演示模式有明确标识，禁止远程读写与消息发送；Release 构建不包含示例数据或演示入口。它用于布局检查，不能代替真实 Agent 联调。

界面截图与验证范围见 [UI 验证记录](docs/UI_REVIEW.md)。

完整结果与尚未覆盖的验收范围见 [验证记录](docs/VALIDATION.md)。
