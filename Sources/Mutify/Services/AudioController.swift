import AudioToolbox
import CoreAudio
import Foundation
import MutifyCore

/// Everything CoreAudio: which device sound comes out of, what kind of device it
/// is, and reading/writing its volume.
@MainActor
final class AudioController {

    /// Fired when the default output device, its volume, its mute flag or its
    /// data source changes.
    var onEvent: ((Trigger) -> Void)?

    private var systemListeners: [ListenerToken] = []
    private var deviceListeners: [ListenerToken] = []
    private var listenedDevice: AudioObjectID?
    /// Our own volume writes come back as volume events; ignore the echo.
    private var lastSelfWrite: Date = .distantPast

    private struct ListenerToken {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    // MARK: - Reading the current output

    var currentOutput: OutputContext? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        let uid = Self.string(device, kAudioDevicePropertyDeviceUID) ?? "device-\(device)"
        let name = Self.string(device, kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
            ?? Self.string(device, kAudioDevicePropertyDeviceNameCFString)
            ?? "Unknown output"
        return OutputContext(
            uid: uid,
            name: name,
            transport: Self.transport(device),
            isHeadphoneDataSource: Self.isHeadphoneDataSource(device)
        )
    }

    var currentVolume: Double? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        return Self.volume(device)
    }

