import XCTest
@testable import SwiftATV

/// Ported from pyatv tests/test_interface.py
final class InterfaceTests: XCTestCase {

    // MARK: - Playing (test_interface.py::test_playing_*)

    func testPlayingMediaTypeAndPlaystate() {
        let playing = Playing(mediaType: .video, deviceState: .playing)
        let out = playing.description
        XCTAssertTrue(out.contains("Video"))
        XCTAssertTrue(out.contains("Playing"))
    }

    func testPlayingBasicFields() {
        let playing = Playing(
            mediaType: .unknown,
            deviceState: .idle,
            title: "mytitle",
            artist: "myartist",
            album: "myalbum",
            genre: "mygenre",
            seriesName: "myseries",
            seasonNumber: 1245,
            episodeNumber: 2468,
            contentIdentifier: "content_id",
            iTunesStoreIdentifier: 123456789
        )

        let out = playing.description
        XCTAssertTrue(out.contains("mytitle"))
        XCTAssertTrue(out.contains("myartist"))
    }

    func testPlayingOnlyPosition() {
        let playing = Playing(position: 1234)
        let out = playing.description
        XCTAssertTrue(out.contains("1234"))
    }

    func testPlayingOnlyTotalTime() {
        let playing = Playing(totalTime: 5678)
        let out = playing.description
        XCTAssertTrue(out.contains("5678"))
    }

    func testPlayingBothPositionAndTotalTime() {
        let playing = Playing(position: 1234, totalTime: 5678)
        let out = playing.description
        XCTAssertTrue(out.contains("1234/5678"))
    }

    func testPlayingDefaults() {
        let playing = Playing()
        XCTAssertEqual(playing.mediaType, .unknown)
        XCTAssertEqual(playing.deviceState, .idle)
        XCTAssertNil(playing.title)
        XCTAssertNil(playing.artist)
        XCTAssertNil(playing.album)
        XCTAssertNil(playing.genre)
        XCTAssertNil(playing.totalTime)
        XCTAssertNil(playing.position)
        XCTAssertNil(playing.shuffle)
        XCTAssertNil(playing.repeatState)
        XCTAssertNil(playing.seriesName)
        XCTAssertNil(playing.seasonNumber)
        XCTAssertNil(playing.episodeNumber)
        XCTAssertNil(playing.contentIdentifier)
        XCTAssertNil(playing.iTunesStoreIdentifier)
    }

    func testPlayingEquality() {
        let playing1 = Playing(title: "foo")
        let playing2 = Playing(title: "bar")
        let playing3 = Playing(title: "bar")

        XCTAssertEqual(playing1, playing1)
        XCTAssertNotEqual(playing1, playing2)
        XCTAssertEqual(playing2, playing3)
    }

