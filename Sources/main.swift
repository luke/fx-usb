import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import SwiftUI

// The mic's audio clock: exactly 56,250 Hz (a 1 kHz factory tone measures 999.999 Hz), and
// its microsecond timer runs from the same crystal. One DMA half = 32 frames = 568.89 µs.
let deviceRate = 56250.0
let blockFrames = 32
let periodMicroseconds = 32e6/deviceRate
/// Firmware versions this reader has been verified on (the DMA layout check guards others).
let testedFirmware: Set<String> = ["1.1.1","1.1.2"]

struct BridgeError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

func little32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8 | UInt32(bytes[offset+2]) << 16 | UInt32(bytes[offset+3]) << 24
}

/// Top-level statements without comments, indentation shrunk from four spaces to one: the
/// mic's Python heap is small and fragmented, so it must compile one function at a time.
func programChunks(_ source: String) -> [String] {
    var chunks: [String] = [], current: [String] = []
    for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let body = raw.drop { $0 == " " }
        if body.isEmpty || body.hasPrefix("#") { continue }
        let indent = raw.count-body.count
        if indent == 0, let last = current.last, !last.hasPrefix("@") { chunks.append(current.joined(separator:"\n")+"\n"); current = [] }
        current.append(String(repeating:" ",count:indent/4)+body)
    }
    if !current.isEmpty { chunks.append(current.joined(separator:"\n")+"\n") }
    return chunks
}

func readerProgram() throws -> String {
    guard let url = Bundle.main.url(forResource:"fxmic_reader",withExtension:"py"),
          let text = try? String(contentsOf:url,encoding:.utf8) else { throw BridgeError("The mic reader is missing from the app. Rebuild FX Mic.") }
    return text
}

/// One DMA half from the mic: its hardware completion stamp and 32 samples.
struct Block { let seq: UInt16; let stamp: UInt32; let samples: [Int16] }

/// 'FXP4' packets (see fxmic_reader.py): a 12-byte header with block 0's full stamp,
/// then up to 8 blocks of 66 bytes (stamp low 16 bits + 32 PCM16 samples).
/// Keep decoder independent of USB read boundaries: reads may split any packet.
struct PacketDecoder {
    private var pending: [UInt8] = []
    /// Latest 'FXS1' status packet (16 bytes: effect, sample, buttons, handle, flags, 0, accel x/y/z).
    var status: (effect: Int8, sample: Int8, buttons: UInt8, handle: UInt8, flags: UInt8, accel: (Int16,Int16,Int16))?
    mutating func feed<C: Collection>(_ bytes: C) -> [Block] where C.Element == UInt8 {
        pending.append(contentsOf: bytes)
        var blocks: [Block] = []
        var i = 0
        while pending.count-i >= 12 {
            if pending[i] == 0x46, pending[i+1] == 0x58, pending[i+2] == 0x53, pending[i+3] == 0x31 {
                if pending.count-i < 16 { break }
                func s16(_ o: Int) -> Int16 { Int16(bitPattern:UInt16(pending[i+o]) | UInt16(pending[i+o+1]) << 8) }
                status = (Int8(bitPattern:pending[i+4]),Int8(bitPattern:pending[i+5]),pending[i+6],pending[i+7],pending[i+8],(s16(10),s16(12),s16(14)))
                i += 16
                continue
            }
            guard pending[i] == 0x46, pending[i+1] == 0x58, pending[i+2] == 0x50, pending[i+3] == 0x34, (1...8).contains(pending[i+10]) else { i += 1; continue }
            let count = Int(pending[i+10])
            if pending.count-i < 12+66*count { break }
            let stamp0 = little32(pending,i+4)
            let seq0 = UInt16(pending[i+8]) | UInt16(pending[i+9]) << 8
            for b in 0..<count {
                let o = i+12+66*b
                let low = UInt16(pending[o]) | UInt16(pending[o+1]) << 8
                let stamp = stamp0 &+ UInt32(bitPattern:Int32(Int16(bitPattern:low &- UInt16(truncatingIfNeeded:stamp0))))
                let samples = (0..<blockFrames).map { Int16(bitPattern:UInt16(pending[o+2+$0*2]) | UInt16(pending[o+3+$0*2]) << 8) }
                blocks.append(Block(seq:seq0 &+ UInt16(b),stamp:stamp,samples:samples))
            }
            i += 12+66*count
        }
        pending.removeFirst(i)
        return blocks
    }
}

/// Places blocks on the mic's own clock using the DMA hardware stamps. A block that never
/// arrived becomes a short fade of the previous block instead of a hole that shortens time.
struct Timeline {
    private var lastStamp: UInt32?
    private var lastSeq: UInt16?
    private var lastBlock = [Float](repeating:0,count:blockFrames)
    private var lastInput: Float = 0
    private var highpass: Float = 0
    var lostBlocks = 0, sequenceBreaks = 0, restarts = 0
    static let maxConcealedBlocks = 88  // 50 ms; longer outages are left to the output buffer
    mutating func append(_ block: Block, gain: Float, muted: Bool, to output: inout [Float]) {
        if let seq = lastSeq, block.seq != seq &+ 1 { sequenceBreaks += 1 }
        lastSeq = block.seq
        if let last = lastStamp {
            let blocks = Int((Double(Int32(bitPattern:block.stamp &- last))/periodMicroseconds).rounded())
            if blocks <= 0 { return }  // stale or repeated block
            if blocks > 17578 { restarts += 1 }  // >10 s: the reader restarted, don't invent audio
            else if blocks > 1 { lostBlocks += blocks-1; conceal(min(blocks-1,Timeline.maxConcealedBlocks),into:&output) }
        }
        lastStamp = block.stamp
        for (i,value) in block.samples.enumerated() {
            let x = Float(value)/32768
            highpass = x-lastInput+0.995*highpass
            lastInput = x
            let y = muted ? 0 : max(-1,min(1,highpass*gain))
            lastBlock[i] = y
            output.append(y)
        }
    }
    private mutating func conceal(_ blocks: Int, into output: inout [Float]) {
        let fade = Float(min(blocks,4)*blockFrames)
        var n: Float = 0
        for _ in 0..<blocks { for value in lastBlock { n += 1; output.append(value*max(0,1-n/fade)) } }
    }
}

@inline(__always) func hermite(_ x0: Float,_ x1: Float,_ x2: Float,_ x3: Float,_ t: Float) -> Float {
    let c1 = 0.5*(x2-x0)
    let c2 = x0-2.5*x1+2*x2-0.5*x3
    let c3 = 0.5*(x3-x0)+1.5*(x1-x2)
    return ((c3*t+c2)*t+c1)*t+x1
}

