import Foundation

// MARK: - User
struct User: Codable, Identifiable {
    let id: String
    let email: String
    let virtualUrn: String?
    let virtualEd25519PublicKey: String?
    let virtualX25519PublicKey: String?
    let createdAt: String
    let updatedAt: String
}

// MARK: - Agent
struct Agent: Codable, Identifiable, Hashable {
    let id: String
    let userId: String
    let name: String
    let urn: String
    let publicKey: String
    let encryptedPrivateKey: String?
    let keySalt: String?
    let localUrl: String?
    let platformRegistered: Bool
    let lastActiveAt: String?
    let createdAt: String
    let updatedAt: String
}

// MARK: - Contact
struct Contact: Codable, Identifiable, Hashable {
    struct AgentBrief: Codable, Hashable {
        let id: String
        let name: String
        let urn: String
    }
    
    let id: String
    let userId: String
    let agentId: String
    let agent: AgentBrief?
    let contactUrn: String
    let trustTier: String // family, friend, stranger, self
    let alias: String?
    let publicKey: String?
    let lastMessageAt: String?
    let createdAt: String
    let updatedAt: String
    
    var displayName: String {
        if let alias = alias, !alias.isEmpty {
            return "\(alias) (\(contactUrn))"
        }
        return contactUrn
    }
}

// MARK: - Message
struct Message: Codable, Identifiable, Hashable {
    let id: String
    let userId: String
    let agentId: String
    let senderUrn: String
    let recipientUrn: String
    let content: String
    let isIncoming: Bool
    let isRead: Bool
    let createdAt: String
}

// MARK: - HITLRequest
struct HITLRequest: Codable, Identifiable, Hashable {
    struct AgentBrief: Codable, Hashable {
        let id: String
        let name: String
        let urn: String
    }
    
    let id: String
    let userId: String
    let agentId: String
    let agent: AgentBrief?
    let requestType: String // message, service_call, transaction
    let payload: String // JSON payload
    let status: String // pending, approved, rejected
    let resolvedAt: String?
    let createdAt: String
}

// MARK: - Transaction
struct Transaction: Codable, Identifiable, Hashable {
    let id: String
    let userId: String
    let agentId: String
    let fromUrn: String
    let toUrn: String
    let amount: String
    let currency: String
    let status: String // pending, confirmed, failed
    let txHash: String?
    let createdAt: String
    let updatedAt: String
}

// MARK: - Service Discovery Models
struct SchemaProperty: Codable, Hashable {
    let type: String
    let description: String?
}

struct ServiceInputSchema: Codable, Hashable {
    let type: String
    let properties: [String: SchemaProperty]?
    let required: [String]?
}

struct ServiceDescription: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
    let inputSchema: ServiceInputSchema?
    let requiresHitl: Bool
    let exposure: String?
}
