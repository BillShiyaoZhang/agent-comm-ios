# Apple 客户端开发与安装

[返回使用介绍](../README.md)。本文保留源码安装、同步机制和验证说明；下列命令均在本仓库根目录运行。

面向 `agent-collaboration-web` 的远程工作台与账号同步接口。支持 iOS 18+、macOS 15+、visionOS 2+；同一份 SwiftUI 界面在手机使用四个标签页，在宽屏使用侧栏。

## 使用

1. 使用 Xcode 打开 `agent comm ios.xcodeproj`，选择 `agent comm ios` scheme。
2. 登录现有工作区账号。默认地址为 `https://agent-communication.online`；自托管地址必须是 Web/nginx 的根地址，并与服务端 `NEXTAUTH_URL` 同源。
3. 首次接入时，让运行 Hermes 的设备发起一次性连接申请，核对申请中的 Agent、功能及期限后授权。链接确认仅代表工作区已授权，显示本机完成后才代表 Hermes 保存了配对。已有安装仍可在工作台保存 Agent 名称及 URN，并创建或恢复控制台身份。
4. 阅读工作区的当前平台政策。合规政策需要账户明确确认，暂停或无法核验政策时仍可查看已保存内容；新的远程读取、发送和后台同步会暂停。
5. 验证连接后，查看已同步的联系人、协作事项、收件箱和提醒；继续历史对话，或发起新对话。好友、消息、审批与协作工具分别受实际配对方法约束。

配对与运行时安装以 deploy 仓库的 `docs/users/README.md`、SDK runtime 和 connector 文档为准。手工配对必须在 **Agent 本机**完成，并配置 connector 的允许列表与 remote 功能；保存连接或注册身份本身不授予访问权。新客户端可在 Agent 明确开放 `approval.respond` 时回应确切审批，也可继续使用原生渠道；旧配对不会自动增加权限。现行好友、消息和审批操作使用已配对 Agent 的 RPC，不重新启用退役的云端联系人、HITL、交易或服务业务模型。

手机上的 `localhost` 是手机本身；局域网调试应使用电脑的私有地址。客户端只允许 HTTPS 公网地址及明确的本地 HTTP 地址，拒绝重定向。应用保留 ATS 的本地自托管兼容配置，由统一网络客户端限制 HTTP 的地址范围。macOS target 包含网络客户端 sandbox entitlement。

## 服务端版本与兼容检查

Apple 客户端通过 Web 的账户接口工作，不直接连接 Go platform。填写 Web/nginx 的根地址，例如 `https://agent-communication.online`，不要填写 `/dashboard`、helper 地址或单独的消息转交服务地址。

它需要支持以下工作区约定的 Web 版本：