/// 56,250 → 48,000 Hz for recordings: exactly 75 input samples per 64 output samples, so a
/// file follows the mic's clock with no drift.
struct RecordingResampler {
    private var buffer: [Float] = [0]
    private var phase = 0
    mutating func process(_ input: [Float]) -> [Float] {
        buffer.append(contentsOf:input)
        var output: [Float] = []
        output.reserveCapacity(input.count)
        while true {
            let i = 1+phase/64
            if i+2 >= buffer.count { break }
            output.append(hermite(buffer[i-1],buffer[i],buffer[i+1],buffer[i+2],Float(phase%64)/64))
            phase += 75
        }
        let consumed = phase/64
        buffer.removeFirst(consumed); phase -= consumed*64
        return output
    }
}

final class UnfairLock {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>
    init() { pointer = .allocate(capacity:1); pointer.initialize(to:os_unfair_lock()) }
    deinit { pointer.deallocate() }
    func lock() { os_unfair_lock_lock(pointer) }
    func unlock() { os_unfair_lock_unlock(pointer) }
}

/// Bridges the mic's clock to the output device's clock. USB delivers blocks every few
/// milliseconds (up to ~20 ms late while the mic plays a sample with the jack in); the
/// output pulls 5–20 ms at a time. The buffer holds ~40 ms and nudges
/// the resampling ratio (at most ±0.5%, normally a few ppm) to stay there, so neither side ever
/// runs dry or piles up. If the mic stops, output fades out and refills before resuming.
final class JitterBuffer {
    private let lock = UnfairLock()
    private let capacity = 1 << 16
    private let ring: UnsafeMutablePointer<Float>
    private var written = 0, read = 0
    private var fraction = 0.0
    private var outputRate = 48000.0
    private var smoothedFill = 0.0
    private var priming = true
    private var fadeIn: Float = 1
    private var lastOutput: Float = 0
    let target: Double
    private(set) var underflows = 0, overflowSkips = 0
    private(set) var ratioPPM = 0.0
    private(set) var renderedFrames = 0, consumedStart = 0, producedTotal = 0
    init(targetSeconds: Double = 0.040) { target = targetSeconds*deviceRate; ring = .allocate(capacity:capacity); ring.initialize(repeating:0,count:capacity) }
    deinit { ring.deallocate() }
    func push(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        for value in samples { ring[written & (capacity-1)] = value; written += 1 }
        producedTotal += samples.count
        // Nobody is pulling (calls off): keep only recent audio so a later start is fresh.
        if written-read > capacity/2 { read = written-Int(target); fraction = 0 }
    }
    func start(rate: Double) {
        lock.lock(); defer { lock.unlock() }
        outputRate = rate; priming = true; smoothedFill = target; fraction = 0
        if written-read > Int(target) { read = written-Int(target) }
        consumedStart = read; renderedFrames = 0
    }
    func stats() -> (fillMs: Double, ppm: Double, underflows: Int, skips: Int) {
        lock.lock(); defer { lock.unlock() }
        return (smoothedFill/deviceRate*1000, ratioPPM, underflows, overflowSkips)
    }
    func effectiveRatioPPM() -> Double {
        lock.lock(); defer { lock.unlock() }
        return renderedFrames == 0 ? 0 : (Double(read-consumedStart)/Double(renderedFrames)/(deviceRate/outputRate)-1)*1e6
    }
    /// Fills `frames` interleaved frames of `channels` channels. Called on the audio I/O thread.
    func render(_ output: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        lock.lock(); defer { lock.unlock() }
        var available = Double(written-read)-fraction
        if available > target+0.120*deviceRate {
            let skip = Int(available-target); read += skip; consumedStart += skip; available -= Double(skip); overflowSkips += 1
        }
        smoothedFill += (available-smoothedFill)*0.02
        if priming {
            if available >= target {
                // Still silent: drop any surplus now instead of draining it by pitch later.
                let surplus = Int(available-target); read += surplus; consumedStart += surplus; available -= Double(surplus)
                priming = false; fadeIn = 0; smoothedFill = available
            }
            else { for i in 0..<frames*channels { output[i] = 0 }; return }
        }
        let correction = max(-0.005,min(0.005,(smoothedFill-target)/deviceRate*0.1))
        ratioPPM = correction*1e6
        let step = deviceRate/outputRate*(1+correction)
        let mask = capacity-1
        renderedFrames += frames
        for frame in 0..<frames {
            var y: Float
            if written-read >= 3 {
                let x0 = ring[(read-1)&mask], x1 = ring[read&mask], x2 = ring[(read+1)&mask], x3 = ring[(read+2)&mask]
                y = hermite(x0,x1,x2,x3,Float(fraction))*fadeIn
                fadeIn = min(1,fadeIn+1/240)
                fraction += step
                let whole = Int(fraction); read += whole; fraction -= Double(whole)
            } else {
                if !priming { priming = true; underflows += 1 }
                y = lastOutput*0.97
            }
            lastOutput = y
            for channel in 0..<channels { output[frame*channels+channel] = y }
        }
    }
}

final class AudioState {
    let lock = NSLock()
    let buffer = JitterBuffer()
    let monitorBuffer = JitterBuffer(targetSeconds:0.030)
    /// Commands for the mic ('e'+digit, 's'+digit, 'p', 'q'); the USB thread sends them.
    var commands: [[UInt8]] = []
    func send(_ command: String) { lock.lock(); commands.append(Array(command.utf8)); lock.unlock() }
    var running = true
    var enabled = true
    var muted = false
    var gain: Float = 1
    var connected = false
    var status = "Looking for FX–MIC…"
    var level: Float = 0
    var packets = 0
    var lostBlocks = 0, sequenceBreaks = 0
    var maxReadGap = 0.0
    var totalFrames: UInt64 = 0
    var recording: FileHandle?
    var recordingURL: URL?
    var recordedBytes: UInt32 = 0
    var recordingSince: Date?
    var resampler = RecordingResampler()
    var mic = MicStatus()
    var firmware = ""
    func update(_ text: String, connected newValue: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        status = text; connected = newValue
        if !newValue { level = 0 }
    }
    func ingest(_ samples: [Float], timeline: Timeline, packets count: Int) {
        buffer.push(samples)
        monitorBuffer.push(samples)
        lock.lock(); defer { lock.unlock() }
        level = max(level*0.95, samples.map { abs($0) }.max() ?? 0)
        totalFrames += UInt64(samples.count); packets += count
        lostBlocks = timeline.lostBlocks; sequenceBreaks = timeline.sequenceBreaks
        if let recording {
            let pcm = resampler.process(samples).map { Int16(max(-32768,min(32767,Int(($0*32767).rounded())))) }
            let data = pcm.withUnsafeBytes { Data($0) }
            do { try recording.write(contentsOf:data); recordedBytes += UInt32(data.count) }
            catch { status = "Recording failed: \(error.localizedDescription)"; closeRecordingLocked() }
        }
    }
    func startRecording(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard recording == nil else { return }
        FileManager.default.createFile(atPath:url.path,contents:wavHeader(0))
        let file = try FileHandle(forWritingTo:url)
        try file.seekToEnd()
        recording = file; recordingURL = url; recordedBytes = 0; resampler = RecordingResampler(); recordingSince = Date()
    }
    func stopRecording() { lock.lock(); defer { lock.unlock() }; closeRecordingLocked() }
    private func closeRecordingLocked() {
        guard let file = recording else { return }
        try? file.seek(toOffset:0); try? file.write(contentsOf:wavHeader(recordedBytes)); try? file.close()
        recording = nil; recordingSince = nil
    }
}

