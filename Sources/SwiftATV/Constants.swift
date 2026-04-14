// MARK: - Protocol

/// Communication protocols supported for Apple TV interaction.
public enum ATVProtocol: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case mrp = 1
    case airPlay = 2
    case companion = 3

    public var description: String {
        switch self {
        case .mrp: return "MRP"
        case .airPlay: return "AirPlay"
        case .companion: return "Companion"
        }
    }
}

// MARK: - Device State

/// Current playback state of the device.
public enum DeviceState: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case idle = 0
    case loading = 1
    case paused = 2
    case playing = 3
    case stopped = 4
    case seeking = 5

    public var description: String {
        switch self {
        case .idle: return "Idle"
        case .loading: return "Loading"
        case .paused: return "Paused"
        case .playing: return "Playing"
        case .stopped: return "Stopped"
        case .seeking: return "Seeking"
        }
    }
}

// MARK: - Media Type

/// Type of media currently playing.
public enum MediaType: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case unknown = 0
    case video = 1
    case music = 2
    case tv = 3

    public var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .video: return "Video"
        case .music: return "Music"
        case .tv: return "TV"
        }
    }
}

// MARK: - Repeat State

/// Repeat mode for playback.
public enum RepeatState: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case off = 0
    case track = 1
    case all = 2

    public var description: String {
        switch self {
        case .off: return "Off"
        case .track: return "Track"
        case .all: return "All"
        }
    }
}

// MARK: - Shuffle State

/// Shuffle mode for playback.
public enum ShuffleState: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case off = 0
    case albums = 1
    case songs = 2

    public var description: String {
        switch self {
        case .off: return "Off"
        case .albums: return "Albums"
        case .songs: return "Songs"
        }
    }
}

// MARK: - Power State

/// Power state of the device.
public enum PowerState: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case unknown = 0
    case off = 1
    case on = 2

    public var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .off: return "Off"
        case .on: return "On"
        }
    }
}

// MARK: - Operating System

/// Operating system running on the device.
public enum OperatingSystem: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case unknown = 0
    case legacy = 1
    case tvOS = 2
    case airPortOS = 3
    case macOS = 4

    public var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .legacy: return "Legacy"
        case .tvOS: return "tvOS"
        case .airPortOS: return "AirPortOS"
        case .macOS: return "macOS"
        }
    }
}

// MARK: - Device Model

/// Known Apple device models.
public enum DeviceModel: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case unknown = 0
    case gen2 = 1
    case gen3 = 2
    case gen4 = 3
    case gen4K = 4
    case homePod = 5
    case homePodMini = 6
    case airPortExpress = 7
    case airPortExpressGen2 = 8
    case gen4K2 = 9
    case music = 10
    case gen4K3 = 11
    case homePod2 = 12
    case gen1 = 13

    public var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .gen1: return "Apple TV (1st gen)"
        case .gen2: return "Apple TV (2nd gen)"
        case .gen3: return "Apple TV (3rd gen)"
        case .gen4: return "Apple TV (4th gen)"
        case .gen4K: return "Apple TV 4K"
        case .homePod: return "HomePod"
        case .homePodMini: return "HomePod Mini"
        case .airPortExpress: return "AirPort Express (1st gen)"
        case .airPortExpressGen2: return "AirPort Express (2nd gen)"
        case .gen4K2: return "Apple TV 4K (2nd gen)"
        case .music: return "Music/iTunes"
        case .gen4K3: return "Apple TV 4K (3rd gen)"
        case .homePod2: return "HomePod (2nd gen)"
        }
    }
}

// MARK: - Input Action

/// Type of button press action.
public enum InputAction: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case singleTap = 0
    case doubleTap = 1
    case hold = 2

    public var description: String {
        switch self {
        case .singleTap: return "Single Tap"
        case .doubleTap: return "Double Tap"
        case .hold: return "Hold"
        }
    }
}

// MARK: - Touch Action

/// Type of touch gesture action.
public enum TouchAction: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case press = 1
    case hold = 3
    case release = 4
    case click = 5

    public var description: String {
        switch self {
        case .press: return "Press"
        case .hold: return "Hold"
        case .release: return "Release"
        case .click: return "Click"
        }
    }
}

// MARK: - Keyboard Focus State

/// State of keyboard focus on the device.
public enum KeyboardFocusState: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case unknown = 0
    case unfocused = 1
    case focused = 2

    public var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .unfocused: return "Unfocused"
        case .focused: return "Focused"
        }
    }
}

