#if DEBUG
import Foundation
import AgentWorkspaceKit

enum DemoWorkspace {
    static let agent: WorkspaceAgent = {
        let json = #"""
        {
          "agent":{"id":"demo-hermes","name":"Hermes","urn":"urn:agent:demo-hermes","platformRegistered":true,"lastActiveAt":null,"createdAt":"2026-09-27T10:00:00Z","sync":{"status":"ready","lastAttemptAt":1790493571000,"lastSuccessAt":1790493571000,"nextSyncAt":null,"error":null}},
          "identity":{"virtualUrn":"urn:agent:demo-console","virtualEd25519PublicKey":"示例控制台公钥"},
          "sync":{"status":"ready","lastAttemptAt":1790493571000,"lastSuccessAt":1790493571000,"nextSyncAt":null,"error":null},
          "snapshots":{
            "capabilities":{"time":1790493571000,"data":{"methods":[{"name":"conversation.send","available":true},{"name":"conversation.get","available":true},{"name":"contacts.list","available":true},{"name":"collaboration.state","available":true},{"name":"inbox.list","available":true}]}},
            "contacts.list":{"time":1790493571000,"data":{"contacts":[{"contact_id":"lin","alias":"林的 Agent","urn":"urn:agent:lin-demo","connection_status":"connected","presence":{"status":"online","expires_at":"2026-09-28T10:00:00Z"}},{"contact_id":"design","alias":"设计伙伴","urn":"urn:agent:design-demo","connection_status":"connected"}]}},
            "collaboration.state":{"time":1790493571000,"data":{"contact_requests":[{"request_id":"friend-demo-1","direction":"incoming","status":"pending","peer_urn":"urn:agent:research-demo","created_at":1790493171}],"sent_messages":[{"message_id":"sent-demo-1","recipient_urn":"urn:agent:design-demo","text":"收到，我们先核对评审范围。","status":"sent","created_at":1790493371}],"collaboration":{"collaborations":[{"collaboration_id":"collab-review-1","task_id":"review-1","peer_urn":"urn:agent:design-demo","phase":"negotiating","waiting_reason":"owner_decision","joined":true,"terms":{"topic":"下周产品方案评审","version":2,"start":"2026-09-30T06:00:00Z","end":"2026-09-30T07:00:00Z"},"source_context":{"origin":"paired_conversation","conversation_id":"conversation-demo","turn_id":"turn-demo-1"}}]},"pending_confirmations":[{"approval_id":"approval-1","subject_id":"review-1","question":"是否允许将周三下午的评审安排发给设计伙伴？","status":"pending"}],"tasks":[{"task_id":"review-1","status":"active","scope":{"purpose":"准备下周的产品评审","topic":"汇总方案与待讨论事项","participant_ids":["我的 Agent","设计伙伴"]}}],"operations":[{"task_id":"review-1","operation_id":"op-1","status":"accepted","text":"已整理讨论提纲，等待确认后发送。"}]}},
            "inbox.list":{"time":1790493571000,"data":{"messages":[{"message_id":"msg-1","sender_urn":"urn:agent:design-demo","text":"设计方案已经更新，周三可以一起过一遍。","read":false,"received_at":1790493471,"task_id":"review-1"}]}}
          },
          "conversations":[{"id":"conversation-demo","title":"准备下周的产品评审","updatedAt":1790493571000,"pending":false,"turnCount":2}],
          "activeConversationId":"conversation-demo",
          "conversation":{"conversation_id":"conversation-demo","turns":[{"turn_id":"turn-demo-1","status":"completed","text":"帮我看看产品评审准备得怎么样了。","response":"方案和讨论提纲已经整理好了。\n\n设计伙伴更新了最新方案，我们还需要确认周三的评审时间。你可以在“协作”中核对完整确认问题，并在授权允许时回应。","created_at":1790493271},{"turn_id":"turn-demo-2","status":"completed","text":"好的，先把需要讨论的问题整理一下。","response":"这次建议集中讨论三件事：\n\n1. 首次连接的引导是否足够清楚\n2. 手机与桌面如何接续同一段对话\n3. 发送结果待核实时，怎样让用户明确下一步\n\n我会把这份提纲保留在当前事项里。","created_at":1790493471}]},
          "hasEarlierTurns":false,"submission":null
        }
        """#
        return try! JSONDecoder().decode(WorkspaceAgent.self, from: Data(json.utf8))
    }()
}
#endif
