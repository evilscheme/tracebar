import Foundation
import Darwin

struct HopResult: Sendable {
    let hop: Int
    let address: String
    let latencyMs: Double
}

final class ICMPEngine: @unchecked Sendable {
    private let identifier: UInt16
    private let sock: Int32
    private var nextSequence: UInt16 = 33434
    private let machNumer: Double
    private let machDenom: Double
    private var cachedHost: String = ""
    private var cachedAddr: sockaddr_in?

    init() {
        self.identifier = UInt16(getpid() & 0xFFFF)
        self.sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        if sock < 0 {
            NSLog("[ICMPEngine] socket() failed: %s", String(cString: strerror(errno)))
        }
        // IP_STRIPHDR (value 23) is not exposed in Swift headers.
        // It tells the kernel to strip the IP header from received packets,
        // so ICMP data starts at buffer[0].
        var strip: Int32 = 1
        setsockopt(sock, IPPROTO_IP, 23, &strip, socklen_t(MemoryLayout<Int32>.size))

        // Cache mach timebase (constant for process lifetime)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.machNumer = Double(info.numer)
        self.machDenom = Double(info.denom)
    }

    deinit {
        if sock >= 0 { close(sock) }
    }

    private func allocateSequence() -> UInt16 {
        let seq = nextSequence
        nextSequence = nextSequence >= 65535 ? 33434 : nextSequence + 1
        return seq
    }

    /// Concurrent send/receive probe: a dedicated receiver thread captures
    /// recvTime immediately on packet arrival while the sender paces probes
    /// with a short inter-packet delay on the calling thread.
    /// - Important: Must be called from a single serial queue (not concurrently).
    func probeRound(host: String, maxHops: Int, timeout: TimeInterval = 2.0) -> [HopResult] {
        guard sock >= 0 else { return [] }

        // Cache resolved address — only re-resolve when target changes
        if host != cachedHost || cachedAddr == nil {
            guard let addr = resolveHost(host) else { return [] }
            cachedHost = host
            cachedAddr = addr
        }
        guard var destAddr = cachedAddr else { return [] }

        // Pre-allocate sequences so the receiver can map seq→hop without
        // waiting for the sender to populate the map.
        var hopSeqs: [(hop: Int, seq: UInt16)] = []
        for hop in 1...maxHops {
            hopSeqs.append((hop, allocateSequence()))
        }
        let seqToHop = Dictionary(uniqueKeysWithValues: hopSeqs.map { ($0.seq, $0.hop) })

        // Shared mutable state protected by lock
        let lock = NSLock()
        var sendTimes: [UInt16: UInt64] = [:]
        var responses: [Int: (address: String, latencyMs: Double)] = [:]
        var destHop = maxHops
        var sendingDone = false

        // Capture immutable values for the receiver closure
        let sockFd = self.sock
        let numer = self.machNumer
        let denom = self.machDenom
        let deadline = Date().addingTimeInterval(timeout)

        // --- Receiver thread: always blocking on recvfrom so recvTime is accurate ---
        let recvGroup = DispatchGroup()
        recvGroup.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            defer { recvGroup.leave() }
            var buf = [UInt8](repeating: 0, count: 4096)
            var consecutiveMisses = 0

            while Date() < deadline {
                let remaining = min(max(deadline.timeIntervalSinceNow, 0.01), 0.15)
                var tv = timeval(tv_sec: 0, tv_usec: Int32(remaining * 1_000_000))
                setsockopt(sockFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                var sender = sockaddr_in()
                var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &sender) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(sockFd, &buf, buf.count, 0, sa, &senderLen)
                    }
                }
                let recvTime = mach_absolute_time()

                guard n > 0 else {
                    consecutiveMisses += 1
                    lock.lock()
                    let done = sendingDone
                    lock.unlock()
                    if done && consecutiveMisses >= 5 { break }
                    continue
                }
                consecutiveMisses = 0

                // Parse ICMP response (IP_STRIPHDR: ICMP starts at byte 0)
                guard n >= 8 else { continue }
                let icmpType = buf[0]
                var matchedSeq: UInt16?
                var isDestReply = false

