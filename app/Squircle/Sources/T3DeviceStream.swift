import AVFoundation
import ImageIO
import Synchronization
import UIKit
import VideoToolbox

struct SimulatorTarget: Hashable {
    let deviceID: String
    let hostID: String
    init?(deviceID: String?, hostID: String?) {
        guard let deviceID, UUID(uuidString:deviceID) != nil,
              let hostID, !hostID.isEmpty else { return nil }
        self.deviceID = deviceID; self.hostID = hostID
    }
}

/// T3's AVCC envelopes may be split or coalesced arbitrarily by HTTP.
/// The declared packet bound also bounds retained incomplete input.
struct AVCCFramer {
    static let maximumPacketSize = 8 * 1024 * 1024
    private var pending = Data()
    mutating func consume(_ bytes:Data, emit:(UInt8,Data) throws -> Void) throws {
        pending.append(bytes)
        var offset = 0
        while pending.count - offset >= 4 {
            let length = pending[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            guard length >= 1, length <= Self.maximumPacketSize else { throw ClientError.response("Simulator AVCC envelope") }
            guard pending.count - offset >= length + 4 else { break }
            try emit(pending[offset+4],pending.subdata(in:offset+5..<offset+4+length))
            offset += length + 4
        }
        if offset > 0 { pending = pending.subdata(in:offset..<pending.count) }
    }
}

/// The video renderers showing one simulator. Pictures go to them straight
/// from the decoding queue, each at its scheduled host time on the
/// renderer's own clock, so a busy main actor never delays or bunches them.
/// The main actor only adds and removes renderers.
final class SimulatorOutput: @unchecked Sendable {
    /// Weak: a screen that went away without detaching leaves nothing behind.
    private struct Target { weak var renderer: AVSampleBufferVideoRenderer?; var last: CFTimeInterval }
    private struct State { var targets: [ObjectIdentifier: Target] = [:]; var format: CMVideoFormatDescription? }
    private let state = Mutex(State())

    /// Starts showing on `renderer`, with `picture` now if there is one.
    func add(_ renderer: AVSampleBufferVideoRenderer, showing picture: CVPixelBuffer?) {
        state.withLock { state in
            var target = Target(renderer: renderer, last: 0)
            if let picture { Self.enqueue(picture, at: CACurrentMediaTime(), on: &target, format: &state.format) }
            state.targets[ObjectIdentifier(renderer)] = target
        }
    }

    /// Stops showing on `renderer`; it keeps its current picture.
    func remove(_ renderer: AVSampleBufferVideoRenderer) {
        state.withLock { state in
            if state.targets.removeValue(forKey: ObjectIdentifier(renderer)) != nil { renderer.flush() }
        }
    }

    func show(_ picture: CVPixelBuffer, at time: CFTimeInterval) {
        state.withLock { state in
            var gone = false
            for index in state.targets.values.indices {
                if state.targets.values[index].renderer == nil { gone = true; continue }
                Self.enqueue(picture, at: time, on: &state.targets.values[index], format: &state.format)
            }
            // A screen that went away without detaching: dropped once, when found.
            if gone { state.targets = state.targets.filter { $0.value.renderer != nil } }
        }
    }

    private static func enqueue(_ picture: CVPixelBuffer, at time: CFTimeInterval, on target: inout Target, format: inout CMVideoFormatDescription?) {
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: picture) {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: picture, formatDescriptionOut: &format)
        }
        guard let format, let renderer = target.renderer else { return }
        // Times only move forward on a renderer; a late picture shows at once.
        let shown = max(time, target.last + 0.000_1)
        target.last = shown
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: shown, preferredTimescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: picture, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}

/// Schedules pictures on a steady clock. T3's AVCC feed carries no
/// timestamps and arrives unevenly (the Mac's capture alone varies 9–50 ms
/// between frames, a relayed cellular link much more), so each picture is
/// given a time a little after it arrives: the previous one's plus the
/// recent frame interval, pulled gently toward a delay that covers the
/// measured jitter and recent stalls (a long gap followed by a burst),
/// which it forgets over a few seconds. A pause starts a new run on the same
/// clock; only a long one (a still screen) rebuilds the delay at once.
struct SimulatorPacer {
    static let minimumDelay: CFTimeInterval = 0.033
    static let maximumDelay: CFTimeInterval = 0.150
    /// Never more than this behind arrival; beyond it, catch up at once.
    static let maximumLead: CFTimeInterval = 0.300
    /// Arrivals further apart than this are a new run, not a slow frame.
    static let pause: CFTimeInterval = 0.100
    /// T3's feed is at most 60 fps.
    static let shortestInterval: CFTimeInterval = 1.0 / 60
    private var arrivals: [CFTimeInterval] = []
    private var last: CFTimeInterval?
    private var interval = shortestInterval
    private var lastGap: CFTimeInterval = 0
    private var jitter: CFTimeInterval = 0.011
    private var stall: (held: CFTimeInterval, at: CFTimeInterval) = (0, 0)