func wavHeader(_ count: UInt32, rate: UInt32 = 48000) -> Data {
    var data = Data()
    func text(_ s: String) { data.append(Data(s.utf8)) }
    func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
    func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
    text("RIFF"); u32(36+count); text("WAVEfmt "); u32(16); u16(1); u16(1)
    u32(rate); u32(rate*2); u16(2); u16(16); text("data"); u32(count)
    return data
}

func writeWAV(_ samples: [Float], rate: UInt32, to path: String) throws {
    let pcm = samples.map { Int16(max(-32768,min(32767,Int(($0*32767).rounded())))) }
    var data = wavHeader(UInt32(pcm.count*2),rate:rate)
    pcm.withUnsafeBytes { data.append(contentsOf:$0) }
    try data.write(to:URL(fileURLWithPath:path))
}

final class USBReader {
    let state: AudioState
    var testSample: Int?
    init(_ state: AudioState) { self.state = state }
    func run() {
        while true {
            state.lock.lock(); let running = state.running; let enabled = state.enabled; state.lock.unlock()
            if !running { break }
            if !enabled { Thread.sleep(forTimeInterval:0.2); continue }
            let ports = ((try? FileManager.default.contentsOfDirectory(atPath:"/dev")) ?? []).filter { $0.hasPrefix("cu.usbmodemEP") }
            guard ports.count == 1 else {
                state.update(ports.isEmpty ? "Connect FX–MIC by USB-C and press its handle" : "Connect one FX–MIC at a time")
                Thread.sleep(forTimeInterval:1); continue
            }
            do { try session("/dev/"+ports[0]) }
            catch { state.update(String(describing:error)); Thread.sleep(forTimeInterval:1) }
        }
        state.update("Stopped")
    }
    private var scratch = [UInt8](repeating:0,count:65536)
    func readAvailable(_ fd: Int32) throws -> [UInt8] {
        let amount = Darwin.read(fd,&scratch,scratch.count)
        if amount > 0 { return Array(scratch.prefix(amount)) }
        if amount < 0 && errno != EAGAIN && errno != EINTR { throw BridgeError("USB disconnected") }
        return []
    }
    func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            let deadline = Date().addingTimeInterval(2)
            while offset < data.count {
                let n = Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),data.count-offset)
                if n > 0 { offset += n }
                else if (errno == EAGAIN || errno == EINTR) && Date() < deadline { usleep(1000) }
                else { throw BridgeError("Could not write to the mic’s USB console") }
            }
        }
    }
    func query(_ fd: Int32, _ statement: String) throws -> String {
        let request = Data(("\r"+statement+"; print('FXU_DONE')\r").utf8)
        var answer = [UInt8]()
        // The mic's console truncates large writes: send small chunks and drain its echo.
        for offset in stride(from:0,to:request.count,by:48) {
            try write(fd,request.subdata(in:offset..<min(offset+48,request.count)))
            usleep(3000); answer += try readAvailable(fd)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            answer += try readAvailable(fd)
            if let s = String(bytes:answer,encoding:.utf8), s.hasSuffix(">>> ") {
                if s.contains("Traceback") { throw BridgeError("The mic refused the reader: "+(s.components(separatedBy:"\r\n").dropLast().last ?? "")) }
                if s.contains("\r\nFXU_DONE\r\n") { return s }
            }
            usleep(1000)
        }
        throw BridgeError("The mic did not answer. Reconnect its USB cable.")
    }
    func session(_ port: String) throws {
        let fd = Darwin.open(port,O_RDWR|O_NOCTTY|O_NONBLOCK)
        guard fd >= 0 else { throw BridgeError("Mic busy or USB access unavailable") }
        var original = termios()
        guard tcgetattr(fd,&original) == 0 else { Darwin.close(fd); throw BridgeError("USB console unavailable") }
        guard ioctl(fd,TIOCEXCL) == 0 else { Darwin.close(fd); throw BridgeError("Another app is using the mic") }
        var raw = original; cfmakeraw(&raw); tcsetattr(fd,TCSANOW,&raw)
        defer {
            // Ctrl-C makes the reader's `finally` restore the factory DMA chain before it exits.
            try? write(fd,Data([3])); usleep(10000); try? write(fd,Data([13]))
            let until = Date().addingTimeInterval(1)
            var tail = [UInt8]()
            while Date() < until, !(String(bytes:tail.suffix(64),encoding:.utf8) ?? "").contains("FXU_STOPPED") {
                tail += (try? readAvailable(fd)) ?? []; usleep(3000)
            }
            if let sample = testSample { _ = try? query(fd,"spl.trigger(-1,\(sample),False)") }
            _ = try? query(fd,"exec(\"for _fxu_name in [n for n in globals() if n.startswith('_fxu')]:\\n    globals().pop(_fxu_name)\")")
            tcsetattr(fd,TCSANOW,&original); _ = ioctl(fd,TIOCNXCL); Darwin.close(fd)
        }
        state.update("Checking connected mic…")
        try write(fd,Data([3])); usleep(10000); try write(fd,Data([13])); usleep(50000); _ = try readAvailable(fd)
        let info = try query(fd,"print('FXU_VERSION', __import__('os').uname().machine)")
        guard info.contains("FXU_VERSION EP-2350 with RP2350") else { throw BridgeError("Connected device is not a supported FX–MIC") }
        let answer = try query(fd,"print('FXU_RELEASE', __import__('sys').implementation._machine)")
        guard let line = answer.components(separatedBy:"\r\n").first(where:{ $0.hasPrefix("FXU_RELEASE EP-2350 ") }) else { throw BridgeError("Connected device is not a supported FX–MIC") }
        // Other versions are allowed: the reader checks the mic's audio DMA layout before touching it.
        let firmware = String(line.dropFirst("FXU_RELEASE EP-2350 ".count))
        let firmwareNote = testedFirmware.contains(firmware) ? "firmware \(firmware)" : "firmware \(firmware), untested"
        state.lock.lock(); state.firmware = firmware; state.lock.unlock()
        for chunk in programChunks(try readerProgram()) {
            let literal = String(data:try JSONSerialization.data(withJSONObject:chunk,options:.fragmentsAllowed),encoding:.utf8)!
            _ = try query(fd,"exec("+literal+")")
        }
        if let sample = testSample { _ = try query(fd,"spl.trigger(-1,\(sample),True)") }
        try write(fd,Data("_fxu_run()\r".utf8))
        var decoder = PacketDecoder(), timeline = Timeline()
        var lastReceived = Date(), lastRead = Date()
        var pollFD = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
        var announced = false
        var preamble = [UInt8]()
        var gravity = 0.0, motion = 0.0
        while true {
            state.lock.lock(); let keep = state.running && state.enabled; let gain = state.gain; let muted = state.muted; state.lock.unlock()
            if !keep { return }
            state.lock.lock(); let commands = state.commands; state.commands = []; state.lock.unlock()
            for command in commands {
                // Ctrl-C interrupts the reader loop (and flushes the mic's stdin); the command follows.
                try write(fd,Data([3])); usleep(10000); try write(fd,Data(command))
            }
            _ = poll(&pollFD,1,20)
            let bytes = try readAvailable(fd)
            if bytes.isEmpty {
                if Date().timeIntervalSince(lastReceived) > 3 { throw BridgeError("Audio stream stopped. Reconnect the mic.") }
                continue
            }
            let now = Date()
            let packets = decoder.feed(bytes)
            if !announced && preamble.count < 4096 {
                preamble += bytes
                if let text = String(bytes:preamble,encoding:.utf8), text.contains("Traceback"), text.hasSuffix(">>> ") {
                    throw BridgeError("The mic stopped the reader: "+(text.components(separatedBy:"\r\n").dropLast().last ?? ""))
                }
            }
            if let st = decoder.status {
                decoder.status = nil
                let magnitude = (Double(st.accel.0)*Double(st.accel.0)+Double(st.accel.1)*Double(st.accel.1)+Double(st.accel.2)*Double(st.accel.2)).squareRoot()
                gravity = gravity == 0 ? magnitude : gravity*0.95+magnitude*0.05
                motion = max(motion*0.85,min(1,abs(magnitude-gravity)/6000))
                state.lock.lock()
                state.mic = MicStatus(effect:Int(st.effect),sample:Int(st.sample),buttons:st.buttons,handle:Double(st.handle)/255,
                                      effectPending:st.flags & 1 != 0,samplePending:st.flags & 2 != 0,motion:motion)
                state.lock.unlock()
            }
            if packets.isEmpty { continue }
            var samples: [Float] = []
            samples.reserveCapacity(packets.count*blockFrames+64)
            for block in packets { timeline.append(block,gain:gain,muted:muted,to:&samples) }
            state.lock.lock(); state.maxReadGap = max(state.maxReadGap, announced ? now.timeIntervalSince(lastRead) : 0); state.lock.unlock()
            lastReceived = now; lastRead = now
            if !announced { state.update("USB audio connected · \(firmwareNote) · hold handle to speak",connected:true); announced = true }
            state.ingest(samples,timeline:timeline,packets:packets.count)
        }
    }
}