- `/api/workspace` 返回连接与同步状态。
- `/api/agents/:id/workspace` 支持 `conversation_id`（省略与空字符串不同）、`before` 历史分页，以及 `select_conversation` / `dismiss_submission` 操作。
- `/api/workspace/sync` 支持安排同步，`/api/agents/:id/control` 支持提交和按同一请求编号查询。
- 返回值符合 `AgentWorkspaceKit` 中的模型，包括 `hasEarlierTurns` 和未确认发送的记录。完整路由表见[架构说明](ARCHITECTURE.md#已接入-api)。

本次功能更新还依赖以下新增约定：

- `/api/platform-policy` 返回已验证的政策披露与 `can_use_workbench`，并支持明确确认、暂停与恢复。`policy_paused`、`policy_unavailable` 保留缓存，不表示需要重新配对。
- `/api/agents/:id/workspace/operations` 提供账户持久操作账本。原请求先保存再投递，客户端更新仅是显示提示；终态事实由认证 Agent 结果或读取确定。
- `/api/notifications` 提供账户范围的提醒、未读与待处理数量、分页和逐版本阅读回执。提醒已读不等于业务完成或授权同意。
- `/api/agents/:id/workspace/conversations` 提供保存历史中的搜索、会话标题、归档与恢复等账户状态。`recordStates` 记录联系人或协作在账户列表中的隐藏状态；这不撤销 Agent 本机对象或授权。
- `/api/agents/:id` 支持连接重命名与删除。删除会清除当前账户该连接的保存副本，不停止 Agent 执行或撤销本机配对；未确认操作和处理中回合需要先核实。
- `/api/onboarding/claim/:code` 提供一次性连接申请预览和明确确认。控制台身份与托管证书由 Web 服务管理，手机不持有 Agent 或控制台私钥。
- 邮箱注册返回 `202` 邮件验证申请；新账户验证后才能登录。找回密码与重新发送验证邮件使用现行 `/api/auth` 路由。

2026-09-27 本次更新按本机 deploy `65be7df` 固定的 Web `78c019b` 核对新增接口，并沿用其 `packages/client-contract` 共享模块中的权限、时间及不确定写入语义。Web 的接口校验、客户端与同步逻辑使用该模块；请求指纹和已保存的发送记录采用规范化 JSON 比较，并兼容旧会话参数顺序。Swift 保留原有稳定发送编码以兼容旧后端。

`packages/client-contract` 是配套开发和跨语言 fixtures 的来源，不是 Apple 应用运行时的文件依赖；更新协议时需同时比较两端内容。当前 fixture 集合新增了 Agent 提醒和会话结果提醒，包含 9 份 JSON。运行 `scripts/check-contract-fixtures.sh` 检查逐字节一致性。参考模块设计与实际测试范围分别见[架构说明](ARCHITECTURE.md)及[验证记录](VALIDATION.md)。

**拉取源码不等于已经更新线上服务。** 规范化跨端重试修复需要重新构建并部署到所有提供服务的 Web 实例后才生效；仅更新 Apple 应用不能改变现有后端。详见[共享模块的重试与发布说明](https://github.com/BillShiyaoZhang/agent-collaboration-web/blob/d56bf3557141821290c4a996f4fe98df56b5395d/packages/client-contract/README.md#cross-client-retries-and-rollout)。源码和 fixtures 核对不等于已完成真实账户的跨端联调。

应用设置中的“测试连接”只检查服务可达。发布前还需要使用匹配的后端验证真实邮箱注册/登录、政策确认、已有配对恢复、历史分页、发送核实、好友通信及确切审批；原生客户端的完整真机验收和签名分发不在现有验证记录的已完成范围内。

## 可复用模块

| 模块 | 职责 | 使用者 |
| --- | --- | --- |
| [`Packages/AgentWorkspaceKit`](../Packages/AgentWorkspaceKit/README.md) | Foundation 模型、NextAuth 会话、HTTP/RPC、请求关联检查、合并与配对规则、Keychain 存储 | iOS、macOS、visionOS 及其他 Swift 客户端 |
| Web 的 [`packages/client-contract`](https://github.com/BillShiyaoZhang/agent-collaboration-web/tree/78c019bf132e7b55e31b5987ba11617a6ba15662/packages/client-contract) | 不依赖 Next/React 的 JS 客户端、协议验证、同步策略、类型、JSON Schema 和跨语言 fixtures | Web 直接复用；Swift 和其他语言客户端用 Schema 与 fixtures 核对接口 |
| `WorkspaceStore` | 页面状态、前台同步、会话恢复、发送日志与 UI 动作 | Apple 应用层 |

网络层对接 Web 的账号会话与工作区接口；Web 继续负责与 platform/helper/runtime 的签名和加密传输。Agent 身份私钥不进入手机。详见 [架构与兼容说明](ARCHITECTURE.md)。

## 同步与恢复

- 前台约每 4 秒读取账号工作区，后台停止设备轮询；服务端原有同步继续运行。回到前台立即读取。
- 更新失败保留本次会话已加载的数据；快照以服务端时间判断新旧，已结束回合不会被旧缓存改回处理中。
- 手机使用账号保存的历史会话，支持按 ID 找回对话及加载更早回合。
- Cookie、未同步草稿和发送前日志存入设备 Keychain。草稿按会话隔离，并延迟保存到账户；只有匹配当前编辑版本的成功回执才解除本机覆盖。草稿和日志按服务器及账号隔离，重新登录/切换服务器会使旧请求失效。
- 发送前先保存请求编号。超时或中断保留同一编号，可读取对话核实或重试同一个请求；不会自动重发写入。
- 好友申请、回应、消息、已读、审批及协作工具在服务端保存原请求与参数后才投递。刷新和恢复账本不自动重放，明确重试复用原请求；120 秒原投递期限不因重试延长。已过期且可能产生重复效果的协作操作不能通过新请求 ID 通用重启。
- 回应审批前再次读取当前确切问题、不可变审批 ID 和对象，变化或已处理时要求重新查看。认证结果仍不明确时继续显示待核实，不把传输回执当作成功。
- 确认受理只代表 Agent 接收了回合；完成结果来自后续同步。协作动作被本机队列接收也不等于对方同意或事项完成。接受好友请求允许普通通信，不自动授予协作范围或核实现实身份。
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
- 追加 `--demo-notifications`：预览提醒中心。
- `--preview-login`：仅显示登录布局，不尝试恢复会话。

演示模式有明确标识，禁止远程读写与消息发送；Release 构建不包含示例数据或演示入口。它用于布局检查，不能代替真实 Agent 联调。

界面截图与验证范围见 [UI 验证记录](UI_REVIEW.md)。

完整结果与尚未覆盖的验收范围见 [验证记录](VALIDATION.md)。