    func delay(at now: CFTimeInterval) -> CFTimeInterval {
        let stalled = stall.held * exp(-(now - stall.at) / 3)
        return min(Self.maximumDelay, max(Self.minimumDelay, 3 * jitter, stalled + 0.010))
    }

    /// The time to show a picture that arrived at `arrival`, no earlier than
    /// `earliest` (when it can first reach the screen). Never decreases.
    mutating func time(arrival: CFTimeInterval, earliest: CFTimeInterval) -> CFTimeInterval {
        if let previous = arrivals.last {
            let gap = arrival - previous
            // A burst right after a long gap: those pictures were held back.
            if gap < interval / 2, lastGap > interval * 1.5 {
                let held = lastGap - interval
                if held > stall.held * exp(-(arrival - stall.at) / 3) { stall = (held, arrival) }
            }
            lastGap = gap
            if gap > Self.pause { arrivals = [] }
        }
        arrivals.append(arrival)
        if arrivals.count > 17 { arrivals.removeFirst(arrivals.count - 17) }
        let delay = delay(at: arrival)
        var time = arrival + delay
        if let last, arrivals.count < 8 {
            time = max(last + interval, arrival + (lastGap > 0.3 ? delay : 0))
        } else if let last {
            interval = max(Self.shortestInterval, (arrivals[arrivals.count - 1] - arrivals[0]) / Double(arrivals.count - 1))
            jitter += (abs(arrivals[arrivals.count - 1] - arrivals[arrivals.count - 2] - interval) - jitter) / 16
            let ideal = last + interval
            time = ideal + (arrival + delay - ideal) * 0.1
        }
        if time - arrival > Self.maximumLead { time = arrival + delay }
        time = max(time, earliest, (last ?? -.infinity) + 0.001)
        last = time
        return time
    }
}