struct AudioDevice { let id: AudioDeviceID; let name: String; let uid: String }
func audioDevices() -> [AudioDevice] {
    var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&ids) == noErr else { return [] }
    func property(_ id: AudioDeviceID,_ selector: AudioObjectPropertySelector) -> String {
        var a = AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var result: CFString = "" as CFString; var n = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to:&result) { AudioObjectGetPropertyData(id,&a,0,nil,&n,$0) }
        guard status == noErr else { return "" }
        return result as String
    }
    return ids.map { AudioDevice(id:$0,name:property($0,kAudioObjectPropertyName),uid:property($0,kAudioDevicePropertyDeviceUID)) }
}
func nominalRate(_ id: AudioDeviceID) -> Double {
    var a = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyNominalSampleRate,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var rate: Float64 = 0; var n = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(id,&a,0,nil,&n,&rate) == noErr && rate > 0 ? rate : 48000
}
func device(uid: String) -> AudioDevice? {
    var a = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyTranslateUIDToDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var id: AudioDeviceID = 0; var n = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to:&cfUID) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,UInt32(MemoryLayout<CFString>.size),$0,&n,&id) }
    return status == noErr && id != 0 ? AudioDevice(id:id,name:uid,uid:uid) : nil
}

/// Where calls go: our own FX–USB virtual mic when installed (the app plays into its hidden
/// "Bridge" half; apps record from "FX–USB"), else BlackHole 2ch (one device, both halves).
struct CallRoute { let output: AudioDevice; let microphone: AudioDevice; let name: String }
func callRoute() -> CallRoute? {
    if let output = device(uid:"FX-USB_2_UID"), let microphone = device(uid:"FX-USB_UID") { return CallRoute(output:output,microphone:microphone,name:"FX–USB") }
    if let blackhole = audioDevices().first(where:{ $0.name == "BlackHole 2ch" }) { return CallRoute(output:blackhole,microphone:blackhole,name:"BlackHole 2ch") }
    return nil
}

func bufferFrames(_ id: AudioDeviceID) -> Int {
    var a = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyBufferFrameSize,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var frames: UInt32 = 0; var n = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id,&a,0,nil,&n,&frames) == noErr ? Int(frames) : 512
}
func defaultInput() -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var result: AudioDeviceID = 0; var n = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&n,&result); return result
}
@discardableResult func setDefaultInput(_ id: AudioDeviceID) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var value = id
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,UInt32(MemoryLayout<AudioDeviceID>.size),&value)
}

func halUnit(_ device: AudioDeviceID, input: Bool) throws -> AudioUnit {
    var description = AudioComponentDescription(componentType:kAudioUnitType_Output,componentSubType:kAudioUnitSubType_HALOutput,componentManufacturer:kAudioUnitManufacturer_Apple,componentFlags:0,componentFlagsMask:0)
    guard let component = AudioComponentFindNext(nil,&description) else { throw BridgeError("Core Audio output unavailable") }
    var created: AudioUnit?
    guard AudioComponentInstanceNew(component,&created) == noErr, let unit = created else { throw BridgeError("Could not create audio output") }
    if input {
        var on: UInt32 = 1, off: UInt32 = 0
        AudioUnitSetProperty(unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&on,4)
        AudioUnitSetProperty(unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&off,4)
    }
    var id = device
    guard AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&id,UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
        AudioComponentInstanceDispose(unit); throw BridgeError("Could not connect to BlackHole")
    }
    var format = AudioStreamBasicDescription(mSampleRate:nominalRate(device),mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
    AudioUnitSetProperty(unit,kAudioUnitProperty_StreamFormat,input ? kAudioUnitScope_Output : kAudioUnitScope_Input,input ? 1 : 0,&format,UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    return unit
}

/// Devices that can play sound, except the BlackHole bridge (that would loop into calls).
func outputDevices() -> [AudioDevice] {
    audioDevices().filter { device in
        guard !device.name.hasPrefix("BlackHole") else { return false }
        var a = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioObjectPropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device.id,&a,0,nil,&size) == noErr && size > 0
    }
}
func defaultOutput() -> AudioDeviceID {
    var a = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var result: AudioDeviceID = 0; var n = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&n,&result); return result
}

