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

// MARK: - Feature State

/// Availability state of a feature.
public enum FeatureState: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
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

// MARK: - Feature Name

/// All features that can be queried from a device.
public enum FeatureName: Int, Codable, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    // Remote control
    case up = 0
    case down = 1
    case left = 2
    case right = 3
    case play = 4
    case playPause = 5
    case pause = 6
    case stop = 7
    case next = 8
    case previous = 9
    case select = 10
    case menu = 11
    case volumeUp = 12
    case volumeDown = 13
    case home = 14
    case homeHold = 15
    case topMenu = 16
    case suspend = 17
    case wakeUp = 18

    // Playback control
    case setPosition = 19
    case setShuffle = 20
    case setRepeat = 21

    // Metadata
    case title = 22
    case artist = 23
    case album = 24
    case genre = 25
    case totalTime = 26
    case position = 27
    case shuffle = 28
    case repeatState = 29

    // Media
    case artwork = 30
    case playUrl = 31
    case powerState = 32
    case turnOn = 33
    case turnOff = 34
    case app = 35
    case skipForward = 36
    case skipBackward = 37

    // Apps
    case appList = 38
    case launchApp = 39

    // Series
    case seriesName = 40
    case seasonNumber = 41
    case episodeNumber = 42

    // Push / Stream / Volume
    case pushUpdates = 43
    case streamFile = 44
    case volume = 45
    case setVolume = 46
    case contentIdentifier = 47

    // Channel
    case channelUp = 48
    case channelDown = 49

    // iTunes
    case iTunesStoreIdentifier = 50

    // Keyboard
    case textGet = 51
    case textClear = 52
    case textAppend = 53
    case textSet = 54

    // Accounts
    case accountList = 55
    case switchAccount = 56

    // Focus / Screen
    case textFocusState = 57
    case screensaver = 58

    // Output devices
    case outputDevices = 59
    case addOutputDevices = 60
    case removeOutputDevices = 61
    case setOutputDevices = 62

    // Touch
    case swipe = 63
    case action = 64
    case click = 65

    // Guide
    case guide = 66

    // Control Center
    case controlCenter = 68

    public var description: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .play: return "Play"
        case .playPause: return "Play/Pause"
        case .pause: return "Pause"
        case .stop: return "Stop"
        case .next: return "Next"
        case .previous: return "Previous"
        case .select: return "Select"
        case .menu: return "Menu"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .home: return "Home"
        case .homeHold: return "Home Hold"
        case .topMenu: return "Top Menu"
        case .suspend: return "Suspend"
        case .wakeUp: return "Wake Up"
        case .setPosition: return "Set Position"
        case .setShuffle: return "Set Shuffle"
        case .setRepeat: return "Set Repeat"
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .totalTime: return "Total Time"
        case .position: return "Position"
        case .shuffle: return "Shuffle"
        case .repeatState: return "Repeat"
        case .artwork: return "Artwork"
        case .playUrl: return "Play URL"
        case .powerState: return "Power State"
        case .turnOn: return "Turn On"
        case .turnOff: return "Turn Off"
        case .app: return "App"
        case .skipForward: return "Skip Forward"
        case .skipBackward: return "Skip Backward"
        case .appList: return "App List"
        case .launchApp: return "Launch App"
        case .seriesName: return "Series Name"
        case .seasonNumber: return "Season Number"
        case .episodeNumber: return "Episode Number"
        case .pushUpdates: return "Push Updates"
        case .streamFile: return "Stream File"
        case .volume: return "Volume"
        case .setVolume: return "Set Volume"
        case .contentIdentifier: return "Content Identifier"
        case .channelUp: return "Channel Up"
        case .channelDown: return "Channel Down"
        case .iTunesStoreIdentifier: return "iTunes Store Identifier"
        case .textGet: return "Text Get"
        case .textClear: return "Text Clear"
        case .textAppend: return "Text Append"
        case .textSet: return "Text Set"
        case .accountList: return "Account List"
        case .switchAccount: return "Switch Account"
        case .textFocusState: return "Text Focus State"
        case .screensaver: return "Screensaver"
        case .outputDevices: return "Output Devices"
        case .addOutputDevices: return "Add Output Devices"
        case .removeOutputDevices: return "Remove Output Devices"
        case .setOutputDevices: return "Set Output Devices"
        case .swipe: return "Swipe"
        case .action: return "Action"
        case .click: return "Click"
        case .guide: return "Guide"
        case .controlCenter: return "Control Center"
        }
    }
}