/// One synchronous hardware decode at a time, off the main actor. All reference
/// frames are decoded; only decoded pictures may be replaced before presentation.
private final class SimulatorH264Decoder {
    private final class Configuration {
        let format: CMVideoFormatDescription
        let session: VTDecompressionSession
        init(avcC:Data) throws {
            let bytes = [UInt8](avcC)
            guard bytes.count >= 7, bytes[0] == 1 else { throw ClientError.response("Simulator avcC") }
            let nalLength = Int(bytes[4] & 3) + 1
            guard [1,2,4].contains(nalLength) else { throw ClientError.response("Simulator NAL length") }
            var offset = 6, parameterSets = [Data]()
            func readSets(_ count:Int) throws {
                guard count > 0 else { throw ClientError.response("Simulator parameter sets") }
                for _ in 0..<count {
                    guard offset + 2 <= bytes.count else { throw ClientError.response("Simulator parameter length") }
                    let size = Int(bytes[offset]) << 8 | Int(bytes[offset+1]); offset += 2
                    guard size > 0, offset + size <= bytes.count else { throw ClientError.response("Simulator parameter data") }
                    parameterSets.append(Data(bytes[offset..<offset+size])); offset += size
                }
            }
            try readSets(Int(bytes[5] & 31))
            guard offset < bytes.count else { throw ClientError.response("Simulator PPS") }
            let ppsCount = Int(bytes[offset]); offset += 1; try readSets(ppsCount)
            let pointers = parameterSets.map { data -> UnsafeMutablePointer<UInt8> in
                let p = UnsafeMutablePointer<UInt8>.allocate(capacity:data.count)
                data.copyBytes(to:p,count:data.count); return p
            }
            defer { pointers.forEach { $0.deallocate() } }
            var constantPointers = pointers.map { UnsafePointer($0) }, sizes = parameterSets.map(\.count)
            var description: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator:kCFAllocatorDefault,
                parameterSetCount:pointers.count,parameterSetPointers:&constantPointers,parameterSetSizes:&sizes,
                nalUnitHeaderLength:Int32(nalLength),formatDescriptionOut:&description)
            guard status == noErr, let description else { throw ClientError.response("Simulator H.264 description: \(status)") }
            format = description
            var decoder: VTDecompressionSession?
            var specification: [String:Any] = [:]
            #if !targetEnvironment(simulator)
            specification[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String] = true
            #endif
            let attributes: [String:Any] = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String:[:],kCVPixelBufferMetalCompatibilityKey as String:true]
            let created = VTDecompressionSessionCreate(allocator:kCFAllocatorDefault,formatDescription:format,
                decoderSpecification:specification as CFDictionary,imageBufferAttributes:attributes as CFDictionary,
                outputCallback:nil,decompressionSessionOut:&decoder)
            guard created == noErr, let decoder else { throw ClientError.response("Simulator H.264 decoder: \(created)") }
            session = decoder
            VTSessionSetProperty(session,key:kVTDecompressionPropertyKey_RealTime,value:kCFBooleanTrue)
            #if DEBUG
            print("Simulator H.264 decoder: \(CMVideoFormatDescriptionGetDimensions(format))")
            #endif
        }
        deinit { VTDecompressionSessionInvalidate(session) }
    }
    private enum Phase { case waiting, awaitingKeyframe(Configuration), decoding(Configuration) }
    private var phase: Phase = .waiting
    private var sequence: Int64 = 0
    func consume(tag:UInt8,payload:Data) throws -> CVPixelBuffer? {
        if tag == 1 { phase = .awaitingKeyframe(try Configuration(avcC:payload)); return nil }
        guard tag == 2 || tag == 3 else { return nil } // The JPEG seed is `SimulatorSeed`'s; never play JPEG.
        let config: Configuration
        switch phase {
        case .waiting: throw ClientError.response("Simulator missing H.264 configuration")
        case .awaitingKeyframe(let current): guard tag == 2 else { return nil }; config = current; phase = .decoding(current)
        case .decoding(let current): config = current
        }
        guard !payload.isEmpty else { throw ClientError.response("Simulator empty H.264 frame") }
        var block: CMBlockBuffer?
        let allocated = CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:payload.count,
            blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:payload.count,flags:0,blockBufferOut:&block)
        guard allocated == noErr, let block else { throw ClientError.response("Simulator H.264 block") }
        let copied = payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block,offsetIntoDestination:0,dataLength:payload.count) }
        guard copied == noErr else { throw ClientError.response("Simulator H.264 data") }
        var sample: CMSampleBuffer?, size = payload.count
        var timing = CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:CMTime(value:sequence,timescale:60),decodeTimeStamp:.invalid)
        sequence += 1
        let ready = CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:config.format,
            sampleCount:1,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample)
        guard ready == noErr, let sample else { throw ClientError.response("Simulator H.264 sample") }
        var output: CVPixelBuffer?, outputStatus: OSStatus = noErr
        // Both flags clear guarantees the callback completes before this returns.
        // No temporal reordering or asynchronous decoder queue can accumulate.
        let status = VTDecompressionSessionDecodeFrame(config.session,sampleBuffer:sample,flags:[],infoFlagsOut:nil) {
            status, _, image, _, _ in outputStatus = status; output = image
        }
        guard status == noErr, outputStatus == noErr else { throw ClientError.response("Simulator H.264 decode: \(status)/\(outputStatus)") }
        return output
    }
}

/// The one still serve-sim sends first on every `stream.avcc` request (tag 4,
/// a JPEG of the current screen). A screen that doesn't change sends no H.264
/// at all, so this is its only picture: it is drawn once, until H.264 starts.
/// One picture per connection; never JPEG playback.
private enum SimulatorSeed {
    static func picture(_ jpeg: Data) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}

/// What the video request delivers: its response (the feed is open), then
/// pictures whenever the screen changes. A still screen sends none.
private enum SimulatorEvent { case open, picture(CVPixelBuffer) }

