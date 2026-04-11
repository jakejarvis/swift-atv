import Foundation

// MARK: - Value Types

/// Artwork information including image data and dimensions.
public struct ArtworkInfo: Sendable, Hashable {
    public let data: Data
    public let mimetype: String
    public let width: Int
    public let height: Int

    public init(data: Data, mimetype: String, width: Int, height: Int) {
        self.data = data
        self.mimetype = mimetype
        self.width = width
        self.height = height
    }
}

/// Metadata for streaming media to a device.
public struct MediaMetadata: Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var artwork: Data?
    public var duration: Double?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        artwork: Data? = nil,
        duration: Double? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.duration = duration
    }
}

/// Information about a specific feature's availability.
public struct FeatureInfo: Sendable, Hashable {
    public let state: FeatureState
    public let options: [String: String]

    public init(state: FeatureState, options: [String: String] = [:]) {
        self.state = state
        self.options = options
    }
}

/// An application on the device.
public struct App: Sendable, Hashable, CustomStringConvertible {
    public let name: String?
    public let identifier: String

    public init(name: String?, identifier: String) {
        self.name = name
        self.identifier = identifier
    }

    public var description: String {
        "\(name ?? "Unknown") (\(identifier))"
    }
}

/// A user account on the device.
public struct UserAccount: Sendable, Hashable, CustomStringConvertible {
    public let name: String?
    public let identifier: String

    public init(name: String?, identifier: String) {
        self.name = name
        self.identifier = identifier
    }

    public var description: String {
        "\(name ?? "Unknown") (\(identifier))"
    }
}

/// An audio output device.
public struct OutputDevice: Sendable, Hashable, CustomStringConvertible {
    public let identifier: String
    public let name: String?
    public var volume: Float

    public init(identifier: String, name: String? = nil, volume: Float = 0.0) {
        self.identifier = identifier
        self.name = name
        self.volume = volume
    }

    public var description: String {
        "\(name ?? identifier) (vol: \(volume))"
    }
}

// MARK: - Playing State

/// Current playback state information.
public struct Playing: Sendable, Hashable, CustomStringConvertible {
    public var mediaType: MediaType
    public var deviceState: DeviceState
    public var title: String?
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var totalTime: Int?
    public var position: Int?
    public var shuffle: ShuffleState?
    public var repeatState: RepeatState?
    public var seriesName: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var contentIdentifier: String?
    public var iTunesStoreIdentifier: Int?
    public var hash: String?
    public var app: App?

    public init(
        mediaType: MediaType = .unknown,
        deviceState: DeviceState = .idle,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        totalTime: Int? = nil,
        position: Int? = nil,
        shuffle: ShuffleState? = nil,
        repeatState: RepeatState? = nil,
        seriesName: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        contentIdentifier: String? = nil,
        iTunesStoreIdentifier: Int? = nil,
        hash: String? = nil,
        app: App? = nil
    ) {
        self.mediaType = mediaType
        self.deviceState = deviceState
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.totalTime = totalTime
        self.position = position
        self.shuffle = shuffle
        self.repeatState = repeatState
        self.seriesName = seriesName
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.contentIdentifier = contentIdentifier
        self.iTunesStoreIdentifier = iTunesStoreIdentifier
        self.hash = hash
        self.app = app
    }