/// Plays the mic live on speakers or headphones, through the feedback guard.
final class MonitorOutput {
    let buffer: JitterBuffer
    private(set) var guardian: FeedbackGuard?
    var unit: AudioUnit?
    var device: AudioDevice?
    var volume: Float = 0.5 { didSet { guardian?.volume = volume } }
    init(_ buffer: JitterBuffer) { self.buffer = buffer }
    func start(_ target: AudioDevice) throws {
        if device?.id == target.id && unit != nil { return }
        stop()
        let unit = try halUnit(target.id,input:false)
        let rate = nominalRate(target.id)
        let guardian = FeedbackGuard(rate:rate); guardian.volume = volume
        self.guardian = guardian
        var callback = AURenderCallbackStruct(inputProc:{ context,_,_,_,frames,data in
            guard let data else { return noErr }
            let monitor = Unmanaged<MonitorOutput>.fromOpaque(context).takeUnretainedValue()
            let buffers = UnsafeMutableAudioBufferListPointer(data)
            if let samples = buffers[0].mData?.assumingMemoryBound(to:Float.self), let guardian = monitor.guardian {
                monitor.buffer.render(samples,frames:Int(frames),channels:2)
                guardian.process(samples,frames:Int(frames),channels:2)
            }
            return noErr
        },inputProcRefCon:Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(unit) == noErr else { AudioComponentInstanceDispose(unit); throw BridgeError("Could not start the speakers") }
        buffer.start(rate:rate)
        guard AudioOutputUnitStart(unit) == noErr else { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); throw BridgeError("Could not start the speakers") }
        self.unit = unit; device = target
    }
    func stop() {
        if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); self.unit = nil }
        device = nil
    }
    deinit { stop() }
}

final class CallOutput {
    let buffer: JitterBuffer
    var unit: AudioUnit?
    var device: AudioDevice?
    var savedInput: AudioDeviceID?
    init(_ buffer: JitterBuffer) { self.buffer = buffer }
    var microphone: AudioDevice?
    func start(_ route: CallRoute, switchDefaultInput: Bool = true) throws {
        if unit != nil { return }
        let target = route.output
        let unit = try halUnit(target.id,input:false)
        var callback = AURenderCallbackStruct(inputProc:{ context,_,_,_,frames,data in
            guard let data else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(data)
            if let samples = buffers[0].mData {
                Unmanaged<JitterBuffer>.fromOpaque(context).takeUnretainedValue().render(samples.assumingMemoryBound(to:Float.self),frames:Int(frames),channels:2)
            }
            return noErr
        },inputProcRefCon:Unmanaged.passUnretained(buffer).toOpaque())
        AudioUnitSetProperty(unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(unit) == noErr else { AudioComponentInstanceDispose(unit); throw BridgeError("Could not start call audio") }
        buffer.start(rate:nominalRate(target.id))
        guard AudioOutputUnitStart(unit) == noErr else { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); throw BridgeError("Could not start call audio") }
        self.unit = unit; device = target; microphone = route.microphone
        if switchDefaultInput {
            savedInput = defaultInput()
            guard setDefaultInput(route.microphone.id) == noErr else { stop(); throw BridgeError("Choose \(route.name) in your call app’s microphone settings") }
        }
    }
    func stop() {
        if let mic = microphone, let saved = savedInput, defaultInput() == mic.id, audioDevices().contains(where:{ $0.id == saved }) { setDefaultInput(saved) }
        savedInput = nil; device = nil; microphone = nil
        if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); self.unit = nil }
    }
    deinit { stop() }
}