/// One authenticated H.264 request. Decoded pictures go to `output` at their
/// paced times and, newest only, to `events`. No codec fallback or priming
/// stream. URLSession delegates, decoding, pacing and presentation share a
/// serial queue, off the main actor. It lives as long as its connection:
/// silence is a still screen, not a dead stream.
private final class SimulatorVideo: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let events: AsyncThrowingStream<SimulatorEvent, Error>
    private let continuation: AsyncThrowingStream<SimulatorEvent, Error>.Continuation
    private let output: SimulatorOutput
    private var session: URLSession!
    private var framer = AVCCFramer()
    private var decoder = SimulatorH264Decoder()
    private var pacer = SimulatorPacer()
    /// Until H.264 draws, the seed may; afterwards it never replaces video.
    private var decoded = false
    #if DEBUG
    private var stats = SimulatorPacingStats()
    #endif
    init(request: URLRequest, output: SimulatorOutput) {
        self.output = output
        (events, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy:.bufferingNewest(1))
        super.init()
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInteractive
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil; config.urlCredentialStorage = nil
        // Static screens legitimately have no new frames. Startup has its own deadline.
        config.timeoutIntervalForRequest = 86400; config.timeoutIntervalForResource = 86400
        session = URLSession(configuration:config,delegate:self,delegateQueue:queue)
        continuation.onTermination = { [weak self] _ in self?.session.invalidateAndCancel() }
        session.dataTask(with:request).resume()
    }
    func close(_ error: Error = CancellationError()) {
        continuation.finish(throwing:error); session.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            close(ClientError.http("Simulator",(response as? HTTPURLResponse)?.statusCode ?? 0))
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
        continuation.yield(.open)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        decoder = SimulatorH264Decoder() // release decoder on its serial delegate queue
        close(error ?? ClientError.connection("Simulator video"))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let arrival = CACurrentMediaTime()
        do {
            try framer.consume(data) { tag, payload in
                if tag == 4 {
                    guard !decoded, let seed = SimulatorSeed.picture(payload) else { return }
                    output.show(seed,at:CACurrentMediaTime())
                    continuation.yield(.picture(seed)); return
                }
                guard let buffer = try decoder.consume(tag:tag,payload:payload) else { return }
                decoded = true
                let decoded = CACurrentMediaTime()
                let time = pacer.time(arrival:arrival,earliest:decoded + 0.002)
                #if DEBUG
                stats.add(arrival:arrival,decoded:decoded,time:time,delay:pacer.delay(at:arrival))
                #endif
                output.show(buffer,at:time)
                continuation.yield(.picture(buffer))
            }
        } catch { close(error) }
    }
}

#if DEBUG
/// Every 120 pictures: arrival rate and gaps, decode time, and how far ahead
/// of arrival pictures are scheduled (the jitter buffer's added delay).
private struct SimulatorPacingStats {
    private var arrivals: [CFTimeInterval] = [], decodes: [CFTimeInterval] = [], leads: [CFTimeInterval] = []
    private var delay: CFTimeInterval = 0
    mutating func add(arrival: CFTimeInterval, decoded: CFTimeInterval, time: CFTimeInterval, delay: CFTimeInterval) {
        arrivals.append(arrival); decodes.append(decoded - arrival); leads.append(time - arrival); self.delay = delay
        guard arrivals.count == 121 else { return }
        func ms(_ values: [CFTimeInterval], _ q: Double) -> Int { Int(values.sorted()[min(values.count - 1, Int(Double(values.count) * q))] * 1000) }
        let gaps = zip(arrivals.dropFirst(), arrivals).map { $0 - $1 }
        print("Simulator pacing: \(Int(120 / (arrivals[120] - arrivals[0]))) fps, gap p50 \(ms(gaps, 0.5)) p90 \(ms(gaps, 0.9)) max \(ms(gaps, 1)) ms, decode p90 \(ms(decodes, 0.9)) ms, scheduled +\(ms(leads, 0.5))/+\(ms(leads, 0.95)) ms (p50/p95), target \(Int(delay * 1000)) ms")
        arrivals = [arrivals[120]]; decodes = []; leads = []
    }
}
#endif

/// Owns partial startup so cancellation releases resources before a channel exists.
@MainActor
private final class SimulatorAttempt {
    let video: SimulatorVideo
    var socket: URLSessionWebSocketTask?
    init(video:SimulatorVideo) { self.video = video }
    func close(_ error:Error = CancellationError()) {
        video.close(error); socket?.cancel(with:.goingAway,reason:nil)
    }
}

