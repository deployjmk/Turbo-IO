import Foundation
import Combine
import RayNeoDisplay
import RayNeoProtocol
import UIKit

@MainActor final class CompanionDeviceFeatures: ObservableObject {
    @Published private(set) var status = "Connected — glasses features available; audio capture does not start automatically"
    @Published private(set) var recordingStatus = "Glasses recording capture is not enabled"
    @Published private(set) var recordingID: String?
    @Published private(set) var recordingBytes = 0
    @Published private(set) var acceptsEyeRecording = false
    @Published private(set) var todoStatus = "Not synced yet"
    @Published private(set) var battery: Int?
    @Published private(set) var brightness: Int?
    @Published private(set) var settings: [String: Any] = [:]
    @Published private(set) var completedRecording: URL?
    @Published private(set) var recoveryEntries: [GlassesRecordingInbox.Entry] = []
    @Published private(set) var recoveryBusy = false
    @Published private(set) var recoveryStatus = "Scans this device only; the glasses are never accessed."
    @Published var error: String?
    let voice: CompanionVoiceRuntime
    private weak var store: CompanionStore?
    private let inbox: GlassesRecordingInbox
    private let io = DispatchQueue(label: "companion.recording.inbox", qos: .utility)
    private let writeSlots = DispatchSemaphore(value:64)
    private var failedRecordings = Set<String>()
    private var captureDevice: String?
    private var recordTimeRaw: Int64?
    private var finishing = Set<String>()
    private var finalizationInFlight = false
    private var pendingSettings: [String: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    var canControl: Bool { voice.ready && !recoveryBusy && store?.alwaysOn.occupied != true && !["recording", "processing", "displaying"].contains(voice.phase) }
    init(voice: CompanionVoiceRuntime, store: CompanionStore, root: URL) {
        self.voice = voice; self.store = store; inbox = GlassesRecordingInbox(root: root)
        voice.onBusiness = { [weak self] in self?.receive(device: $0, business: $1, data: $2) }
        voice.onBusinessLoss = { [weak self] in self?.lostMessages(); self?.store?.alwaysOn.lostMessages() }
        // One automatic weather owner. Legacy Weatherstack stays manual to avoid overwrites.
        voice.onRuntimeRefresh = { [weak self] in self?.store?.qweather.tick() }
        voice.featureIsBusy = { [weak self] in self?.recordingID != nil || self?.teleprompterID != nil || self?.store?.alwaysOn.occupied == true }
        voice.onConnectionChange = { [weak self] device in
            guard let self else { return }
            self.store?.notifications.connectionChanged()
            self.store?.headControlTest.connectionChanged()
            self.store?.alwaysOn.connectionChanged()
            self.pendingSettings.removeAll(); self.settings = [:]; self.battery = nil; self.brightness = nil
            if self.recordingID != nil { self.recordingStatus = device == self.captureDevice ? "Connection restored; waiting for the same recording state/data, backfill is not declared complete automatically" : "Connection interrupted; the original recording is kept, waiting for the same glasses to resume" }
            if self.teleprompterID != nil, device != self.teleprompterDevice {
                self.teleprompterPrepared = false
                self.teleprompterStatus = "Teleprompter connection interrupted; automatic actions stopped. Restore the connection, then exit and prepare again."
            }
        }
        for (name, foreground) in [(UIApplication.didEnterBackgroundNotification,false),(UIApplication.didBecomeActiveNotification,true)] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.recordingID != nil, self.voice.deviceID == self.captureDevice else { return }
                    self.perform { try self.send(14,14,["isAppForeground":foreground]) }
                }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func prepare() { voice.prepare(); voice.refresh() }
    private func send(_ business: UInt8, _ type: UInt32, _ json: [String: Any]) throws {
        guard voice.deviceID != nil else { throw DeviceFeatureError.disconnected }
        try voice.sendBusiness(business, payload: DeviceBusinessWire.encode(type: type, json: json))
    }
    func perform(_ body: () throws -> Void) {
        do { try body(); error = nil } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Operation failed; the glasses did not confirm completion." }
    }
    func enableEyeRecording(_ enabled: Bool) {
        guard recordingID == nil else { error = "Stop the recording and wait for file reception to finish first."; return }
        acceptsEyeRecording = enabled
        recordingStatus = enabled ? "Reception allowed: start the recording on the glasses; it is saved on this device only" : "Glasses recording capture is not enabled"
    }
    func startRecording() {
        perform {
            guard canControl, recordingID == nil, teleprompterID == nil, let device = voice.deviceID else { throw DeviceFeatureError.busy }
            // Voice standby is explicitly suspended so an unsolicited wake cannot steal the microphone.
            if voice.enabled { voice.stop() }
            acceptsEyeRecording = true
            let id = UUID().uuidString
            captureDevice = device; recordingID = id; recordingBytes = 0; completedRecording = nil; recordTimeRaw = nil
            recordingStatus = "Preparing the local reception directory"
            io.async { [weak self, inbox] in
                do {
                    try inbox.begin(device: device, id: id)
                    DispatchQueue.main.async {
                        guard let self, self.recordingID == id, self.voice.deviceID == device else { return }
                        self.perform {
                            try self.send(14,14,["isAppForeground": true])
                            try self.send(14,1,["uuid":id,"action":1,"code":1])
                            self.recordingStatus = "Start requested, waiting for the glasses to respond"
                        }
                    }
                } catch { DispatchQueue.main.async { self?.error = "Failed to create the reception directory; the glasses recording was not requested."; self?.recordingID = nil } }
            }
        }
    }
    func recordingControl(_ type: UInt32) {
        perform {
            guard let id = recordingID, voice.deviceID == captureDevice, [4,8,9,11].contains(type) else { throw DeviceFeatureError.noSession }
            var body: [String: Any] = ["uuid": id, "action": type == 11 ? 2 : 1, "code": type == 4 ? 2 : 1]
            // Preserve a reported raw time; never invent an epoch/elapsed-time conversion.
            if type == 9, let time = recordTimeRaw { body["time"] = time }
            try send(14,type,body)
            recordingStatus = type == 4 ? "Stop requested; still waiting for the trailing audio and the completion message" : "Control submitted, waiting for the glasses to respond"
        }
    }
    func receive(device: String, business: UInt8, data: Data) {
        guard voice.deviceID == device else { return }
        if business == 13 || business == 15 { store?.alwaysOn.receive(device: device, business: business, packet: data) }
        do {
            let wire = try DeviceBusinessWire(data)
            switch business {
            case 14: try recording(device,wire)
            case 22: try todo(device,wire)
            case 15:
                store?.qweather.receive(device:device,wire:wire)
                launcher(wire)
            case 20: try teleprompterReceive(device,wire)
            case 21:
                store?.notifications.receive(device: device, wire: wire)
                store?.headControlTest.receive(device: device, wire: wire)
            default: break
            }
        } catch {
            self.error = "Received unrecognized or mismatched business data; it was not treated as success."
            if business == 14 { lostMessages() }
        }
    }
    private func recording(_ device: String, _ wire: DeviceBusinessWire) throws {
        let j = wire.json, type = wire.type
        if type == 12 { recordingStatus = "Received the sync list; this build does not import or clean up the offline backlog automatically"; return }
        guard let id = DeviceBusinessWire.identifier(j,"uuid") else { return }
        if type == 3, finishing.contains(id), recordingID != id, captureDevice == device {
            error = "Late data arrived for an already packaged recording; keep a copy and re-check it — completeness cannot be guaranteed."
            io.async { [inbox] in inbox.invalidate(device:device,id:id) }
            return
        }
        let action = DeviceBusinessWire.integer(j,"action"), code = DeviceBusinessWire.integer(j,"code")
        if type == 1, action == 1 {
            guard acceptsEyeRecording, teleprompterID == nil, recordingID == nil || (recordingID == id && captureDevice == device), canControl else { return }
            if voice.enabled { voice.stop() }
            recordingID = id; captureDevice = device; recordingBytes = 0; completedRecording = nil
            io.async { [weak self, inbox] in
                do {
                    try inbox.begin(device: device,id: id)
                    DispatchQueue.main.async {
                        guard let self, self.recordingID == id, self.voice.deviceID == device else { return }
                        self.perform { try self.send(14,1,["uuid":id,"action":2,"code":1]); self.recordingStatus = "Glasses recording accepted, waiting for data" }
                    }
                } catch { DispatchQueue.main.async { self?.error = "Could not prepare local storage for the glasses recording." } }
            }
            return
        }
        guard recordingID == id, captureDevice == device else { return }
        if let time = DeviceBusinessWire.integer(j,"time") { recordTimeRaw = time }
        if type == 1, action == 2 {
            if code == 1 { recordingStatus = "The glasses confirmed the recording started" }
            else { recordingStatus = "The glasses refused to start, code=\(code ?? -1); privacy/conflict is not bypassed automatically"; recordingID = nil }
        } else if type == 3 {
            guard let offset = DeviceBusinessWire.integer(j,"offset"), offset >= 0,
                  offset <= GlassesRecordingInbox.limit, !wire.bytes.isEmpty else { throw DeviceFeatureError.invalidPacket }
            guard writeSlots.wait(timeout:.now()) == .success else { lostMessages(); return }
            io.async { [weak self, inbox, writeSlots] in
                defer { writeSlots.signal() }
                do { let count = try inbox.append(device:device,id:id,offset:Int(offset),data:wire.bytes)
                    DispatchQueue.main.async { self?.recordingBytes = count; self?.recordingStatus = "Receiving and saving the raw audio" }
                } catch { inbox.invalidate(device:device,id:id); DispatchQueue.main.async { self?.error = "Audio write or integrity check failed; the original is kept and cannot be marked complete." } }
            }
        } else if type == 6, DeviceBusinessWire.boolean(j,"completed") == true, !finishing.contains(id) {
            // Persist the observed completion before queued finalization, so a restart cannot invent or lose it.
            io.async { [inbox] in
                do { try inbox.recordCompletion(device:device,id:id) }
                catch { inbox.invalidate(device:device,id:id) }
            }
            finishing.insert(id); recordingStatus = "The glasses reported completion; verifying received coverage and packaging"
            // Small grace for callbacks delivered after completion. Late data is never silently merged into a published file.
            DispatchQueue.main.asyncAfter(deadline: .now()+1) { [weak self] in self?.finishRecording(device:device,id:id) }
        } else if type == 4 {
            if action == 1 { try send(14,4,["uuid":id,"action":2,"code":code ?? 1]) }
            recordingStatus = "Stop event received, waiting for the audio to finish"
        } else if type == 11 {
            if action == 1 { try send(14,11,["uuid":id,"action":2,"code":1]) }
            let time = DeviceBusinessWire.integer(j,"time") ?? 0
            io.async { [inbox] in try? inbox.mark(device:device,id:id,time:time) }
        } else if type == 8 || type == 9 {
            if action == 1 { try send(14,type,["uuid":id,"action":2,"code":1]) }
            recordingStatus = code == 1 ? (type == 8 ? "The glasses paused" : "The glasses resumed") : "Control response code=\(code ?? -1)"
        } else if type == 5 { recordingStatus = "Received reconnection state for the same recording; continuing offset verification" }
    }
    private func finishRecording(device: String, id: String) {
        guard !finalizationInFlight else { return }
        finalizationInFlight = true
        io.async { [weak self, inbox] in
            do {
                _ = try inbox.finish(device:device,id:id)
                let output = try inbox.decodedDerivative(device:device,id:id)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finalizationInFlight = false
                    self.completedRecording = output; self.recordingID = nil
                    self.recordingStatus = "Coverage and per-packet decoding passed; the WAV awaits archiving and the raw audio/Ogg is kept. This does not imply lossless over-the-air audio."
                    // Archive copy + checksum, not ASR or upload. Ogg structure is not proof of acoustic completeness.
                    Task { await self.archiveReceivedRecording() }
                }
            } catch {
                DispatchQueue.main.async { self?.finalizationInFlight = false; self?.recordingStatus = "Packaging could not be completed; the raw bytes and coverage record are preserved"; self?.error = "The recording failed the integrity check and is not marked as complete audio." }
            }
        }
    }
    private func lostMessages() {
        store?.notifications.lostMessages()
        if let id = recordingID, let device = captureDevice, failedRecordings.insert(id).inserted { io.async { [inbox] in inbox.invalidate(device:device,id:id) } }
        error = "The business reception queue overflowed or the recording format mismatched; this recording cannot be marked complete."
    }
    func archiveReceivedRecording() async {
        guard let file = completedRecording, let store else { return }
        let imported = await store.archive.importFile(file,title:"Glasses recording " + Date().formatted(date:.abbreviated,time:.shortened))
        recordingStatus = imported ? "WAV archived after verification; the raw audio/Ogg is kept, with no transcription or upload" : "The WAV was saved but archiving did not succeed; retry archiving or share the file"
    }
    func retryRecordingFinish() {
        guard let id = recordingID, let device = captureDevice, finishing.contains(id) else { error = "No completion message has been received from the glasses yet; it cannot be forced to count as complete."; return }
        finishRecording(device:device,id:id)
    }
    func loadRecoveryEntries() async {
        guard !recoveryBusy, recordingID == nil, !finalizationInFlight else { recoveryStatus = "A reception task is running; finish it before scanning."; return }
        recoveryBusy = true; defer { recoveryBusy = false }
        do {
            let catalog: GlassesRecordingInbox.Catalog = try await withCheckedThrowingContinuation { continuation in
                io.async { [inbox] in continuation.resume(with:Result { try inbox.catalog() }) }
            }
            recoveryEntries = catalog.entries
            recoveryStatus = "\(catalog.entries.count) entries on this device; \(catalog.unreadable) unreadable directories stay in place. Scanning is not an integrity pass."
        } catch { recoveryStatus = "The local reception directory could not be read; it was not cleared, rebuilt, or deleted." }
    }
    func recoverRecording(_ entryID: String) async {
        guard !recoveryBusy, recordingID == nil, !finalizationInFlight else { return }
        recoveryBusy = true; defer { recoveryBusy = false }
        do {
            let file: URL = try await withCheckedThrowingContinuation { continuation in
                io.async { [inbox] in continuation.resume(with:Result { try inbox.recoverDecoded(entryID) }) }
            }
            guard let store else { return }
            let imported = await store.archive.importFile(file,title:"Recovered glasses recording")
            recoveryStatus = imported ? "Re-verified, decoded, and archived; nothing was transcribed, uploaded, or deleted." : "The WAV was recovered but archiving has not succeeded yet; the original file is kept and you can retry."
        } catch { recoveryStatus = "Recovery verification failed or this build cannot decode it; the original is kept and cannot be marked complete." }
    }
    func recoveryRawFile(_ entryID: String) async -> URL? {
        guard !recoveryBusy, recordingID == nil, !finalizationInFlight else { return nil }
        recoveryBusy = true; defer { recoveryBusy = false }
        do {
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                io.async { [inbox] in continuation.resume(with:Result { try inbox.exportRawCopy(entryID) }) }
            }
            return url
        } catch { recoveryStatus = "The original file cannot be read; no share entry was created."; return nil }
    }
    func syncTodos(pendingOnly: Bool = false) {
        perform {
            guard canControl, let device = voice.deviceID, let store else { throw DeviceFeatureError.disconnected }
            let rows = try store.todoCandidates(device: device, pendingOnly: pendingOnly)
            guard rows.count <= 100 else { throw DeviceFeatureError.storageLimit }
            for row in rows { try sendTodo(row, device:device) }
            todoStatus = "Submitted \(rows.count) todos; waiting for the glasses status/operation receipt — this does not mean the lens has displayed them"
        }
    }
    func localTodoChanged(_ row: LocalTodo) {
        guard canControl, row.archivedAt == nil, row.wireDeviceID == voice.deviceID,
              row.wireID != nil, row.delivery?.conflict == nil else { return }
        perform { guard let device = voice.deviceID else { throw DeviceFeatureError.disconnected }; try sendTodo(row,device:device) }
    }
    private func sendTodo(_ row: LocalTodo, device: String) throws {
        guard let store else { throw DeviceFeatureError.noSession }
        let current = try store.prepareTodoSubmission(row.id, device: device)
        guard let id = current.wireID, let revision = current.delivery?.revision else { throw TodoDeliveryError.missing }
        let seconds = Int64(Date().timeIntervalSince1970)
        let body: [String:Any] = ["eventType":1,"eventID":id,"createTime":Int64(current.createdAt.timeIntervalSince1970),
            "title":current.title,"isImportant":current.important ?? false,"status":current.completed ? 1 : 0,"lastModifiedTime":seconds]
        try send(22,2,body)
        store.markTodoSubmitted(row.id, device: device, revision: revision)
    }
    private func todo(_ device: String, _ wire: DeviceBusinessWire) throws {
        if wire.type == 14 { todoStatus = "Glasses operation receipt: \(DeviceBusinessWire.integer(wire.json,"successCount") ?? 0) succeeded; this is not per-item lens acceptance"; return }
        guard wire.type == 4 || wire.type == 10 else { return }
        let data = try JSONSerialization.data(withJSONObject:wire.json)
        let message = try TodoJSONCodec().decodeGlassesMessage(type:UInt16(wire.type),payload:data)
        var changes = 0
        switch message {
        case .status(let s): changes += store?.applyGlassesTodo(device:device,id:s.eventID,status:s.statusRaw,important:s.isImportant.value) == true ? 1 : 0
        case .batch(let b):
            for entry in b.eventList.value ?? [] { if case .todo(let s) = entry { changes += store?.applyGlassesTodo(device:device,id:s.eventID,status:s.statusRaw,important:s.isImportant.value) == true ? 1 : 0 } }
        default: break
        }
        todoStatus = "Applied \(changes) glasses status change(s); for offline edit conflicts check the pending-send list, and unknown IDs are not imported"
    }
    func refreshSettings() {
        perform {
            try voice.sendBusiness(15,payload:LauncherControlPrototype.encode(.requestGeneralStatus))
            try send(15,4,["cmd":"request_general_settings","payload":["value":0,"mode":0,"data":""]])
            status = "Queried; waiting for the glasses status"
        }
    }
    func setBrightness(_ value: Int) { command(type:2,cmd:"brightness_change",value:value,allowed:7...8) }
    func setHeadControl(_ enabled: Bool, mode: Int) {
        guard [0,1].contains(mode) else { return }; command(type:5,cmd:"head_gestures",value:enabled ? 1:0,mode:mode)
    }
    func setSleep(_ seconds: Int) { guard [15,25].contains(seconds) else { return }; command(type:5,cmd:"auto_lock_time",value:seconds) }
    func setDoubleTapTodo(_ todo: Bool) {
        guard let crown = settings["crownConfig"] as? [String:Any] ?? settings["crown_config"] as? [String:Any],
              let long = DeviceBusinessWire.integer(crown,"longPress") else { error = "Read the full crown settings first to avoid overwriting the existing long-press configuration."; return }
        perform { let body = try JSONSerialization.data(withJSONObject:["double":todo ? 8:0,"longPress":long]); try submitCommand(type:5,cmd:"crown_config",value:0,mode:0,data:String(decoding:body,as:UTF8.self)) }
    }
    func setDisplay(height: Int? = nil, distance: Int? = nil) {
        guard let config = settings["displayConfig"] as? [String:Any] ?? settings["display_config"] as? [String:Any],
              let oldHeight = DeviceBusinessWire.integer(config,"height"), let oldDistance = DeviceBusinessWire.integer(config,"distance"),
              height == nil || [1,3,5].contains(height!), distance == nil || [1,2].contains(distance!) else {
            error = "Read the display configuration first; only levels with existing evidence are supported and other parameters are left untouched."; return
        }
        perform {
            let data = try JSONSerialization.data(withJSONObject:["height":height.map(Int64.init) ?? oldHeight,"distance":distance.map(Int64.init) ?? oldDistance])
            try submitCommand(type:5,cmd:"display_config",value:0,mode:0,data:String(decoding:data,as:UTF8.self))
        }
    }
    func sendWeatherstack(_ snapshot: WeatherstackSnapshot, icon: Int) {
        perform { try submitWeatherstack(snapshot, icon: icon) }
    }
    func submitWeatherstack(_ snapshot: WeatherstackSnapshot, icon: Int) throws {
        guard snapshot.canSend(at:Date()) else { throw WeatherstackError.stale }
        guard (0...999).contains(icon) else { throw WeatherstackError.icon }
        try submitWeather(location:snapshot.city,temperature:snapshot.lensTemperature,icon:icon,description:snapshot.description)
    }
    func sendWeather(location: String, temperature: Int, icon: Int, description: String, current: Bool = true) {
        perform { try submitWeather(location:location,temperature:temperature,icon:icon,description:description,current:current) }
    }
    private func submitWeather(location: String, temperature: Int, icon: Int, description: String, current: Bool = true) throws {
            guard canControl, !location.isEmpty, location.utf8.count <= 80, (-80...60).contains(temperature), (0...999).contains(icon) else { throw DeviceFeatureError.invalidPacket }
            let update = SelectedCityWeatherRawUpdate(items:[CityWeatherRawItem(location:location,locationID:"companion-custom",temperatureRaw:Int64(temperature),iconRaw:Int64(icon),descriptionRaw:description,temperatureRangeRaw:"",hourly:[])],timestampRaw:String(Int64(Date().timeIntervalSince1970)))
            let msg = try current ? WeatherJSONCodec().encodeCurrentWeatherUpdate(CurrentWeatherRawUpdate(location:location,temperatureRaw:Int64(temperature),iconRaw:Int64(icon),timestampRaw:update.timestampRaw)) : CityWeatherJSONCodec().encodeUpdate(update)
            try voice.sendBusiness(15,payload:DeviceBusinessWire.encode(type:UInt32(msg.type),json:JSONSerialization.jsonObject(with:msg.payload) as! [String:Any]))
            pendingSettings[current ? "current_weather_update" : "weather_update"] = Date(); status = "Custom weather data submitted; the dashboard layout is unchanged — waiting for the receipt"
    }
    private func command(type: UInt32, cmd: String, value: Int, mode: Int = 0, allowed: ClosedRange<Int>? = nil) {
        perform { if let allowed, !allowed.contains(value) { throw DeviceFeatureError.invalidPacket }; try submitCommand(type:type,cmd:cmd,value:value,mode:mode,data:"") }
    }
    private func submitCommand(type: UInt32, cmd: String, value: Int, mode: Int, data: String) throws {
        guard canControl else { throw DeviceFeatureError.busy }
        if let since = pendingSettings[cmd], Date().timeIntervalSince(since) < 8 { throw DeviceFeatureError.busy }
        try send(15,type,["cmd":cmd,"payload":["value":value,"mode":mode,"data":data]])
        pendingSettings[cmd] = Date(); status = "Setting submitted, waiting for the glasses to report back; the displayed value is not changed in advance"
    }
    private func launcher(_ wire: DeviceBusinessWire) {
        let j = wire.json
        if wire.type == 1 {
            let state = j["generalStatus"] as? [String:Any] ?? j
            if let n = DeviceBusinessWire.integer(state,"battery") { battery = Int(n) }
            if let n = DeviceBusinessWire.integer(state,"brightness") { brightness = Int(n) }
        }
        if wire.type == 4 { settings = j["generalSettings"] as? [String:Any] ?? j; status = "Glasses general settings received" }
        guard let cmd = j["cmd"] as? String, let p = j["payload"] as? [String:Any] else { return }
        if wire.type == 3, cmd == "brightness_change", let n = DeviceBusinessWire.integer(p,"value") { brightness = Int(n) }
        if [3,6,17,19].contains(wire.type) {
            if wire.type == 6, let body = p["data"] as? String, let bytes = body.data(using:.utf8),
               let config = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
               let key = ["display_config":"displayConfig","crown_config":"crownConfig","privacy_config":"privacyConfig"][cmd] {
                settings[key] = config
            }
            pendingSettings.removeValue(forKey:cmd)
            status = "Glasses reported \(cmd.prefix(45)): \(DeviceBusinessWire.integer(p,"value") ?? -1) (lens effect not verified)"
        }
    }

    // Teleprompter state/transport is implemented in the dedicated extension below.
    @Published private(set) var teleprompterStatus = "No script sent yet"
    @Published private(set) var teleprompterID: String?
    @Published private(set) var teleprompterOffset: Int64 = 0
    var teleprompterFile: URL?
    var teleprompterDevice: String?
    var teleprompterPrepared = false
    var teleprompterSentFile = false
    var teleprompterTransferTask: String?
}

