import WithinAudioBuffer

/// One real-time producer and one inference consumer. No allocation or locks in push.
public final class AudioRing: @unchecked Sendable {
    private let storage: OpaquePointer
    public let capacity: Int
    public init(capacity: Int, sampleLimit: UInt64) {
        precondition(capacity > 0 && sampleLimit > 0)
        guard let pointer = within_ring_create(capacity, sampleLimit) else { preconditionFailure("Audio buffer allocation failed") }
        storage = pointer; self.capacity = capacity
    }
    deinit { within_ring_destroy(storage) }
    @discardableResult public func push(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return status }
        return Int(within_ring_push(storage, samples, count))
    }
    public func drain(upTo count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        let read = samples.withUnsafeMutableBufferPointer { within_ring_pop(storage, $0.baseAddress!, count) }
        samples.removeSubrange(read..<samples.count)
        return samples
    }
    public func close() { within_ring_close(storage) }
    public var status: Int { Int(within_ring_status(storage)) }
    public var samplesCaptured: UInt64 { within_ring_count(storage) }
    public var pending: Int { within_ring_pending(storage) }
    public var level: Float { within_ring_level(storage) }
    public var meanEnergy: Double { within_ring_mean_energy(storage) }
}