/// Exists only after video and the input handshake succeed.
/// Closing this channel ends both resources and its gesture queue.
@MainActor
private final class SimulatorChannel {
    let socket: URLSessionWebSocketTask
    let video: SimulatorVideo
    private enum Gesture { case idle, dragging(CGPoint), closed }
    private var gesture: Gesture = .idle
    private var inputTail: Task<Void,Never>?
    init(socket: URLSessionWebSocketTask, video: SimulatorVideo) { self.socket = socket; self.video = video }
    func close() {
        gesture = .closed; inputTail?.cancel(); inputTail = nil
        socket.cancel(with:.goingAway,reason:nil); video.close()
    }
    func send(tag:UInt8,payload:JSONValue) async throws {
        if case .closed = gesture { throw CancellationError() }
        var data = Data([tag]); data.append(try JSONEncoder().encode(payload)); try await socket.send(.data(data))
    }
    func touch(_ phase:String,point:CGPoint) {
        switch (phase,gesture) {
        case ("begin",.idle): gesture = .dragging(point)
        case ("move",.dragging): gesture = .dragging(point)
        case ("end",.dragging): gesture = .idle
        default: return
        }
        let previous = inputTail
        inputTail = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do { try await self.send(tag:3,payload:["type": .string(phase), "x": .number(Double(point.x)), "y": .number(Double(point.y))]) }
            catch { self.close() }
        }
    }
}