// MARK: - Pairing Requirement

/// Whether pairing is required, optional, or unsupported.
public enum PairingRequirement: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case unsupported = 1
    case disabled = 2
    case notNeeded = 3
    case optional = 4
    case mandatory = 5

    public var description: String {
        switch self {
        case .unsupported: return "Unsupported"
        case .disabled: return "Disabled"
        case .notNeeded: return "Not Needed"
        case .optional: return "Optional"
        case .mandatory: return "Mandatory"
        }
    }
}

// MARK: - Capability State

/// Availability state of a capability.
public enum CapabilityState: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case unknown = 0
    case unsupported = 1
    case unavailable = 2
    case available = 3

    public var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .unsupported: return "Unsupported"
        case .unavailable: return "Unavailable"
        case .available: return "Available"
        }
    }
}

// MARK: - Capabilities

/// Remote-control buttons and HID-style actions.
public enum RemoteCapability: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case up
    case down
    case left
    case right
    case select
    case menu
    case volumeUp
    case volumeDown
    case home
    case homeHold
    case topMenu
    case suspend
    case wakeUp
    case playPause
    case channelUp
    case channelDown
    case screensaver
    case guide
    case controlCenter

    public var description: String { rawValue }
}

/// MediaRemote commands that can be sent through MRP or compatible control surfaces.
public enum MediaRemoteCommand: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case play
    case pause
    case togglePlayPause
    case stop
    case nextTrack
    case previousTrack
    case advanceShuffleMode
    case advanceRepeatMode
    case beginFastForward
    case endFastForward
    case beginRewind
    case endRewind
    case rewind15Seconds
    case fastForward15Seconds
    case rewind30Seconds
    case fastForward30Seconds
    case skipForward
    case skipBackward
    case changePlaybackRate
    case rateTrack
    case likeTrack
    case dislikeTrack
    case bookmarkTrack
    case nextChapter
    case previousChapter
    case nextAlbum
    case previousAlbum
    case nextPlaylist
    case previousPlaylist
    case banTrack
    case addTrackToWishList
    case removeTrackFromWishList
    case nextInContext
    case previousInContext
    case resetPlaybackTimeout
    case seekToPlaybackPosition
    case changeRepeatMode
    case changeShuffleMode
    case setPlaybackQueue
    case addNowPlayingItemToLibrary
    case createRadioStation
    case addItemToLibrary
    case insertIntoPlaybackQueue
    case enableLanguageOption
    case disableLanguageOption
    case reorderPlaybackQueue
    case removeFromPlaybackQueue
    case playItemInPlaybackQueue
    case prepareForSetQueue
    case setPlaybackSession
    case preloadedPlaybackSession
    case setPriorityForPlaybackSession
    case discardPlaybackSession
    case reshuffle
    case changeQueueEndAction

    public var description: String { rawValue }
}

/// Metadata fields that may be populated by the active protocol.
public enum MetadataCapability: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case deviceID
    case artworkID
    case currentApp
    case artwork
    case playing
    case title
    case artist
    case album
    case genre
    case totalTime
    case position
    case shuffle
    case repeatState
    case seriesName
    case seasonNumber
    case episodeNumber
    case contentIdentifier
    case iTunesStoreIdentifier

    public var description: String { rawValue }
}

/// Push-update capabilities.
public enum PushCapability: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case updates

    public var description: String { rawValue }
}

/// Streaming capabilities.
public enum StreamCapability: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case playURL
    case streamFile

    public var description: String { rawValue }
}

/// Power-control capabilities.
public enum PowerCapability: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case state
    case turnOn
    case turnOff

    public var description: String { rawValue }
}

/// Audio and output-device capabilities.
public enum AudioCapability: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case volume
    case setVolume
    case volumeUp
    case volumeDown
    case outputDevices
    case addOutputDevices
    case removeOutputDevices
    case setOutputDevices

    public var description: String { rawValue }
}

/// App-management capabilities.
public enum AppsCapability: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case list
    case launch

    public var description: String { rawValue }
}

/// User-account capabilities.
public enum AccountsCapability: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case list
    case switchAccount

    public var description: String { rawValue }
}

/// Keyboard focus and text-entry capabilities.
public enum KeyboardCapability: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case focusState
    case textGet
    case textClear
    case textAppend
    case textSet

    public var description: String { rawValue }
}