final class AppDelegate: NSObject,NSApplicationDelegate {
    let state = AudioState()
    lazy var reader = USBReader(state)
    lazy var calls = CallOutput(state.buffer)
    lazy var monitor = MonitorOutput(state.monitorBuffer)
    let model = MicModel()
    let popover = NSPopover()
    let buttons = ButtonsStore()
    lazy var engine = ButtonEngine(store:buttons,send:{ [weak self] command in self?.state.send(command) },
                                   startVoiceNote:{ [weak self] in self?.startVoiceNote() ?? false },
                                   stopVoiceNote:{ [weak self] in self?.stopVoiceNote() })
    var buttonsWindow: ButtonsWindow!
    var wasConnected = false
    var lastNotice = "", noticeAt = Date.distantPast
    let defaults = UserDefaults.standard
    var outputs: [AudioDevice] = []
    var pressedSample: Int?
    var lastCaught = 0, caughtAt = Date.distantPast
    var window: MainWindow!
    var statusItem: NSStatusItem!
    var timer: Timer?, uiTimer: Timer?
    var worker = DispatchGroup()
    var useCalls = true
    var bridgeInstalled = true
    var callsName = ""
    var shownLevel = 0.0
    var iconKey = ""
    let summary = NSMenuItem(title:"Connecting…",action:nil,keyEquivalent:"")
    let callItem = NSMenuItem(title:"Use for calls",action:#selector(toggleCalls),keyEquivalent:"")
    let recordItem = NSMenuItem(title:"Record",action:#selector(record),keyEquivalent:"r")
    let muteItem = NSMenuItem(title:"Mute",action:#selector(mute),keyEquivalent:"m")
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        statusItem.button?.image = menuBarImage(level:0,connected:false,muted:false)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named:.aqua)
        let panel = NSHostingController(rootView:PopoverView(model:model))
        popover.contentViewController = panel
        popover.contentSize = panel.view.fittingSize
        monitor.volume = Float(defaults.object(forKey:"speakersVolume") as? Double ?? 0.5)
        model.toggleRecording = { [weak self] in self?.record() }
        model.toggleMute = { [weak self] in self?.mute() }
        model.toggleCalls = { [weak self] in self?.toggleCalls() }
        model.installBridge = { [weak self] in self?.setup() }
        model.setGain = { [weak self] g in self?.setGain(g) }
        model.setEffect = { [weak self] effect in self?.state.send("e\(effect+1)") }
        model.pressSample = { [weak self] sample in
            guard let self else { return }
            self.state.lock.lock(); let selected = self.state.mic.sample; self.state.lock.unlock()
            if selected != sample { self.state.send("s\(sample)") }
            self.state.send("p"); self.pressedSample = sample
        }
        model.releaseSample = { [weak self] in self?.state.send("q"); self?.pressedSample = nil }
        model.selectSample = { [weak self] sample in self?.state.send("s\(sample)") }
        model.toggleSpeakers = { [weak self] in
            guard let self else { return }
            self.defaults.set(!self.defaults.bool(forKey:"speakersOn"),forKey:"speakersOn"); self.refresh()
        }
        model.setVolume = { [weak self] v in self?.monitor.volume = Float(v); self?.defaults.set(v,forKey:"speakersVolume") }
        model.chooseOutput = { [weak self] name in
            guard let self, let device = self.outputs.first(where:{ $0.name == name }) else { return }
            self.defaults.set(device.uid,forKey:"speakersUID"); self.refresh()
        }
        model.openWindow = { [weak self] in self?.popover.performClose(nil); self?.window.show() }
        model.allowAccess = { [weak self] in self?.buttons.refreshTrust(prompt:true); NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
        model.openButtons = { [weak self] in self?.popover.performClose(nil); self?.buttonsWindow.show() }
        buttonsWindow = ButtonsWindow(store:buttons)
        model.openSoundSettings = { [weak self] in self?.settings() }
        model.quit = { NSApp.terminate(nil) }
        window = MainWindow(model:model)
        window.show()
        worker.enter()
        DispatchQueue.global(qos:.userInteractive).async { self.reader.run(); self.worker.leave() }
        timer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { _ in self.refresh() }
        uiTimer = Timer.scheduledTimer(withTimeInterval:1/30,repeats:true) { _ in self.tick() }
        RunLoop.main.add(uiTimer!,forMode:.common)
        refresh()
    }
    func buildMainMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle:"Hide FX–USB",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle:"Quit FX–USB",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let windowItem = NSMenuItem(), windowMenu = NSMenu(title:"Window")
        windowMenu.addItem(withTitle:"Close",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        windowMenu.addItem(withTitle:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windowItem.submenu = windowMenu; main.addItem(windowItem)
        NSApp.mainMenu = main
    }
    /// 30 Hz: feeds the window and the menu bar icon.
    func tick() {
        state.lock.lock()
        let level = Double(state.level); state.level *= 0.8
        var snap = Snapshot(connected:state.connected,status:state.status,level:0,mic:state.mic,recordingSince:state.recordingSince,
                            muted:state.muted,gain:Int(state.gain),useCalls:useCalls,bridgeInstalled:bridgeInstalled,callsName:callsName,firmware:state.firmware)
        state.lock.unlock()
        shownLevel = max(level,shownLevel*0.85)
        snap.level = shownLevel
        let output = state.buffer.stats()
        snap.bufferMs = output.fillMs; snap.dropouts = output.underflows
        snap.speakersOn = defaults.bool(forKey:"speakersOn")
        snap.speakersVolume = Double(monitor.volume)
        snap.speakersDevice = speakersDevice()?.name ?? ""
        snap.outputs = outputs.map { $0.name }
        snap.pressedSample = pressedSample
        // Mic presses → Mac actions (Buttons window).
        if snap.connected != wasConnected { engine.connected(snap.connected); wasConnected = snap.connected }
        if snap.connected { engine.update(snap.mic) }
        snap.buttonsSummary = buttons.usesAssistants && !buttons.assistantLine.isEmpty ? "\(buttons.assistantLine) · \(buttons.summary)" : buttons.summary
        if buttons.notice != lastNotice { lastNotice = buttons.notice; noticeAt = Date() }
        snap.needsAccess = buttons.usesKeys && !AXIsProcessTrusted()
        snap.notice = Date().timeIntervalSince(noticeAt) < 4 ? buttons.notice : ""
        if let caught = monitor.guardian?.caught, caught != lastCaught { lastCaught = caught; caughtAt = Date() }
        snap.feedbackCaught = snap.speakersOn && Date().timeIntervalSince(caughtAt) < 4
        if snap != model.snapshot { model.snapshot = snap }
        let key = "\(snap.connected)\(snap.muted)\(Int((min(1,pow(shownLevel,0.6)*1.6)*5).rounded()))"
        if key != iconKey { iconKey = key; statusItem.button?.image = menuBarImage(level:shownLevel,connected:snap.connected,muted:snap.muted) }
    }
    func refresh() {
        state.lock.lock()
        let connected = state.connected, text = state.status, muted = state.muted, recording = state.recording != nil
        state.lock.unlock()
        summary.title = text
        statusItem.button?.title = recording ? " REC" : ""
        muteItem.state = muted ? .on : .off
        recordItem.title = recording ? "Stop recording" : "Record"
        recordItem.isEnabled = connected || recording
        callItem.state = useCalls ? .on : .off
        let route = callRoute()
        bridgeInstalled = route != nil
        callsName = route?.name ?? ""
        callItem.title = route == nil ? "Use for calls — setup needed" : "Use for calls"
        // Switch to FX–USB the moment it is installed, and reconnect after Core Audio restarts
        // (device IDs change), even while BlackHole was in use.
        if calls.device != nil, let route, calls.device?.id != route.output.id { calls.stop() }
        if connected && useCalls, let route {
            do { try calls.start(route) }
            catch { callItem.title = String(describing:error) }
        } else { calls.stop() }
        outputs = outputDevices()
        if connected && defaults.bool(forKey:"speakersOn"), let target = speakersDevice() {
            try? monitor.start(target)
        } else { monitor.stop() }
    }
    /// The chosen speakers, else the Mac's default output (never BlackHole).
    func speakersDevice() -> AudioDevice? {
        let uid = defaults.string(forKey:"speakersUID")
        return outputs.first { $0.uid == uid } ?? outputs.first { $0.id == defaultOutput() } ?? outputs.first
    }
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button { popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY); popover.contentViewController?.view.window?.makeKey() }
    }
    @objc func showWindow() { window.show() }
    @objc func mute() { state.lock.lock(); state.muted.toggle(); state.lock.unlock(); refresh() }
    @objc func toggleCalls() { useCalls.toggle(); refresh() }
    @objc func gain(_ item: NSMenuItem) { setGain(item.tag) }
    func setGain(_ value: Int) { state.lock.lock(); state.gain = Float(value); state.lock.unlock() }
    /// One click: records straight to Music/FX–USB, and shows the file in Finder when stopped.
    @objc func record() {
        state.lock.lock(); let current = state.recordingURL; let isRecording = state.recording != nil; state.lock.unlock()
        if isRecording {
            state.stopRecording(); refresh()
            if let current { NSWorkspace.shared.activateFileViewerSelecting([current]) }
            return
        }
        let folder = FileManager.default.urls(for:.musicDirectory,in:.userDomainMask)[0].appendingPathComponent("FX–USB")
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try state.startRecording(folder.appendingPathComponent("FX–USB \(stamp.string(from:Date())).wav"))
        } catch { let alert = NSAlert(); alert.messageText = "Could not start recording"; alert.informativeText = error.localizedDescription; alert.runModal() }
        refresh()
    }
    /// Voice notes from a mic button: Music/FX–USB/Voice notes, one WAV per press.
    func startVoiceNote() -> Bool {
        state.lock.lock(); let busy = state.recording != nil; state.lock.unlock()
        if busy { return false }
        let folder = FileManager.default.urls(for:.musicDirectory,in:.userDomainMask)[0].appendingPathComponent("FX–USB/Voice notes")
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try state.startRecording(folder.appendingPathComponent("Voice note \(stamp.string(from:Date())).wav"))
            return true
        } catch { return false }
    }
    func stopVoiceNote() -> String? {
        state.lock.lock(); let url = state.recordingURL; state.lock.unlock()
        state.stopRecording()
        return url?.lastPathComponent
    }
    @objc func setup() {
        // The FX–USB installer adds the microphone; it is on the download page.
        NSWorkspace.shared.open(URL(string:"https://danilosierrac.github.io/fx-usb/#get")!)
    }
    @objc func settings() { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { window.show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate(); uiTimer?.invalidate(); calls.stop(); monitor.stop()
        state.lock.lock(); state.running = false; state.lock.unlock()
        _ = worker.wait(timeout:.now()+7); state.stopRecording()
        return .terminateNow
    }
}