    public var description: String {
        var parts: [String] = []
        parts.append("State: \(deviceState)")
        parts.append("Type: \(mediaType)")
        if let title { parts.append("Title: \(title)") }
        if let artist { parts.append("Artist: \(artist)") }
        if let album { parts.append("Album: \(album)") }
        if let position, let totalTime {
            parts.append("Position: \(position)/\(totalTime)s")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Remote Control Protocol

/// Remote control interface for sending button presses and commands.
public protocol RemoteControl: Sendable {
    func up(action: InputAction) async throws
    func down(action: InputAction) async throws
    func left(action: InputAction) async throws
    func right(action: InputAction) async throws
    func play() async throws
    func playPause() async throws
    func pause() async throws
    func stop() async throws
    func next() async throws
    func previous() async throws
    func select(action: InputAction) async throws
    func menu(action: InputAction) async throws
    func volumeUp() async throws
    func volumeDown() async throws
    func home(action: InputAction) async throws
    func homeHold() async throws
    func topMenu() async throws
    func suspend() async throws
    func wakeUp() async throws
    func skipForward(interval: TimeInterval) async throws
    func skipBackward(interval: TimeInterval) async throws
    func setPosition(_ position: Int) async throws
    func setShuffle(_ state: ShuffleState) async throws
    func setRepeat(_ state: RepeatState) async throws
    func channelUp() async throws
    func channelDown() async throws
    func screensaver() async throws
    func guide() async throws
    func controlCenter() async throws
}

// Default parameter values
extension RemoteControl {
    public func up() async throws { try await up(action: .singleTap) }
    public func down() async throws { try await down(action: .singleTap) }
    public func left() async throws { try await left(action: .singleTap) }
    public func right() async throws { try await right(action: .singleTap) }
    public func select() async throws { try await select(action: .singleTap) }
    public func menu() async throws { try await menu(action: .singleTap) }
    public func home() async throws { try await home(action: .singleTap) }
    public func skipForward() async throws { try await skipForward(interval: 0) }
    public func skipBackward() async throws { try await skipBackward(interval: 0) }
}

// MARK: - Metadata Protocol

/// Metadata interface for retrieving information about currently playing media.
public protocol ATVMetadata: Sendable {
    var deviceID: String? { get }
    var artworkID: String { get }
    var currentApp: App? { get }
    func artwork(width: Int?, height: Int?) async throws -> ArtworkInfo?
    func playing() async throws -> Playing
}

extension ATVMetadata {
    public func artwork() async throws -> ArtworkInfo? {
        try await artwork(width: 512, height: nil)
    }
}

// MARK: - Push Updater Protocol

/// Interface for receiving push updates about playback state changes.
public protocol PushUpdater: Sendable {
    var isActive: Bool { get }
    var playingStream: AsyncStream<Playing> { get }
    func start(initialDelay: Int) async throws
    func stop() async
}

extension PushUpdater {
    public func start() async throws { try await start(initialDelay: 0) }
}

// MARK: - Stream Protocol

/// Interface for streaming media to the device.
public protocol StreamController: Sendable {
    func playURL(_ url: URL) async throws
    func streamFile(_ fileURL: URL, metadata: MediaMetadata?) async throws
    func close() async
}

extension StreamController {
    public func streamFile(_ fileURL: URL) async throws {
        try await streamFile(fileURL, metadata: nil)
    }
}

// MARK: - Power Protocol

/// Interface for controlling device power state.
public protocol PowerController: Sendable {
    var powerState: PowerState { get async }
    var powerStateStream: AsyncStream<PowerState> { get }
    func turnOn(awaitNewState: Bool) async throws
    func turnOff(awaitNewState: Bool) async throws
}

extension PowerController {
    public func turnOn() async throws { try await turnOn(awaitNewState: false) }
    public func turnOff() async throws { try await turnOff(awaitNewState: false) }
}

// MARK: - Audio Protocol

/// Interface for controlling audio volume and output devices.
public protocol AudioController: Sendable {
    var volume: Float { get async }
    var volumeStream: AsyncStream<Float> { get }
    var outputDevices: [OutputDevice] { get async }
    var outputDevicesStream: AsyncStream<[OutputDevice]> { get }
    func setVolume(_ level: Float, device: OutputDevice?) async throws
    func volumeUp() async throws
    func volumeDown() async throws
    func addOutputDevices(_ deviceIDs: [String]) async throws
    func removeOutputDevices(_ deviceIDs: [String]) async throws
    func setOutputDevices(_ deviceIDs: [String]) async throws
}

extension AudioController {
    public func setVolume(_ level: Float) async throws {
        try await setVolume(level, device: nil)
    }
}

// MARK: - Apps Protocol

/// Interface for listing and launching apps.
public protocol AppsController: Sendable {
    func appList() async throws -> [App]
    func launchApp(bundleID: String) async throws
}

// MARK: - Keyboard Protocol

/// Interface for virtual keyboard input.
public protocol KeyboardController: Sendable {
    var textFocusState: KeyboardFocusState { get async }
    var focusStateStream: AsyncStream<KeyboardFocusState> { get }
    func textGet() async throws -> String?
    func textClear() async throws
    func textAppend(_ text: String) async throws
    func textSet(_ text: String) async throws
}

// MARK: - Touch Protocol

/// Interface for touch gestures.
public protocol TouchController: Sendable {
    func swipe(startX: Int, startY: Int, endX: Int, endY: Int, durationMs: Int) async throws
    func action(x: Int, y: Int, mode: TouchAction) async throws
    func click(action: InputAction) async throws
}

// MARK: - User Accounts Protocol

/// Interface for managing user accounts.
public protocol UserAccountsController: Sendable {
    func accountList() async throws -> [UserAccount]
    func switchAccount(_ accountID: String) async throws
}

// MARK: - Features Protocol

/// Interface for querying feature availability.
public protocol FeatureProvider: Sendable {
    func featureInfo(_ feature: FeatureName) -> FeatureInfo
    func allFeatures(includeUnsupported: Bool) -> [FeatureName: FeatureInfo]
    func inState(_ states: [FeatureState], features: FeatureName...) -> Bool
}

extension FeatureProvider {
    public func allFeatures() -> [FeatureName: FeatureInfo] {
        allFeatures(includeUnsupported: false)
    }

    public func isAvailable(_ feature: FeatureName) -> Bool {
        featureInfo(feature).state == .available
    }
}

// MARK: - Pairing Handler Protocol

/// Interface for device pairing procedures.
public protocol PairingHandler: Sendable {
    var deviceProvidesPin: Bool { get }
    var hasPaired: Bool { get }
    var service: ServiceInfo { get }
    func pin(_ pin: String) async throws
    func begin() async throws
    func finish() async throws
    func close() async
}

// MARK: - Device Listener

/// Events emitted by the device connection.
public enum DeviceEvent: Sendable {
    case connectionLost(Error)
    case connectionClosed
}

// MARK: - Apple TV Device Protocol

/// Main interface representing a connected Apple TV device.
public protocol AppleTVDevice: Sendable {
    var settings: ATVSettings { get }
    var deviceInfo: DeviceInfo { get }
    var remoteControl: RemoteControl { get }
    var metadata: ATVMetadata { get }
    var pushUpdater: PushUpdater { get }
    var stream: StreamController { get }
    var power: PowerController { get }
    var features: FeatureProvider { get }
    var apps: AppsController { get }
    var userAccounts: UserAccountsController { get }
    var audio: AudioController { get }
    var keyboard: KeyboardController { get }
    var touch: TouchController { get }
    var deviceEvents: AsyncStream<DeviceEvent> { get }

    func connect() async throws
    func close() async
}