/// Touch-surface capabilities.
public enum TouchCapability: String, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case swipe
    case action
    case click

    public var description: String { rawValue }
}

/// A typed capability exposed by a connected Apple TV.
public enum Capability: Sendable, Hashable, CaseIterable, Codable, CustomStringConvertible {
    case remote(RemoteCapability)
    case mediaCommand(MediaRemoteCommand)
    case metadata(MetadataCapability)
    case push(PushCapability)
    case stream(StreamCapability)
    case power(PowerCapability)
    case audio(AudioCapability)
    case apps(AppsCapability)
    case accounts(AccountsCapability)
    case keyboard(KeyboardCapability)
    case touch(TouchCapability)

    public static var allCases: [Capability] {
        RemoteCapability.allCases.map(Capability.remote)
            + MediaRemoteCommand.allCases.map(Capability.mediaCommand)
            + MetadataCapability.allCases.map(Capability.metadata)
            + PushCapability.allCases.map(Capability.push)
            + StreamCapability.allCases.map(Capability.stream)
            + PowerCapability.allCases.map(Capability.power)
            + AudioCapability.allCases.map(Capability.audio)
            + AppsCapability.allCases.map(Capability.apps)
            + AccountsCapability.allCases.map(Capability.accounts)
            + KeyboardCapability.allCases.map(Capability.keyboard)
            + TouchCapability.allCases.map(Capability.touch)
    }

    public var description: String { identifier }

    public var identifier: String {
        switch self {
        case .remote(let capability): return "remote.\(capability.rawValue)"
        case .mediaCommand(let command): return "mediaCommand.\(command.rawValue)"
        case .metadata(let capability): return "metadata.\(capability.rawValue)"
        case .push(let capability): return "push.\(capability.rawValue)"
        case .stream(let capability): return "stream.\(capability.rawValue)"
        case .power(let capability): return "power.\(capability.rawValue)"
        case .audio(let capability): return "audio.\(capability.rawValue)"
        case .apps(let capability): return "apps.\(capability.rawValue)"
        case .accounts(let capability): return "accounts.\(capability.rawValue)"
        case .keyboard(let capability): return "keyboard.\(capability.rawValue)"
        case .touch(let capability): return "touch.\(capability.rawValue)"
        }
    }

    public init(identifier: String) throws {
        let parts = identifier.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Invalid capability identifier \(identifier)")
            )
        }

        switch parts[0] {
        case "remote":
            guard let value = RemoteCapability(rawValue: parts[1]) else { throw Self.invalidIdentifier(identifier) }
            self = .remote(value)
        case "mediaCommand":
            guard let value = MediaRemoteCommand(rawValue: parts[1]) else { throw Self.invalidIdentifier(identifier) }
            self = .mediaCommand(value)
        case "metadata":
            guard let value = MetadataCapability(rawValue: parts[1]) else { throw Self.invalidIdentifier(identifier) }
            self = .metadata(value)
        case "push":
            guard let value = PushCapability(rawValue: parts[1]) else { throw Self.invalidIdentifier(identifier) }
            self = .push(value)
        case "stream":
            guard let value = StreamCapability(rawValue: parts[1]) else { throw Self.invalidIdentifier(identifier) }
            self = .stream(value)
        case "power":
            guard let value = PowerCapability(rawValue: parts[1]) else { throw Self.invalidIdentifier(identifier) }
            self = .power(value)
        case "audio":
            guard let value = AudioCapability(rawValue: parts[1]) else { throw Self.invalidIdentifier(identifier) }
            self = .audio(value)
        case "apps":
            guard let value = AppsCapability(rawValue: parts[1]) else { throw Self.invalidIdentifier(identifier) }
            self = .apps(value)
        case "accounts":
            guard let value = AccountsCapability(rawValue: parts[1]) else { throw Self.invalidIdentifier(identifier) }
            self = .accounts(value)
        case "keyboard":
            guard let value = KeyboardCapability(rawValue: parts[1]) else { throw Self.invalidIdentifier(identifier) }
            self = .keyboard(value)
        case "touch":
            guard let value = TouchCapability(rawValue: parts[1]) else { throw Self.invalidIdentifier(identifier) }
            self = .touch(value)
        default:
            throw Self.invalidIdentifier(identifier)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(identifier: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }

    private static func invalidIdentifier(_ identifier: String) -> DecodingError {
        DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Invalid capability identifier \(identifier)")
        )
    }
}