    func testPlayingMediaTypeEquality() {
        let p1 = Playing(mediaType: .video)
        let p2 = Playing(mediaType: .music)
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingDeviceStateEquality() {
        let p1 = Playing(deviceState: .idle)
        let p2 = Playing(deviceState: .playing)
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingTitleEquality() {
        let p1 = Playing(title: "foo")
        let p2 = Playing(title: "bar")
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingArtistEquality() {
        let p1 = Playing(artist: "abra")
        let p2 = Playing(artist: "kadabra")
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingAlbumEquality() {
        let p1 = Playing(album: "banana")
        let p2 = Playing(album: "apple")
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingGenreEquality() {
        let p1 = Playing(genre: "cat")
        let p2 = Playing(genre: "mouse")
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingTotalTimeEquality() {
        let p1 = Playing(totalTime: 210)
        let p2 = Playing(totalTime: 2000)
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingPositionEquality() {
        let p1 = Playing(position: 555)
        let p2 = Playing(position: 888)
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingShuffleEquality() {
        let p1 = Playing(shuffle: .albums)
        let p2 = Playing(shuffle: .songs)
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingRepeatEquality() {
        let p1 = Playing(repeatState: .track)
        let p2 = Playing(repeatState: .all)
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingSeriesNameEquality() {
        let p1 = Playing(seriesName: "show1")
        let p2 = Playing(seriesName: "show2")
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingSeasonNumberEquality() {
        let p1 = Playing(seasonNumber: 1)
        let p2 = Playing(seasonNumber: 20)
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingEpisodeNumberEquality() {
        let p1 = Playing(episodeNumber: 13)
        let p2 = Playing(episodeNumber: 24)
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingContentIdentifierEquality() {
        let p1 = Playing(contentIdentifier: "abc")
        let p2 = Playing(contentIdentifier: "def")
        XCTAssertNotEqual(p1, p2)
    }

    func testPlayingInitFieldValues() {
        let p = Playing(
            mediaType: .video,
            deviceState: .playing,
            title: "test",
            artist: "art",
            album: "alb",
            genre: "gen",
            totalTime: 100,
            position: 50,
            shuffle: .songs,
            repeatState: .all,
            seriesName: "ser",
            seasonNumber: 3,
            episodeNumber: 7,
            contentIdentifier: "cid"
        )

        XCTAssertEqual(p.mediaType, .video)
        XCTAssertEqual(p.deviceState, .playing)
        XCTAssertEqual(p.title, "test")
        XCTAssertEqual(p.artist, "art")
        XCTAssertEqual(p.album, "alb")
        XCTAssertEqual(p.genre, "gen")
        XCTAssertEqual(p.totalTime, 100)
        XCTAssertEqual(p.position, 50)
        XCTAssertEqual(p.shuffle, .songs)
        XCTAssertEqual(p.repeatState, .all)
        XCTAssertEqual(p.seriesName, "ser")
        XCTAssertEqual(p.seasonNumber, 3)
        XCTAssertEqual(p.episodeNumber, 7)
        XCTAssertEqual(p.contentIdentifier, "cid")
    }

    func testPlayingHashable() {
        let p1 = Playing(title: "test", artist: "art")
        let p2 = Playing(title: "test", artist: "art")
        let p3 = Playing(title: "other")

        var set = Set<Playing>()
        set.insert(p1)
        set.insert(p2)
        XCTAssertEqual(set.count, 1)

        set.insert(p3)
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - App (test_interface.py::test_app_*)

    func testAppProperties() {
        let app = App(name: "name", identifier: "id")
        XCTAssertEqual(app.name, "name")
        XCTAssertEqual(app.identifier, "id")
    }

    func testAppDescription() {
        let app = App(name: "name", identifier: "id")
        XCTAssertTrue(app.description.contains("name"))
        XCTAssertTrue(app.description.contains("id"))
    }

    func testAppEquality() {
        XCTAssertEqual(App(name: nil, identifier: "a"), App(name: nil, identifier: "a"))
        XCTAssertNotEqual(App(name: "test", identifier: "a"), App(name: nil, identifier: "a"))
        XCTAssertEqual(App(name: "test", identifier: "a"), App(name: "test", identifier: "a"))
        XCTAssertNotEqual(App(name: nil, identifier: "a"), App(name: nil, identifier: "b"))
        XCTAssertEqual(App(name: "test", identifier: "test2"), App(name: "test", identifier: "test2"))
    }

    // MARK: - Features (test_interface.py::test_features_*)

    func testAllUnsupportedFeatures() {
        let features = CompanionFeatures(isConnected: false)
        let allFeats = features.allFeatures()
        // Only non-unsupported features should be returned
        for (_, info) in allFeats {
            XCTAssertNotEqual(info.state, .unsupported)
        }
    }

    func testAllIncludeUnsupportedFeatures() {
        let features = CompanionFeatures(isConnected: true)
        let allFeats = features.allFeatures(includeUnsupported: true)

        // Should include ALL features
        XCTAssertEqual(allFeats.count, FeatureName.allCases.count)
    }

    func testFeaturesInState() {
        let features = CompanionFeatures(isConnected: true)

        // Play is unsupported via companion? Actually it IS supported (playPause)
        // Test with a known unsupported feature
        XCTAssertFalse(features.inState([.unknown], features: .title))
        XCTAssertTrue(features.inState([.unsupported], features: .title))

        // Test with supported features
        XCTAssertTrue(features.inState([.available], features: .up, .down))
        XCTAssertFalse(features.inState([.available], features: .up, .title))

        // Multiple states
        XCTAssertTrue(features.inState([.unsupported, .available], features: .up, .title))
    }

    func testIsAvailable() {
        let features = CompanionFeatures(isConnected: true)
        XCTAssertTrue(features.isAvailable(.up))
        XCTAssertTrue(features.isAvailable(.home))
        XCTAssertFalse(features.isAvailable(.title))
        XCTAssertFalse(features.isAvailable(.artwork))
    }

    // MARK: - FeatureInfo

    func testFeatureInfoCreation() {
        let info = FeatureInfo(state: .available)
        XCTAssertEqual(info.state, .available)
        XCTAssertTrue(info.options.isEmpty)

        let info2 = FeatureInfo(state: .unavailable, options: ["key": "val"])
        XCTAssertEqual(info2.state, .unavailable)
        XCTAssertEqual(info2.options["key"], "val")
    }

    // MARK: - ArtworkInfo

    func testArtworkInfoProperties() {
        let art = ArtworkInfo(
            data: Data([0xFF, 0xD8]),
            mimetype: "image/jpeg",
            width: 640,
            height: 480
        )
        XCTAssertEqual(art.data, Data([0xFF, 0xD8]))
        XCTAssertEqual(art.mimetype, "image/jpeg")
        XCTAssertEqual(art.width, 640)
        XCTAssertEqual(art.height, 480)
    }

    // MARK: - OutputDevice

    func testOutputDeviceProperties() {
        let dev = OutputDevice(identifier: "id", name: "Speaker", volume: 0.75)
        XCTAssertEqual(dev.identifier, "id")
        XCTAssertEqual(dev.name, "Speaker")
        XCTAssertEqual(dev.volume, 0.75)
    }

    func testOutputDeviceEquality() {
        let d1 = OutputDevice(identifier: "a", name: "A", volume: 0.5)
        let d2 = OutputDevice(identifier: "a", name: "A", volume: 0.5)
        let d3 = OutputDevice(identifier: "b", name: "B", volume: 0.5)
        XCTAssertEqual(d1, d2)
        XCTAssertNotEqual(d1, d3)
    }

    // MARK: - UserAccount

    func testUserAccountProperties() {
        let acc = UserAccount(name: "John", identifier: "user123")
        XCTAssertEqual(acc.name, "John")
        XCTAssertEqual(acc.identifier, "user123")
    }
}
