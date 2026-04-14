import Foundation

enum MRPMessages {
    static func base(_ type: ProtocolMessageMessage.TypeEnum) -> ProtocolMessageMessage {
        var message = ProtocolMessageMessage()
        message.type = type
        message.identifier = UUID().uuidString
        message.timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        return message
    }

    static func deviceInformation(settings: ATVSettings) -> ProtocolMessageMessage {
        var info = DeviceInfoMessage()
        info.allowsPairing = true
        info.applicationBundleIdentifier = "com.apple.TVRemote"
        info.applicationBundleVersion = "344.28"
        info.deviceClass = .iPhone
        info.lastSupportedMessageType = 108
        info.localizedModelName = "iPhone"
        info.logicalDeviceCount = 1
        info.name = settings.clientIdentity.name
        info.protocolVersion = 1
        info.sharedQueueVersion = 2
        info.supportsAcl = true
        info.supportsExtendedMotion = true
        info.supportsSharedQueue = true
        info.supportsSystemPairing = true
        info.systemBuildVersion = "20A362"
        info.systemMediaApplication = "com.apple.TVMusic"
        info.uniqueIdentifier = settings.clientIdentity.pairingIdentifier

        var message = base(.deviceInfoMessage)
        message.deviceInfoMessage = info
        return message
    }

    static func cryptoPairing(_ pairingData: Data) -> ProtocolMessageMessage {
        var pairing = CryptoPairingMessage()
        pairing.pairingData = pairingData
        pairing.status = 0

        var message = base(.cryptoPairingMessage)
        message.cryptoPairingMessage = pairing
        return message
    }

    static func setConnectionState(_ state: SetConnectionStateMessage.ConnectionState = .connected)
        -> ProtocolMessageMessage
    {
        var inner = SetConnectionStateMessage()
        inner.state = state

        var message = base(.setConnectionStateMessage)
        message.setConnectionStateMessage = inner
        return message
    }

    static func clientUpdatesConfig() -> ProtocolMessageMessage {
        var config = ClientUpdatesConfigMessage()
        config.artworkUpdates = true
        config.keyboardUpdates = true
        config.nowPlayingUpdates = true
        config.outputDeviceUpdates = true
        config.volumeUpdates = true

        var message = base(.clientUpdatesConfigMessage)
        message.clientUpdatesConfigMessage = config
        return message
    }

    static func getKeyboardSession() -> ProtocolMessageMessage {
        var message = base(.getKeyboardSessionMessage)
        message.getKeyboardSessionMessage = ""
        return message
    }

    static func generic() -> ProtocolMessageMessage {
        var message = base(.genericMessage)
        message.genericMessage = GenericMessage()
        return message
    }

    static func wakeDevice() -> ProtocolMessageMessage {
        var message = base(.wakeDeviceMessage)
        message.wakeDeviceMessage = WakeDeviceMessage()
        return message
    }

    static func command(_ command: Command, options: CommandOptions? = nil, playerPath: PlayerPath? = nil)
        -> ProtocolMessageMessage
    {
        var inner = SendCommandMessage()
        inner.command = command
        if let options {
            inner.options = options
        }
        if let playerPath {
            inner.playerPath = playerPath
        }

        var message = base(.sendCommandMessage)
        message.sendCommandMessage = inner
        return message
    }

    static func hidEvent(usagePage: UInt16, usage: UInt16, down: Bool) -> ProtocolMessageMessage {
        var data = Data([
            0x43, 0x89, 0x22, 0xCF, 0x08, 0x02, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00,
        ])
        data.append(UInt8((usagePage >> 8) & 0xFF))
        data.append(UInt8(usagePage & 0xFF))
        data.append(UInt8((usage >> 8) & 0xFF))
        data.append(UInt8(usage & 0xFF))
        data.append(down ? 0x00 : 0x00)
        data.append(down ? 0x01 : 0x00)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0x01, 0x00, 0x00, 0x00])

        var inner = SendHIDEventMessage()
        inner.hidEventData = data

        var message = base(.sendHidEventMessage)
        message.sendHideventMessage = inner
        return message
    }

    static func playbackQueueRequest(width: Int?, height: Int?, playerPath: PlayerPath?) -> ProtocolMessageMessage {
        var request = PlaybackQueueRequestMessage()
        request.includeMetadata = true
        request.location = 0
        request.length = 1
        request.requestID = UUID().uuidString
        if let width {
            request.artworkWidth = Double(width)
        }
        if let height {
            request.artworkHeight = Double(height)
        }
        if let playerPath {
            request.playerPath = playerPath
        }

        var message = base(.playbackQueueRequestMessage)
        message.playbackQueueRequestMessage = request
        return message
    }

    static func setVolume(_ volume: Float, deviceID: String?) -> ProtocolMessageMessage {
        var inner = SetVolumeMessage()
        inner.volume = max(0, min(volume, 100)) / 100
        if let deviceID {
            inner.outputDeviceUid = deviceID
        }

        var message = base(.setVolumeMessage)
        message.setVolumeMessage = inner
        return message
    }

    static func modifyOutputContext(
        adding: [String] = [],
        removing: [String] = [],
        setting: [String] = []
    ) -> ProtocolMessageMessage {
        var inner = ModifyOutputContextRequestMessage()
        inner.type = .sharedAudioPresentation
        inner.clusterAwareAddingDevices = adding
        inner.clusterAwareRemovingDevices = removing
        inner.clusterAwareSettingDevices = setting

        var message = base(.modifyOutputContextRequestMessage)
        message.modifyOutputContextRequestMessage = inner
        return message
    }

    static func commandOptions(
        position: TimeInterval? = nil, shuffle: ShuffleState? = nil, repeatState: RepeatState? = nil
    )
        -> CommandOptions
    {
        var options = CommandOptions()
        if let position {
            options.playbackPosition = position
        }
        if let shuffle {
            options.shuffleMode = shuffle.mrpShuffleMode
        }
        if let repeatState {
            options.repeatMode = repeatState.mrpRepeatMode
        }
        return options
    }
}

extension ShuffleState {
    var mrpShuffleMode: ShuffleMode.Enum {
        switch self {
        case .off: return .off
        case .albums: return .albums
        case .songs: return .songs
        }
    }
}

extension RepeatState {
    var mrpRepeatMode: RepeatMode.Enum {
        switch self {
        case .off: return .off
        case .track: return .one
        case .all: return .all
        }
    }
}

extension ShuffleMode.Enum {
    var swiftState: ShuffleState? {
        switch self {
        case .off: return .off
        case .albums: return .albums
        case .songs: return .songs
        case .unknown: return nil
        }
    }
}

extension RepeatMode.Enum {
    var swiftState: RepeatState? {
        switch self {
        case .off: return .off
        case .one: return .track
        case .all: return .all
        case .unknown: return nil
        }
    }
}
