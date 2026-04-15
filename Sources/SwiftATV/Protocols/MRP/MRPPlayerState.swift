import Foundation
import SwiftProtobuf

private let defaultPlayerIdentifier = "MediaRemote-DefaultPlayer"
private let cocoaEpochDelta = 978_307_200.0
private typealias ATVMediaType = MediaType

private struct MRPPlayerPathKey: Hashable, Sendable {
    var bundleID: String
    var playerID: String
}

private struct MRPPlayerSnapshot: Sendable {
    var client: NowPlayingClient?
    var player: NowPlayingPlayer?
    var playerPath: PlayerPath?
    var playbackState: PlaybackState.Enum?
    var playbackStateTimestamp: Double?
    var item: ContentItem?
    var supportedCommands: [Command: CommandInfo] = [:]
}

/// Tracks direct-MRP now-playing state across clients and players.
///
/// Apple TV can report multiple media clients and multiple players per client.
/// This actor keeps the active client/player pointers and builds SwiftATV's
/// `Playing` value from the same MRP message families that pyatv's
/// `MRPPlayerState` consumes.
public actor MRPPlayerState {
    private var activeClientBundleID: String?
    private var activePlayerID: String?
    private var clients: [String: NowPlayingClient] = [:]
    private var players: [MRPPlayerPathKey: MRPPlayerSnapshot] = [:]
    private var defaultSupportedCommands: [Command: CommandInfo] = [:]
    private var continuations: [UUID: AsyncStream<Playing>.Continuation] = [:]

    public init() {}

    /// The currently active playback state.
    public var currentPlaying: Playing {
        get async { playing() }
    }

    var activePlayerPath: PlayerPath? {
        guard let snapshot = activeSnapshot() else {
            return nil
        }
        return snapshot.playerPath
    }

    var currentApp: App? {
        guard let bundleID = activeClientBundleID, let client = clients[bundleID] else {
            return nil
        }
        return App(name: client.hasDisplayName ? client.displayName : nil, identifier: bundleID)
    }

    var artworkID: String {
        let item = activeSnapshot()?.item
        if let metadata = item?.metadata, metadata.hasArtworkIdentifier {
            return metadata.artworkIdentifier
        }
        if let id = item?.identifier, !id.isEmpty {
            return id
        }
        return ""
    }

    func pushStream() -> AsyncStream<Playing> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weakBox = WeakMRPPlayerState(self)] _ in
                Task {
                    await weakBox.value?.removeContinuation(id)
                }
            }
        }
    }

    internal func _testContinuationCount() -> Int {
        continuations.count
    }

    func process(_ message: ProtocolMessageMessage) {
        switch message.type {
        case .setStateMessage:
            update(with: message.setStateMessage)
        case .updateContentItemMessage:
            update(with: message.updateContentItemMessage)
        case .setNowPlayingClientMessage:
            setActiveClient(message.setNowPlayingClientMessage.client)
        case .setNowPlayingPlayerMessage:
            setActivePlayer(message.setNowPlayingPlayerMessage.playerPath)
        case .updateClientMessage:
            updateClient(message.updateClientMessage.client)
        case .removeClientMessage:
            removeClient(message.removeClientMessage.client)
        case .removePlayerMessage:
            removePlayer(message.removePlayerMessage.playerPath)
        case .setDefaultSupportedCommandsMessage:
            setDefaultSupportedCommands(message.setDefaultSupportedCommandsMessage)
        default:
            return
        }
        publish()
    }

    func commandInfo(_ command: Command) -> CommandInfo? {
        activeSnapshot()?.supportedCommands[command] ?? defaultSupportedCommands[command]
    }

    func capabilityState(for command: Command) -> CapabilityState {
        guard let info = commandInfo(command) else {
            return .unavailable
        }
        return info.enabled ? .available : .unavailable
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func publish() {
        let state = playing()
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    private func setActiveClient(_ client: NowPlayingClient) {
        guard !client.bundleIdentifier.isEmpty else {
            return
        }
        clients[client.bundleIdentifier] = client
        activeClientBundleID = client.bundleIdentifier
    }

    private func setActivePlayer(_ path: PlayerPath) {
        let ids = identifiers(from: path)
        guard let bundleID = ids.bundleID else {
            return
        }
        if path.hasClient {
            clients[bundleID] = path.client
        }
        activeClientBundleID = bundleID
        activePlayerID = ids.playerID
        var snapshot = ensureSnapshot(bundleID: bundleID, playerID: ids.playerID)
        snapshot.playerPath = path
        players[MRPPlayerPathKey(bundleID: bundleID, playerID: ids.playerID)] = snapshot
    }

    private func updateClient(_ client: NowPlayingClient) {
        guard !client.bundleIdentifier.isEmpty else {
            return
        }
        clients[client.bundleIdentifier] = client
    }

    private func removeClient(_ client: NowPlayingClient) {
        let bundleID = client.bundleIdentifier
        clients.removeValue(forKey: bundleID)
        players = players.filter { $0.key.bundleID != bundleID }
        if activeClientBundleID == bundleID {
            activeClientBundleID = nil
            activePlayerID = nil
        }
    }

    private func removePlayer(_ path: PlayerPath) {
        let ids = identifiers(from: path)
        guard let bundleID = ids.bundleID else {
            return
        }
        let key = MRPPlayerPathKey(bundleID: bundleID, playerID: ids.playerID)
        players.removeValue(forKey: key)
        if activeClientBundleID == bundleID, activePlayerID == ids.playerID {
            activePlayerID = nil
        }
    }

    private func update(with state: SetStateMessage) {
        let ids = identifiers(from: state.playerPath)
        let bundleID = ids.bundleID ?? activeClientBundleID ?? ""
        guard !bundleID.isEmpty else {
            return
        }
        if state.playerPath.hasClient {
            clients[bundleID] = state.playerPath.client
        }
        let playerID = ids.playerID
        var snapshot = ensureSnapshot(bundleID: bundleID, playerID: playerID)
        if state.hasPlaybackState {
            snapshot.playbackState = state.playbackState
        }
        if state.hasPlaybackStateTimestamp {
            snapshot.playbackStateTimestamp = state.playbackStateTimestamp
        }
        if state.hasPlayerPath {
            snapshot.playerPath = state.playerPath
            snapshot.client = state.playerPath.hasClient ? state.playerPath.client : snapshot.client
            snapshot.player = state.playerPath.hasPlayer ? state.playerPath.player : snapshot.player
        }
        if state.hasSupportedCommands {
            snapshot.supportedCommands = commandMap(from: state.supportedCommands)
        }
        if state.hasPlaybackQueue, let item = state.playbackQueue.contentItems.first {
            snapshot.item = item
        }
        if state.hasPlaybackState, state.playbackState == .stopped {
            snapshot.item = nil
        }
        players[MRPPlayerPathKey(bundleID: bundleID, playerID: playerID)] = snapshot
        activeClientBundleID = bundleID
        activePlayerID = playerID
    }

    private func update(with content: UpdateContentItemMessage) {
        let ids = identifiers(from: content.playerPath)
        let bundleID = ids.bundleID ?? activeClientBundleID ?? ""
        guard !bundleID.isEmpty, !content.contentItems.isEmpty else {
            return
        }
        let playerID = ids.playerID
        var snapshot = ensureSnapshot(bundleID: bundleID, playerID: playerID)
        if let currentItem = snapshot.item, currentItem.hasIdentifier {
            guard
                let update = content.contentItems.first(where: { item in
                    item.hasIdentifier && item.identifier == currentItem.identifier
                })
            else {
                return
            }
            snapshot.item = mergeContentItem(currentItem, with: update)
        } else if let update = content.contentItems.first {
            snapshot.item = mergeContentItem(snapshot.item, with: update)
        }
        snapshot.playerPath = content.hasPlayerPath ? content.playerPath : snapshot.playerPath
        players[MRPPlayerPathKey(bundleID: bundleID, playerID: playerID)] = snapshot
    }

    private func setDefaultSupportedCommands(_ message: SetDefaultSupportedCommandsMessage) {
        defaultSupportedCommands = commandMap(from: message.supportedCommands)
        let ids = identifiers(from: message.playerPath)
        guard let bundleID = ids.bundleID else {
            return
        }
        var snapshot = ensureSnapshot(bundleID: bundleID, playerID: ids.playerID)
        snapshot.supportedCommands = defaultSupportedCommands
        players[MRPPlayerPathKey(bundleID: bundleID, playerID: ids.playerID)] = snapshot
    }

    private func ensureSnapshot(bundleID: String, playerID: String) -> MRPPlayerSnapshot {
        let key = MRPPlayerPathKey(bundleID: bundleID, playerID: playerID)
        if let snapshot = players[key] {
            return snapshot
        }
        return MRPPlayerSnapshot(client: clients[bundleID])
    }

    private func activeSnapshot() -> MRPPlayerSnapshot? {
        guard let bundleID = activeClientBundleID else {
            return nil
        }
        if let playerID = activePlayerID {
            let key = MRPPlayerPathKey(bundleID: bundleID, playerID: playerID)
            if let snapshot = players[key] {
                return snapshot
            }
        }
        let defaultKey = MRPPlayerPathKey(bundleID: bundleID, playerID: defaultPlayerIdentifier)
        if let snapshot = players[defaultKey] {
            return snapshot
        }
        return players.first { $0.key.bundleID == bundleID }?.value
    }

    private func identifiers(from path: PlayerPath) -> (bundleID: String?, playerID: String) {
        let bundleID =
            path.hasClient && !path.client.bundleIdentifier.isEmpty
            ? path.client.bundleIdentifier : nil
        let playerID =
            path.hasPlayer && !path.player.identifier.isEmpty
            ? path.player.identifier : defaultPlayerIdentifier
        return (bundleID, playerID)
    }

    private func commandMap(from commands: SupportedCommands) -> [Command: CommandInfo] {
        Dictionary(uniqueKeysWithValues: commands.supportedCommands.map { ($0.command, $0) })
    }

    private func playing() -> Playing {
        guard let snapshot = activeSnapshot() else {
            return Playing()
        }

        let item = snapshot.item
        let metadata = item?.metadata
        let app = currentApp

        return Playing(
            mediaType: metadata?.swiftMediaType ?? .unknown,
            deviceState: deviceState(snapshot: snapshot),
            title: metadata?.hasTitle == true ? metadata?.title : nil,
            artist: metadata?.hasTrackArtistName == true ? metadata?.trackArtistName : nil,
            album: metadata?.hasAlbumName == true ? metadata?.albumName : nil,
            genre: metadata?.hasGenre == true ? metadata?.genre : nil,
            totalTime: metadata?.hasDuration == true ? Self.intValue(metadata?.duration ?? 0) : nil,
            position: playbackPosition(snapshot: snapshot),
            shuffle: shuffleState(snapshot),
            repeatState: repeatState(snapshot),
            seriesName: metadata?.hasSeriesName == true ? metadata?.seriesName : nil,
            seasonNumber: metadata?.hasSeasonNumber == true ? Int(metadata?.seasonNumber ?? 0) : nil,
            episodeNumber: metadata?.hasEpisodeNumber == true ? Int(metadata?.episodeNumber ?? 0) : nil,
            contentIdentifier: metadata?.hasContentIdentifier == true ? metadata?.contentIdentifier : nil,
            iTunesStoreIdentifier: metadata?.hasITunesStoreIdentifier == true
                ? Int(metadata?.iTunesStoreIdentifier ?? 0) : nil,
            hash: item?.hasIdentifier == true ? item?.identifier : nil,
            app: app
        )
    }

    private func deviceState(snapshot: MRPPlayerSnapshot) -> DeviceState {
        switch snapshot.playbackState {
        case .playing:
            if snapshot.item?.metadata.hasPlaybackRate == true, snapshot.item?.metadata.playbackRate == 0 {
                return .paused
            }
            if snapshot.item?.metadata.hasPlaybackRate == true, snapshot.item?.metadata.playbackRate == 2 {
                return .seeking
            }
            return .playing
        case .paused:
            return .paused
        case .stopped:
            return .stopped
        case .interrupted:
            return .loading
        case .seeking:
            return .seeking
        case .unknown, nil:
            return .idle
        }
    }

    private func playbackPosition(snapshot: MRPPlayerSnapshot) -> Int? {
        guard let metadata = snapshot.item?.metadata else {
            return nil
        }
        let elapsed = metadata.hasElapsedTime ? metadata.elapsedTime : 0
        if metadata.hasElapsedTimeTimestamp {
            guard metadata.elapsedTimeTimestamp.isFinite else {
                return Self.intValue(elapsed)
            }
            guard deviceState(snapshot: snapshot) == .playing else {
                return Self.intValue(elapsed)
            }
            let cocoaNow = Date().timeIntervalSince1970 - cocoaEpochDelta
            let delta = max(0, cocoaNow - metadata.elapsedTimeTimestamp)
            return Self.intValue(elapsed + delta)
        }
        if metadata.hasElapsedTime {
            return Self.intValue(metadata.elapsedTime)
        }
        return nil
    }

    private static func intValue(_ value: Double) -> Int? {
        guard value.isFinite,
            value >= Double(Int.min),
            value <= Double(Int.max)
        else {
            return nil
        }
        return Int(value)
    }

    private func mergeContentItem(_ existing: ContentItem?, with update: ContentItem) -> ContentItem {
        var item = existing ?? ContentItem()
        if update.hasIdentifier {
            item.identifier = update.identifier
        }
        if update.hasMetadata {
            item.metadata = mergeMetadata(
                item.hasMetadata ? item.metadata : ContentItemMetadata(),
                with: update.metadata
            )
        }
        if update.hasArtworkData {
            item.artworkData = update.artworkData
        }
        if update.hasInfo {
            item.info = update.info
        }
        if !update.availableLanguageOptions.isEmpty {
            item.availableLanguageOptions = update.availableLanguageOptions
        }
        if !update.currentLanguageOptions.isEmpty {
            item.currentLanguageOptions = update.currentLanguageOptions
        }
        if update.hasParentIdentifier {
            item.parentIdentifier = update.parentIdentifier
        }
        if update.hasAncestorIdentifier {
            item.ancestorIdentifier = update.ancestorIdentifier
        }
        if update.hasQueueIdentifier {
            item.queueIdentifier = update.queueIdentifier
        }
        if update.hasRequestIdentifier {
            item.requestIdentifier = update.requestIdentifier
        }
        if update.hasArtworkDataWidth {
            item.artworkDataWidth = update.artworkDataWidth
        }
        if update.hasArtworkDataHeight {
            item.artworkDataHeight = update.artworkDataHeight
        }
        return item
    }

    private func mergeMetadata(
        _ existing: ContentItemMetadata,
        with update: ContentItemMetadata
    ) -> ContentItemMetadata {
        var metadata = existing
        do {
            try metadata.merge(serializedBytes: update.serializedData())
            return metadata
        } catch {
            return update
        }
    }

    private func shuffleState(_ snapshot: MRPPlayerSnapshot) -> ShuffleState? {
        guard let info = snapshot.supportedCommands[.changeShuffleMode], info.hasShuffleMode else {
            return nil
        }
        return info.shuffleMode.swiftState
    }

    private func repeatState(_ snapshot: MRPPlayerSnapshot) -> RepeatState? {
        guard let info = snapshot.supportedCommands[.changeRepeatMode], info.hasRepeatMode else {
            return nil
        }
        return info.repeatMode.swiftState
    }
}

private final class WeakMRPPlayerState: @unchecked Sendable {
    weak var value: MRPPlayerState?

    init(_ value: MRPPlayerState) {
        self.value = value
    }
}

extension ContentItemMetadata {
    fileprivate var swiftMediaType: ATVMediaType {
        switch mediaType {
        case .audio: return .music
        case .video: return .video
        case .unknownMediaType: return .unknown
        }
    }
}
