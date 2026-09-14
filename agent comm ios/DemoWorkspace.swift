#if DEBUG
import Foundation
import AgentWorkspaceKit

enum DemoWorkspace {
    static let agent: WorkspaceAgent = {
        let json = #"""
        {
          "agent":{"id":"demo-hermes","name":"Hermes","urn":"urn:agent:demo-hermes","platformRegistered":true,"lastActiveAt":null,"createdAt":"2026-09-14T10:00:00Z","sync":{"status":"ready","lastAttemptAt":1789395000000,"lastSuccessAt":1789395000000,"nextSyncAt":null,"error":null}},
          "identity":{"virtualUrn":"urn:agent:demo-console","virtualEd25519PublicKey":"示例控制台公钥"},
          "sync":{"status":"ready","lastAttemptAt":1789395000000,"lastSuccessAt":1789395000000,"nextSyncAt":null,"error":null},
          "snapshots":{
            "capabilities":{"time":1789395000000,"data":{"methods":[{"name":"conversation.send","available":true},{"name":"conversation.get","available":true},{"name":"contacts.list","available":true},{"name":"collaboration.state","available":true},{"name":"inbox.list","available":true}]}},
            "contacts.list":{"time":1789395000000,"data":{"contacts":[{"contact_id":"lin","alias":"林的 Agent","urn":"urn:agent:lin-demo"},{"contact_id":"design","alias":"设计伙伴","urn":"urn:agent:design-demo"}]}},
            "collaboration.state":{"time":1789395000000,"data":{"pending_confirmations":[{"approval_id":"approval-1","subject_id":"与设计伙伴确认评审时间","question":"是否允许将周三下午的评审安排发给设计伙伴？","status":"pending"}],"tasks":[{"task_id":"review-1","status":"active","scope":{"purpose":"准备下周的产品评审","topic":"汇总方案与待讨论事项","participant_ids":["我的 Agent","设计伙伴"]}}],"operations":[{"task_id":"review-1","operation_id":"op-1","status":"accepted","text":"已整理讨论提纲，等待确认后发送。"}]}},
            "inbox.list":{"time":1789395000000,"data":{"messages":[{"message_id":"msg-1","sender_urn":"urn:agent:design-demo","text":"设计方案已经更新，周三可以一起过一遍。","received_at":1789394900,"task_id":"review-1"}]}}
          },
          "conversations":[{"id":"conversation-demo","title":"准备下周的产品评审","updatedAt":1789395000000,"pending":false,"turnCount":2}],
          "activeConversationId":"conversation-demo",
          "conversation":{"conversation_id":"conversation-demo","turns":[{"turn_id":"turn-demo-1","status":"completed","text":"帮我看看产品评审准备得怎么样了。","response":"方案和讨论提纲已经整理好了。\n\n设计伙伴更新了最新方案，我们还需要确认周三的评审时间。确认请求已发到你的原生渠道，回应后我会继续推进。","created_at":1789394700},{"turn_id":"turn-demo-2","status":"completed","text":"好的，先把需要讨论的问题整理一下。","response":"这次建议集中讨论三件事：\n\n1. 首次连接的引导是否足够清楚\n2. 手机与桌面如何接续同一段对话\n3. 发送结果待核实时，怎样让用户明确下一步\n\n我会把这份提纲保留在当前事项里。","created_at":1789394900}]},
          "hasEarlierTurns":false,"submission":null
        }
        """#
        return try! JSONDecoder().decode(WorkspaceAgent.self, from: Data(json.utf8))
    }()
}
#endif