    var currentDeviceIsMuted: Bool? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        return Self.muted(device)
    }

    /// The data source name, e.g. "Headphones" — used in explanations.
    var currentDataSourceName: String? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        return Self.dataSourceName(device)
    }

    // MARK: - Writing

    /// Sets the output volume to zero and, where the device supports it, also
    /// raises the mute flag. Returns false if the device refused both.
    @discardableResult
    func silence() -> Bool {
        guard let device = Self.defaultOutputDevice() else { return false }
        lastSelfWrite = Date()
        let volumeOK = Self.setVolume(device, 0)
        let muteOK = Self.setMuted(device, true)
        return volumeOK || muteOK
    }

    /// Restores a volume on a specific device, which needn't be the current
    /// output — that's the point: speakers get their level back even while
    /// headphones are in use.
    @discardableResult
    func restore(volume: Double, onDeviceWithUID uid: String) -> Bool {
        guard let device = Self.device(withUID: uid) else { return false }
        lastSelfWrite = Date()
        _ = Self.setMuted(device, false)
        return Self.setVolume(device, volume)
    }

    func volume(ofDeviceWithUID uid: String) -> Double? {
        guard let device = Self.device(withUID: uid) else { return nil }
        return Self.volume(device)
    }

    func deviceExists(uid: String) -> Bool {
        Self.device(withUID: uid) != nil
    }

    static func device(withUID uid: String) -> AudioObjectID? {
        allOutputDevices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    // MARK: - Listening

    func startListening() {
        stopListening()

        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        add(listener: &address, on: AudioObjectID(kAudioObjectSystemObject), to: &systemListeners) { [weak self] in
            guard let self else { return }
            self.attachDeviceListeners()
            self.onEvent?(.outputDeviceChange)
        }

        attachDeviceListeners()
    }

    func stopListening() {
        remove(&systemListeners)
        remove(&deviceListeners)
        listenedDevice = nil
    }

    private func attachDeviceListeners() {
        remove(&deviceListeners)
        guard let device = Self.defaultOutputDevice() else { return }
        listenedDevice = device

        var volume = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        add(listener: &volume, on: device, to: &deviceListeners) { [weak self] in
            guard let self else { return }
            // Ignore the echo of our own write.
            guard Date().timeIntervalSince(self.lastSelfWrite) > 0.5 else { return }
            self.onEvent?(.volumeChange)
        }

        var mute = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        add(listener: &mute, on: device, to: &deviceListeners) { [weak self] in
            guard let self else { return }
            guard Date().timeIntervalSince(self.lastSelfWrite) > 0.5 else { return }
            self.onEvent?(.volumeChange)
        }

        // Plugging headphones into the jack keeps the same device and only
        // changes the data source.
        var source = Self.address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        add(listener: &source, on: device, to: &deviceListeners) { [weak self] in
            self?.onEvent?(.outputDeviceChange)
        }
    }

    private func add(
        listener address: inout AudioObjectPropertyAddress,
        on object: AudioObjectID,
        to store: inout [ListenerToken],
        handler: @escaping @MainActor () -> Void
    ) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        guard status == noErr else { return }
        store.append(ListenerToken(object: object, address: address, block: block))
    }

    private func remove(_ store: inout [ListenerToken]) {
        for var token in store {
            AudioObjectRemovePropertyListenerBlock(token.object, &token.address, DispatchQueue.main, token.block)
        }
        store.removeAll()
    }

    // MARK: - CoreAudio primitives

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device
        )
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private static func string(
        _ device: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func uint32(
        _ device: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var addr = address(selector, scope: scope)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func transport(_ device: AudioObjectID) -> TransportKind {
        switch uint32(device, kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        default: return .other
        }
    }

    /// 'hdpn' — headphones in the built-in jack.
    private static let headphoneDataSource: UInt32 = 0x6864_706E

    static func isHeadphoneDataSource(_ device: AudioObjectID) -> Bool {
        uint32(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput) == headphoneDataSource
    }

    static func dataSourceName(_ device: AudioObjectID) -> String? {
        guard var source = uint32(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput) else {
            return nil
        }
        var addr = address(
            kAudioDevicePropertyDataSourceNameForIDCFString,
            scope: kAudioDevicePropertyScopeOutput
        )
        var name: Unmanaged<CFString>? = nil
        return withUnsafeMutablePointer(to: &source) { input -> String? in
            withUnsafeMutablePointer(to: &name) { output -> String? in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(input),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(output),
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &translation)
                guard status == noErr, let value = output.pointee else { return nil }
                return value.takeUnretainedValue() as String
            }
        }
    }

    static func volume(_ device: AudioObjectID) -> Double? {
        var addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        var size = UInt32(MemoryLayout<Float32>.size)
        var value: Float32 = 0

        if AudioObjectHasProperty(device, &addr),
           AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
            return Double(value)
        }

        // Some devices expose no main element; average the stereo channels.
        let channels = stereoChannels(device)
        var total: Float32 = 0
        var count = 0
        for channel in channels {
            var channelAddr = address(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: channel
            )
            var channelSize = UInt32(MemoryLayout<Float32>.size)
            var channelValue: Float32 = 0
            guard AudioObjectHasProperty(device, &channelAddr),
                  AudioObjectGetPropertyData(device, &channelAddr, 0, nil, &channelSize, &channelValue) == noErr
            else { continue }
            total += channelValue
            count += 1
        }
        return count > 0 ? Double(total / Float32(count)) : nil
    }

    @discardableResult
    static func setVolume(_ device: AudioObjectID, _ volume: Double) -> Bool {
        var value = Float32(max(0, min(1, volume)))
        var addr = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false

        if AudioObjectHasProperty(device, &addr),
           AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
           settable.boolValue,
           AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr {
            return true
        }

        var wroteAnyChannel = false
        for channel in stereoChannels(device) {
            var channelAddr = address(
                kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: channel
            )
            var channelSettable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &channelAddr),
                  AudioObjectIsPropertySettable(device, &channelAddr, &channelSettable) == noErr,
                  channelSettable.boolValue
            else { continue }
            if AudioObjectSetPropertyData(
                device, &channelAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
            ) == noErr {
                wroteAnyChannel = true
            }
        }
        return wroteAnyChannel
    }

    static func muted(_ device: AudioObjectID) -> Bool? {
        guard let value = uint32(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) else {
            return nil
        }
        return value != 0
    }

    @discardableResult
    static func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool {
        var value: UInt32 = muted ? 1 : 0
        var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
              settable.boolValue
        else { return false }
        return AudioObjectSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }

    /// Every device that can play sound — used by the diagnostic mode.
    static func allOutputDevices() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices
        ) == noErr else { return [] }

        return devices.filter { device in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr else { return false }
            return streamSize > 0
        }
    }

    static func describe(_ device: AudioObjectID) -> OutputContext {
        OutputContext(
            uid: string(device, kAudioDevicePropertyDeviceUID) ?? "device-\(device)",
            name: string(device, kAudioObjectPropertyName) ?? "Unknown",
            transport: transport(device),
            isHeadphoneDataSource: isHeadphoneDataSource(device)
        )
    }

    private static func stereoChannels(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        var addr = address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioDevicePropertyScopeOutput)
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &channels) == noErr
        else { return [1, 2] }
        return channels
    }
}
