import UIKit
import CoreMedia
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
    #if DEBUG
    private var decoded = 0, totalMilliseconds = 0.0, maximumMilliseconds = 0.0
    #endif
    func consume(tag:UInt8,payload:Data) throws -> CVPixelBuffer? {
        if tag == 1 { phase = .awaitingKeyframe(try Configuration(avcC:payload)); return nil }
        guard tag == 2 || tag == 3 else { return nil } // Ignore the host's one-off JPEG seed; never play JPEG.
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
        #if DEBUG
        let started = CACurrentMediaTime()
        #endif
        // Both flags clear guarantees the callback completes before this returns.
        // No temporal reordering or asynchronous decoder queue can accumulate.
        let status = VTDecompressionSessionDecodeFrame(config.session,sampleBuffer:sample,flags:[],infoFlagsOut:nil) {
            status, _, image, _, _ in outputStatus = status; output = image
        }
        guard status == noErr, outputStatus == noErr else { throw ClientError.response("Simulator H.264 decode: \(status)/\(outputStatus)") }
        #if DEBUG
        let elapsed = (CACurrentMediaTime() - started) * 1000
        decoded += 1; totalMilliseconds += elapsed; maximumMilliseconds = max(maximumMilliseconds,elapsed)
        if decoded % 60 == 0 { print("Simulator H.264: \(decoded) decoded, mean \(totalMilliseconds / Double(decoded)) ms, max \(maximumMilliseconds) ms, one decode in flight") }
        #endif
        return output
    }
}

/// One authenticated H.264 request and one newest decoded picture. No codec
/// fallback or priming stream. URLSession delegates and decoding share a serial queue.
private final class SimulatorVideo: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let frames: AsyncThrowingStream<CVPixelBuffer, Error>
    private let continuation: AsyncThrowingStream<CVPixelBuffer, Error>.Continuation
    private var session: URLSession!
    private var framer = AVCCFramer()
    private var decoder = SimulatorH264Decoder()
    init(request: URLRequest) {
        (frames, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy:.bufferingNewest(1))
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
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        decoder = SimulatorH264Decoder() // release decoder on its serial delegate queue
        close(error ?? ClientError.connection("Simulator video"))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try framer.consume(data) { tag, payload in
                if let frame = try decoder.consume(tag:tag,payload:payload) { continuation.yield(frame) }
            }
        } catch { close(error) }
    }
}

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
            do { try await self.send(tag:3,payload:.from(["type":phase,"x":point.x,"y":point.y])) }
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
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onScreen: ((JSONValue) -> Void)?
    var onStatus: ((String?) -> Void)?
    var onInteractive: ((Bool) -> Void)?
    var isInteractive: Bool { if case .running(_,_,.interactive) = lifetime { return true }; return false }
    let codec = "h264"
    init(http:T3HTTP,base:String,target:SimulatorTarget) {
        self.http = http; self.base = base + "/vendor/serve-sim"; self.target = target
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
            query:[URLQueryItem(name:"hostId",value:target.hostID)]))
        // A failed input handshake also releases video. A startup timeout cancels
        // the actual resources, so no orphan receive task can hold a retry open.
        let attempt = SimulatorAttempt(video:video); set(.connecting(attempt),id:id)
        let deadline = Task {
            try? await Task.sleep(for:.seconds(20))
            guard !Task.isCancelled else { return }
            attempt.close(ClientError.connection("Simulator startup"))
        }
        defer { deadline.cancel(); attempt.close() }
        var frames = video.frames.makeAsyncIterator()
        guard let first = try await frames.next() else { throw ClientError.connection("Simulator video") }
        try Task.checkCancellation(); guard owns(id) else { throw CancellationError() }
        onFrame?(first)
        let ws = http.session.webSocketTask(with:try await http.socketRequest(base + "/helper/ws",query:[
            URLQueryItem(name:"device",value:target.deviceID),URLQueryItem(name:"hostId",value:target.hostID)]))
        attempt.socket = ws; ws.resume()
        let channel = SimulatorChannel(socket:ws,video:video)
        try await channel.send(tag:0x0d,payload:.from(["enabled":false]))
        // The helper's config confirms that HID is ready; a cached picture alone
        // never enables input. Video continues buffering just its newest frame.
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
        while let buffer = try await frames.next() {
            try Task.checkCancellation(); guard owns(id) else { throw CancellationError() }; onFrame?(buffer)
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
    #if DEBUG
    /// Exercises real input loss in integration tests without changing the host.
    func disconnectInputForTesting() {
        if case .running(_,_,.interactive(let channel)) = lifetime { channel.socket.cancel(with:.goingAway,reason:nil) }
    }
    #endif
}
/// Coordinate mapping between a displayed simulator picture and T3's input
/// contract. The picture itself is drawn flat by `SimulatorScreen`.
enum SimulatorSurface {
    /// Aspect-fit placement of a `size` picture inside `bounds`.
    static func point(_ point: CGPoint, bounds: CGRect, size: CGSize, orientation: String) -> CGPoint? {
        let scale = min(bounds.width/size.width,bounds.height/size.height)
        let rect = CGRect(x:(bounds.width-size.width*scale)/2,y:(bounds.height-size.height*scale)/2,width:size.width*scale,height:size.height*scale)
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