func selfTest() {
    func packet(_ seq: UInt16, _ stamps: [UInt32], _ value: Int16) -> [UInt8] {
        var bytes = Array("FXP4".utf8)
        for shift in stride(from:0,to:32,by:8) { bytes.append(UInt8((stamps[0] >> UInt32(shift)) & 255)) }
        bytes += [UInt8(seq & 255),UInt8(seq >> 8),UInt8(stamps.count),0]
        for stamp in stamps {
            bytes += [UInt8(stamp & 255),UInt8((stamp >> 8) & 255)]
            for _ in 0..<blockFrames { bytes += [UInt8(UInt16(bitPattern:value) & 255),UInt8(UInt16(bitPattern:value) >> 8)] }
        }
        return bytes
    }
    // Two packets split byte by byte, one crossing a 16-bit stamp wrap.
    var decoder = PacketDecoder(); var decoded: [Block] = []
    for byte in Array("garbage".utf8)+packet(1,[65000,65569,66138],32767)+packet(4,[1_000_000],-5) { decoded += decoder.feed([byte]) }
    precondition(decoded.count == 4 && decoded[0].samples[0] == 32767 && decoded[2].stamp == 66138 && decoded[3].samples[31] == -5 && decoded[3].seq == 4,"Framing across partial reads")

    // Stamps 0, 1, 4 periods: two blocks missing → concealed, so time is preserved.
    var timeline = Timeline(), out: [Float] = []
    for (seq,period) in [(0,0),(1,1),(2,4)] {
        let stamp = UInt32((Double(period)*periodMicroseconds).rounded())&+4_294_966_000
        timeline.append(Block(seq:UInt16(seq),stamp:stamp,samples:Array(repeating:1000,count:blockFrames)),gain:1,muted:false,to:&out)
    }
    precondition(timeline.lostBlocks == 2 && out.count == 5*blockFrames,"Lost blocks concealed on the mic's clock, across timer wrap")
    timeline.append(Block(seq:3,stamp:4_294_966_000,samples:Array(repeating:0,count:blockFrames)),gain:1,muted:false,to:&out)
    precondition(out.count == 5*blockFrames,"Stale block dropped")

    var resampler = RecordingResampler()
    let tone = (0..<56250).map { Float(sin(Double($0)*2*Double.pi*440/56250)*0.3) }
    let resampled = stride(from:0,to:tone.count,by:1000).flatMap { resampler.process(Array(tone[$0..<min($0+1000,tone.count)])) }
    precondition(abs(resampled.count-48000) <= 2 && resampled.allSatisfy { $0.isFinite && abs($0) <= 0.31 },"Recording resample 56,250 → 48,000 Hz")

    // Output buffer: the mic's clock 200 ppm fast against the output's; the control loop
    // must hold the fill near target without a single dropout.
    let buffer = JitterBuffer(); buffer.start(rate:48000)
    var produced = 0.0, rendered = [Float](repeating:0,count:1024)
    for step in 0..<6000 {
        let due = Double(step+1)*512/48000*1.0002*deviceRate
        let count = Int(due-produced); produced += Double(count)
        buffer.push(Array(repeating:0.1,count:count))
        buffer.render(&rendered,frames:512,channels:2)
    }
    let stats = buffer.stats()
    precondition(stats.underflows == 0 && stats.skips == 0 && abs(stats.fillMs-40) < 3 && abs(stats.ppm-200) < 60,"Drift tracking (fill \(stats.fillMs) ms, \(stats.ppm) ppm)")
    precondition(wavHeader(100).count == 44)
    let chunks = programChunks((try? readerProgram()) ?? "")
    precondition(chunks.count >= 6 && chunks.allSatisfy { !$0.contains("\n#") && $0.count < 2600 },"Reader program chunks")
    let open = simulateRoom(guarded:false), guarded = simulateRoom(guarded:true), alarms = guardFalseAlarms()
    let notchOnly = simulateRoom(guarded:true,shiftHz:0)
    precondition(notchOnly.rms < 0.05 && notchOnly.caught > 0,"Howl notches alone: \(notchOnly.rms) rms, \(notchOnly.caught) caught")
    precondition(open.rms > 0.2,"Room simulation must howl without the guard (\(open.rms))")
    precondition(guarded.rms < 0.02 && alarms == 0,"Feedback guard: howl \(guarded.rms) rms, \(guarded.caught) caught, \(alarms) false alarms")
    let buttonsCheck = buttonsSelfTest()
    print(String(format:"PASS: framing, hardware timeline, concealment, recording resampler, drift tracking, reader chunks, feedback guard (howl %.3f → %.4f rms; notches alone %.4f rms after %d catches; 0 false alarms), %@",open.rms,guarded.rms,notchOnly.rms,notchOnly.caught,buttonsCheck))
}

