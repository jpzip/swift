import Foundation

/// The abstract interface a user-supplied L2 persistent cache must satisfy.
/// Implementations are free to add TTLs, eviction, or backends.
public protocol Cache: Sendable {
    func get(_ key: String) async throws -> Data?
    func set(_ key: String, _ value: Data) async throws
    func delete(_ key: String) async throws
    func clear() async throws
}

/// L1 in-memory cache, bounded by a fixed number of prefix entries.
/// Safe for concurrent use via actor isolation.
actor MemoryLRU {
    private final class Node {
        let key: String
        var value: ZipcodeDict
        var prev: Node?
        var next: Node?
        init(key: String, value: ZipcodeDict) {
            self.key = key
            self.value = value
        }
    }

    private let capacity: Int
    private var items: [String: Node] = [:]
    private var head: Node?
    private var tail: Node?

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func get(_ key: String) -> ZipcodeDict? {
        guard let node = items[key] else { return nil }
        moveToFront(node)
        return node.value
    }

    func set(_ key: String, _ value: ZipcodeDict) {
        if let node = items[key] {
            node.value = value
            moveToFront(node)
            return
        }
        let node = Node(key: key, value: value)
        items[key] = node
        pushFront(node)
        if items.count > capacity {
            if let oldest = tail {
                remove(oldest)
                items.removeValue(forKey: oldest.key)
            }
        }
    }

    func clear() {
        items.removeAll()
        head = nil
        tail = nil
    }

    func size() -> Int { items.count }

    private func pushFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func remove(_ node: Node) {
        let p = node.prev
        let n = node.next
        p?.next = n
        n?.prev = p
        if head === node { head = n }
        if tail === node { tail = p }
        node.prev = nil
        node.next = nil
    }

    private func moveToFront(_ node: Node) {
        if head === node { return }
        remove(node)
        pushFront(node)
    }
}