extension CompanionDeviceFeatures {
    func prepareTeleprompter(_ text: String, speed: Int) {
        perform {
            guard canControl, recordingID == nil, teleprompterID == nil, let device = voice.deviceID else { throw DeviceFeatureError.busy }
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.count <= 12_000,
                  text.utf8.count <= 48_000, (60...240).contains(speed) else { throw DeviceFeatureError.invalidPacket }
            if voice.enabled { voice.stop() }
            let did = UUID().uuidString
            let dir = inbox.root.deletingLastPathComponent().appendingPathComponent("TeleprompterOutboxV1")
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            guard try FileManager.default.contentsOfDirectory(atPath:dir.path).count < 100 else { throw DeviceFeatureError.storageLimit }
            let url = dir.appendingPathComponent(did + ".txt")
            try Data(text.utf8).write(to:url,options:[.withoutOverwriting,.completeFileProtectionUntilFirstUserAuthentication])
            teleprompterID = did; teleprompterDevice = device; teleprompterFile = url
            teleprompterOffset = 0; teleprompterPrepared = false; teleprompterSentFile = false
            // Optional layout fields intentionally omitted: never guess pixel/gear defaults.
            try send(20,2,["action":1,"did":did,"total":text.utf8.count,"scroll":2,"speed":speed,"pageOffset":0,"highLightOffset":0])
            teleprompterStatus = "Script preparation requested, waiting for the glasses to respond; follow-along/microphone is not enabled this time"
            DispatchQueue.main.asyncAfter(deadline:.now()+30) { [weak self] in
                guard let self, self.teleprompterID == did, !self.teleprompterPrepared else { return }
                self.teleprompterStatus = "Preparation timed out; receipt of the script was not confirmed and scrolling will not start automatically. Tap Exit to cancel this round."
            }
        }
    }
    func teleprompterControl(_ type: UInt32, speed: Int = 120) {
        perform {
            guard let did = teleprompterID, teleprompterDevice == voice.deviceID,
                  type == 6 || teleprompterPrepared else { throw DeviceFeatureError.noSession }
            guard [3,4,5,6,7].contains(type) else { throw DeviceFeatureError.invalidPacket }
            var body: [String:Any] = ["action":1,"did":did]
            if type == 4 { body["offset"] = teleprompterOffset; body["code"] = 1; body["isCompleted"] = false }
            if type == 7 { guard (60...240).contains(speed) else { throw DeviceFeatureError.invalidPacket }; body["scroll"] = 2; body["speed"] = speed }
            try send(20,type,body)
            if type == 6, let task = teleprompterTransferTask { voice.cancelFile(task); teleprompterTransferTask = nil }
            teleprompterStatus = "Control type\(type) submitted, waiting for the glasses to respond"
        }
    }
    private func teleprompterReceive(_ device: String, _ wire: DeviceBusinessWire) throws {
        guard let did = DeviceBusinessWire.identifier(wire.json,"did"), did == teleprompterID, teleprompterDevice == device else { return }
        let action = DeviceBusinessWire.integer(wire.json,"action"), code = DeviceBusinessWire.integer(wire.json,"code")
        if wire.type == 2, action == 2 {
            guard code == 1 || code == 7 else { teleprompterStatus = "Preparation rejected with code=\(code ?? -1); the conflict is not handled automatically"; return }
            if !teleprompterSentFile {
                guard let file = teleprompterFile else { throw DeviceFeatureError.noSession }
                teleprompterTransferTask = try voice.sendFile(file,id:did)
                teleprompterSentFile = true
                teleprompterStatus = "Sent over the dedicated file channel, waiting for business receipt confirmation; playback has not started"
            } else { teleprompterPrepared = true; teleprompterStatus = "Business success received after the file was submitted — start is now testable; there is still no independent file verification or lens proof" }
            return
        }
        if wire.type == 3, action == 2 { teleprompterStatus = "Teleprompter start response code=\(code ?? -1)"; return }
        guard let control = TeleprompterControlType(rawValue: UInt16(clamping:wire.type)) else { return }
        let data = try JSONSerialization.data(withJSONObject:wire.json)
        if action == 1 {
            let event = try TeleprompterJSONCodec().decodeGlassesRequest(type:control.rawValue,payload:data)
            switch event {
            case .progress(let p): teleprompterOffset = p.pageOffset; teleprompterStatus = "Glasses progress report: raw UTF-8 offset \(p.pageOffset)"
            case .pause: teleprompterStatus = "The glasses requested a pause"
            case .resume: teleprompterStatus = "The glasses requested to resume"
            case .stop: teleprompterStatus = "The glasses requested to exit"
            default: return
            }
            let ack = try TeleprompterJSONCodec().encodeAppResponse(type:control,did:did,code:.accepted)
            try voice.sendBusiness(20,payload:DeviceBusinessWire.encode(type:UInt32(ack.type),json:JSONSerialization.jsonObject(with:ack.payload) as! [String:Any]))
        } else if action == 2 { teleprompterStatus = "Glasses response type\(wire.type) code=\(code ?? -1)" }
        if control == .stop, action == 1 || code == 1 {
            if let task = teleprompterTransferTask { voice.cancelFile(task); teleprompterTransferTask = nil }
            teleprompterID = nil; teleprompterPrepared = false; teleprompterFile = nil
        }
    }
}