func streamTest(seconds: Double, sample: Int?, pipeline: String?, loopback: String?) {
    let state = AudioState(), group = DispatchGroup(), reader = USBReader(state)
    reader.testSample = sample
    var recordPath: String?
    if let base = pipeline ?? loopback {
        recordPath = base+"-direct.wav"
        try! state.startRecording(URL(fileURLWithPath:recordPath!))
    }
    group.enter()
    DispatchQueue.global(qos:.userInteractive).async { reader.run(); group.leave() }
    var rendered: [Float] = []
    var calls: CallOutput?
    var capture: AudioUnit?
    var captureRate = 48000.0
    let captured = CaptureSink()
    if pipeline != nil {
        // Simulated output clock: pull 512 frames every 10.67 ms, like a 48 kHz device.
        let start = DispatchTime.now().uptimeNanoseconds
        state.buffer.start(rate:48000)
        var block = [Float](repeating:0,count:1024), n: UInt64 = 0
        while Double(DispatchTime.now().uptimeNanoseconds-start)/1e9 < seconds {
            n += 1
            let due = start+n*512*1_000_000_000/48000
            while DispatchTime.now().uptimeNanoseconds < due { usleep(200) }
            state.buffer.render(&block,frames:512,channels:2)
            rendered += stride(from:0,to:1024,by:2).map { block[$0] }
        }
    } else if let name = argument("--monitor-test"), let target = outputDevices().first(where:{ $0.name == name }) {
        Thread.sleep(forTimeInterval:1.5)
        let monitor = MonitorOutput(state.monitorBuffer); monitor.volume = 0
        try! monitor.start(target)
        Thread.sleep(forTimeInterval:seconds)
        let m = state.monitorBuffer.stats()
        print("monitor on \(name): underflows \(m.underflows), overflow skips \(m.skips), fill \(Int(m.fillMs)) ms, device buffer \(bufferFrames(target.id)) frames at \(Int(nominalRate(target.id))) Hz")
        monitor.stop()
    } else if loopback != nil, let route = callRoute() {
        Thread.sleep(forTimeInterval:1.5)
        calls = CallOutput(state.buffer)
        try! calls!.start(route,switchDefaultInput:false)
        print("calls route: \(route.name)")
        captureRate = nominalRate(route.microphone.id)
        if CommandLine.arguments.contains("--capture") { capture = try! startCapture(route.microphone.id,captured) }
        Thread.sleep(forTimeInterval:seconds)
        if let capture { AudioOutputUnitStop(capture); AudioComponentInstanceDispose(capture) }
        calls?.stop()
    } else { Thread.sleep(forTimeInterval:seconds) }
    state.stopRecording()
    let output = state.buffer.stats()
    state.lock.lock()
    var result: [String:Any] = ["connected":state.connected,"status":state.status,"packets":state.packets,"lostBlocks":state.lostBlocks,
                                "sequenceBreaks":state.sequenceBreaks,"maxUSBReadGapMs":Int(state.maxReadGap*1000),"frames56k":state.totalFrames,
                                "outputUnderflows":output.underflows,"outputOverflowSkips":output.skips,"outputFillMs":(output.fillMs*10).rounded()/10,"ratioPPM":Int(output.ppm),"effectiveRatioPPM":Int(state.buffer.effectiveRatioPPM())]
    state.running = false
    state.lock.unlock()
    _ = group.wait(timeout:.now()+8)
    if let base = pipeline { try! writeWAV(rendered,rate:48000,to:base+"-output.wav"); result["outputWAV"] = base+"-output.wav"; result["directWAV"] = recordPath }
    if let base = loopback, capture != nil {
        let samples = captured.take()
        try! writeWAV(samples,rate:UInt32(captureRate),to:base+"-blackhole.wav")
        result["blackholeWAV"] = base+"-blackhole.wav"; result["blackholeFrames"] = samples.count; result["directWAV"] = recordPath
    }
    print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    exit((result["connected"] as? Bool) == true ? 0 : 1)
}

/// Records what other apps hear from BlackHole (test only; needs microphone permission).
final class CaptureSink {
    let lock = NSLock()
    var samples: [Float] = []
    var unit: AudioUnit?
    var scratch = [Float](repeating:0,count:16384)
    func take() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }
}
func startCapture(_ device: AudioDeviceID, _ sink: CaptureSink) throws -> AudioUnit {
    let unit = try halUnit(device,input:true)
    sink.unit = unit
    var callback = AURenderCallbackStruct(inputProc:{ context,flags,time,bus,frames,_ in
        let sink = Unmanaged<CaptureSink>.fromOpaque(context).takeUnretainedValue()
        guard let unit = sink.unit, Int(frames)*2 <= sink.scratch.count else { return noErr }
        return sink.scratch.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:2,mDataByteSize:frames*8,mData:raw.baseAddress))
            let status = AudioUnitRender(unit,flags,time,bus,frames,&list)
            if status == noErr {
                let floats = raw.bindMemory(to:Float.self)
                sink.lock.lock(); for i in 0..<Int(frames) { sink.samples.append(floats[i*2]) }; sink.lock.unlock()
            }
            return status
        }
    },inputProcRefCon:Unmanaged.passUnretained(sink).toOpaque())
    AudioUnitSetProperty(unit,kAudioOutputUnitProperty_SetInputCallback,kAudioUnitScope_Global,0,&callback,UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    guard AudioUnitInitialize(unit) == noErr, AudioOutputUnitStart(unit) == noErr else { throw BridgeError("Could not capture BlackHole") }
    return unit
}

func argument(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of:name), i+1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i+1]
}

if CommandLine.arguments.contains("--self-test") { selfTest() }
else if CommandLine.arguments.contains("--assistants") { printAssistants() }
else if let name = argument("--assistant-focus") { focusAssistant(name) }
else if let name = argument("--press") { pressHook(name) }
else if let directory = argument("--iconset") { try! writeIconset(directory) }
else if let directory = argument("--preview") { MainActor.assumeIsolated { renderPreviews(directory) } }
else if CommandLine.arguments.contains("--devices") { for device in audioDevices() { print("\(device.id) \(device.name) [\(device.uid)] \(nominalRate(device.id)) Hz, buffer \(bufferFrames(device.id)) frames") } }
else if CommandLine.arguments.contains("--usb-test") || argument("--pipeline-test") != nil || argument("--loopback-test") != nil || argument("--monitor-test") != nil {
    // Close FX Mic first: only one process may own the mic's USB console.
    streamTest(seconds:Double(argument("--seconds") ?? "12") ?? 12,sample:argument("--sample").flatMap { Int($0) },
               pipeline:argument("--pipeline-test"),loopback:argument("--loopback-test"))
}
else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