                if icmpType == 0 { // Echo Reply
                    matchedSeq = UInt16(buf[6]) << 8 | UInt16(buf[7])
                    isDestReply = true
                } else if icmpType == 11 || icmpType == 3 { // Time Exceeded / Dest Unreachable
                    let innerIPOffset = 8
                    guard n >= innerIPOffset + 20 else { continue }
                    let ihl = Int(buf[innerIPOffset] & 0x0F) * 4
                    let innerICMPOff = innerIPOffset + ihl
                    guard n >= innerICMPOff + 8 else { continue }
                    matchedSeq = UInt16(buf[innerICMPOff + 6]) << 8 | UInt16(buf[innerICMPOff + 7])
                    if icmpType == 3 { isDestReply = true }
                }

                guard let seq = matchedSeq, let hop = seqToHop[seq] else { continue }

                var addrBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sender.sin_addr, &addrBuf, socklen_t(INET_ADDRSTRLEN))
                let senderIP = String(cString: addrBuf)

                lock.lock()
                if let sendTime = sendTimes[seq] {
                    let latencyMs = Double(recvTime - sendTime) * numer / denom / 1_000_000.0
                    responses[hop] = (senderIP, latencyMs)
                    if isDestReply { destHop = min(destHop, hop) }
                }
                let complete = destHop < maxHops
                    && (1...destHop).allSatisfy({ responses[$0] != nil })
                lock.unlock()

                if complete { break }
            }
        }

        // --- Sender: current thread, paced 10ms apart ---
        for (hop, seq) in hopSeqs {
            // Stop sending past the destination once the receiver identifies it
            lock.lock()
            let currentDest = destHop
            lock.unlock()
            if currentDest < maxHops && hop > currentDest { break }

            var ttl = Int32(hop)
            setsockopt(sockFd, IPPROTO_IP, IP_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))

            let packet = buildPacket(sequence: seq)
            let sendTime = mach_absolute_time()

            lock.lock()
            sendTimes[seq] = sendTime
            lock.unlock()

            _ = packet.withUnsafeBytes { rawBuf in
                withUnsafeMutablePointer(to: &destAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(sockFd, rawBuf.baseAddress, packet.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            if hop < maxHops { usleep(10_000) } // 10ms between sends
        }

        lock.lock()
        sendingDone = true
        lock.unlock()

        // Wait for receiver to finish (bounded by timeout deadline)
        recvGroup.wait()

        // Build results
        lock.lock()
        let finalDestHop = destHop
        let finalResponses = responses
        lock.unlock()

        return (1...finalDestHop).map { hop in
            if let resp = finalResponses[hop] {
                return HopResult(hop: hop, address: resp.address, latencyMs: resp.latencyMs)
            } else {
                return HopResult(hop: hop, address: "", latencyMs: -1)
            }
        }
    }

    // MARK: - Packet Construction

    private func buildPacket(sequence: UInt16) -> Data {
        var packet = Data(count: 16)

        packet[0] = 8  // Type: Echo Request
        packet[1] = 0  // Code
        // Checksum at [2..3] — filled below
        packet[4] = UInt8(identifier >> 8)
        packet[5] = UInt8(identifier & 0xFF)
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)

        var ts = mach_absolute_time()
        withUnsafeBytes(of: &ts) { tsBytes in
            for i in 0..<8 { packet[8 + i] = tsBytes[i] }
        }

        // Compute checksum — required because some routers/firewalls validate
        // ICMP checksums on forwarded packets and drop malformed ones.
        var sum: UInt32 = 0
        for i in stride(from: 0, to: packet.count - 1, by: 2) {
            sum += UInt32(packet[i]) << 8 | UInt32(packet[i + 1])
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        let cksum = ~UInt16(sum & 0xFFFF)
        packet[2] = UInt8(cksum >> 8)
        packet[3] = UInt8(cksum & 0xFF)

        return packet
    }

    // MARK: - Utilities

    private func resolveHost(_ host: String) -> sockaddr_in? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }

}