@MainActor
final class T3DeviceStream {
    private enum Phase { case connecting(SimulatorAttempt), interactive(SimulatorChannel), reconnecting(String) }
    private enum Lifetime { case stopped, running(UUID,Task<Void,Never>,Phase) }
    private var lifetime: Lifetime = .stopped
    private let http: T3HTTP
    private let base: String
    let target: SimulatorTarget
    /// The newest picture, on the main actor (it is already on screen).
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onScreen: ((JSONValue) -> Void)?
    var onStatus: ((String?) -> Void)?
    var onInteractive: ((Bool) -> Void)?
    var isInteractive: Bool { if case .running(_,_,.interactive) = lifetime { return true }; return false }
    let codec = "h264"
    let output: SimulatorOutput
    init(http:T3HTTP,base:String,target:SimulatorTarget,output:SimulatorOutput) {
        self.http = http; self.base = base + "/vendor/serve-sim"; self.target = target; self.output = output
    }
    func start() {
        guard case .stopped = lifetime else { return }
        let id = UUID()
        let worker = Task { [weak self] in
            var delay = 1
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.connect(id); return }
                catch {
                    guard self.owns(id), !Task.isCancelled else { return }
                    self.set(.reconnecting("Reconnecting simulator…"),id:id)
                    try? await Task.sleep(for:.seconds(delay)); delay = min(8,delay * 2)
                }
            }
        }
        lifetime = .running(id,worker,.reconnecting("Connecting simulator…")); publish()
    }
    func stop() {
        let previous = lifetime; lifetime = .stopped
        if case .running(_,let worker,let phase) = previous {
            worker.cancel()
            switch phase {
            case .connecting(let attempt): attempt.close()
            case .interactive(let channel): channel.close()
            case .reconnecting: break
            }
        }
        publish()
    }
    private func owns(_ id:UUID) -> Bool { if case .running(let current,_,_) = lifetime { return current == id }; return false }
    private func set(_ phase:Phase,id:UUID) {
        guard case .running(let current,let worker,_) = lifetime, current == id else { return }
        lifetime = .running(id,worker,phase); publish()
    }
    private func publish() {
        onInteractive?(isInteractive)
        switch lifetime {
        case .stopped: onStatus?("Paused")
        case .running(_,_,.connecting): onStatus?("Connecting simulator…")
        case .running(_,_,.interactive): onStatus?(nil)
        case .running(_,_,.reconnecting(let message)): onStatus?(message)
        }
    }
    private func connect(_ id:UUID) async throws {
        let video = SimulatorVideo(request:try http.request(base + "/helper/\(target.deviceID)/stream.avcc",
            query:[URLQueryItem(name:"hostId",value:target.hostID)]),output:output)
        // A failed input handshake also releases video. The startup deadline
        // covers the two handshakes only (video's response, input's config),
        // never pictures: a still screen sends none. It cancels the actual
        // resources, so no orphan receive task can hold a retry open.
        let attempt = SimulatorAttempt(video:video); set(.connecting(attempt),id:id)
        let deadline = Task {
            try? await Task.sleep(for:.seconds(20))
            guard !Task.isCancelled else { return }
            attempt.close(ClientError.connection("Simulator startup"))
        }
        defer { deadline.cancel(); attempt.close() }
        var events = video.events.makeAsyncIterator()
        guard let first = try await events.next() else { throw ClientError.connection("Simulator video") }
        try Task.checkCancellation(); guard owns(id) else { throw CancellationError() }
        if case .picture(let picture) = first { onFrame?(picture) }
        let ws = http.session.webSocketTask(with:try await http.socketRequest(base + "/helper/ws",query:[
            URLQueryItem(name:"device",value:target.deviceID),URLQueryItem(name:"hostId",value:target.hostID)]))
        attempt.socket = ws; ws.resume()
        let channel = SimulatorChannel(socket:ws,video:video)
        try await channel.send(tag:0x0d,payload:["enabled": false])
        // The helper's config confirms that HID is ready; a cached picture alone
        // never enables input. Video keeps playing meanwhile.
        while true {
            if let screen = try await screenMessage(ws) {
                guard owns(id), !Task.isCancelled else { throw CancellationError() }
                onScreen?(screen); break
            }
        }
        try Task.checkCancellation(); guard owns(id) else { throw CancellationError() }
        deadline.cancel(); set(.interactive(channel),id:id)
        let input = Task {
            do { while !Task.isCancelled { if let screen = try await self.screenMessage(ws), self.owns(id) { self.onScreen?(screen) } } }
            catch { video.close(error) }
        }
        let heartbeat = Task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for:.seconds(20)); try Task.checkCancellation()
                    ws.sendPing { error in if let error { video.close(error) } }
                }
            } catch { if !Task.isCancelled { video.close(error) } }
        }
        defer { input.cancel(); heartbeat.cancel(); channel.close() }
        // Connected until either connection fails (the input socket's pings
        // detect a dead path); a quiet stream keeps its last picture.
        while let event = try await events.next() {
            try Task.checkCancellation(); guard owns(id) else { throw CancellationError() }
            if case .picture(let picture) = event { onFrame?(picture) }
        }
        throw ClientError.connection("Simulator video")
    }
    private func screenMessage(_ ws:URLSessionWebSocketTask) async throws -> JSONValue? {
        let message = try await ws.receive()
        if case .data(let data) = message, data.first == 0x82 {
            return try JSONDecoder().decode(JSONValue.self,from:Data(data.dropFirst()))
        }
        return nil
    }
    func send(tag:UInt8,payload:JSONValue) async throws {
        guard case .running(let id,_,.interactive(let channel)) = lifetime else { throw ClientError.connection("Simulator input") }
        do { try await channel.send(tag:tag,payload:payload) }
        catch {
            if owns(id) { set(.reconnecting("Reconnecting simulator…"),id:id); channel.close() }
            throw error
        }
    }
    func touch(_ phase:String,point:CGPoint) {
        if case .running(_,_,.interactive(let channel)) = lifetime { channel.touch(phase,point:point) }
    }
}
/// Coordinate mapping between a displayed simulator picture and T3's input
/// contract. The picture itself is drawn flat by `SimulatorScreen`.
enum SimulatorSurface {
    /// Aspect-fit placement of a `size` picture inside `bounds`.
    static func point(_ point: CGPoint, bounds: CGRect, size: CGSize, orientation: String) -> CGPoint? {
        let rect = AVMakeRect(aspectRatio:size,insideRect:CGRect(origin:.zero,size:bounds.size))
        guard rect.contains(point) else { return nil }
        return input(CGPoint(x:(point.x-rect.minX)/rect.width,y:(point.y-rect.minY)/rect.height),size:size,orientation:orientation)
    }
    /// `picture` is normalized within the framebuffer, origin top left.
    static func input(_ picture: CGPoint, size: CGSize, orientation: String) -> CGPoint {
        let x = picture.x, y = picture.y
        // The upstream input contract uses portrait coordinates for portrait framebuffers.
        if size.width < size.height {
            switch orientation { case "landscape_left": return CGPoint(x:y,y:1-x)
            case "landscape_right": return CGPoint(x:1-y,y:x)
            case "portrait_upside_down": return CGPoint(x:1-x,y:1-y)
            default: break }
        }
        return CGPoint(x:x,y:y)
    }
}
