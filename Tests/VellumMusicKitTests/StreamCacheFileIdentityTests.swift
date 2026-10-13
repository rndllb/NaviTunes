import AVFoundation
import Foundation
import Testing

@testable import VellumMusicKit

/// T665. On the device every song that `AutoMixStreamPrefetcher` had fetched failed to start with
/// `candidate failed [load] loader=false url=file:///…/stream-cache/<sha256> error=
/// AVFoundationErrorDomain -11828 ← NSOSStatusErrorDomain -12847 (Cannot Open)`, the plain stream
/// then played instead, and the perfectly good file was evicted and fetched again. The file is
/// complete and valid — `AVAudioFile` reads it — but it has no extension, and AVFoundation
/// identifies a file URL by its extension. The asset now gets the container, read from the first
/// bytes, as its out-of-band MIME type.
@Suite("Stream-cache file identity")
struct StreamCacheFileIdentityTests {
    /// One second of a 440 Hz sine as FLAC, written by AVFoundation itself.
    static func writeFLAC(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for i in 0 ..< 44_100 { buffer.floatChannelData![0][i] = sinf(Float(i) * 2 * .pi * 440 / 44_100) * 0.5 }
        try file.write(from: buffer)
    }

    /// The FLAC copied under a hash-shaped, extensionless name in a `stream-cache` folder, the way
    /// `StreamingMediaDiskCache.commit` leaves it.
    static func extensionlessFLAC() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("t665-\(UUID().uuidString)/VellumMusic/stream-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let flac = dir.appendingPathComponent("tone.flac")
        try writeFLAC(to: flac)
        let bare = dir.appendingPathComponent("c0c2d9ef1aab3fb6ae6e727675db4f7c2e3bd3dc4c31916c9000d475535ccde3")
        try FileManager.default.copyItem(at: flac, to: bare)
        return bare
    }

    @Test("the container is read from the first bytes")
    func sniff() {
        func head(_ bytes: [UInt8]) -> String? { StreamingMediaDiskCache.sniffedMIMEType(head: Data(bytes)) }
        #expect(head(Array("fLaC\0\0\0\"".utf8)) == "audio/flac")
        #expect(head(Array("OggS\0\u{2}".utf8)) == "audio/ogg")
        #expect(head(Array("ID3\u{4}\0\0".utf8)) == "audio/mpeg")
        #expect(head([0xFF, 0xFB, 0x90, 0x64]) == "audio/mpeg")
        #expect(head([0xFF, 0xF1, 0x50, 0x80]) == "audio/aac")
        #expect(head(Array("RIFF\u{24}\u{8}\0\0WAVEfmt ".utf8)) == "audio/wav")
        #expect(head(Array("FORM\0\0\0\0AIFF".utf8)) == "audio/aiff")
        #expect(head([0, 0, 0, 0x20] + Array("ftypM4A ".utf8)) == "audio/mp4")
        #expect(head(Array("<html><body>".utf8)) == nil)
        #expect(head([0x66, 0x4C]) == nil)
        #expect(head([]) == nil)
    }

    // On the main actor: an AVPlayerItem's status only advances with the main run loop, and off
    // it the item sat at `.unknown` for the whole wait (the `.flac` control takes ~0.8 s there).
    @MainActor
    @Test("an extensionless FLAC: the bare asset fails exactly as on the device; with the hint it opens and the item is ready")
    func extensionlessFLACOpens() async throws {
        let bare = try Self.extensionlessFLAC()
        #expect(StreamingMediaDiskCache.sniffedMIMEType(ofFileAt: bare) == "audio/flac")

        // What `makePlaybackAsset` built before T665: the device's -11828.
        let bareAsset = AVURLAsset(url: bare, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var bareError: NSError?
        do { _ = try await bareAsset.load(.tracks) } catch { bareError = error as NSError }
        #expect(bareError?.domain == AVFoundationErrorDomain, Comment(rawValue: String(describing: bareError)))
        #expect(bareError?.code == -11828, Comment(rawValue: String(describing: bareError)))

        // What it builds now.
        let options = PlaybackEngine.localAssetOptions(for: bare)
        #expect(options[CachingResourceLoaderDelegate.outOfBandMIMETypeOptionKey] as? String == "audio/flac")
        let asset = AVURLAsset(url: bare, options: options)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.load(.tracks)
        #expect(playable)
        #expect(tracks.count == 1)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        for _ in 0 ..< 200 where item.status == .unknown { try await Task.sleep(for: .milliseconds(25)) }
        #expect(item.status == .readyToPlay, Comment(rawValue: String(describing: item.error)))
        player.pause()
    }

    @Test("a file with an extension gets no hint; a file that cannot be read gets none either")
    func hintOnlyWhenNeeded() throws {
        let bare = try Self.extensionlessFLAC()
        let withExtension = bare.deletingLastPathComponent().appendingPathComponent("tone.flac")
        #expect(PlaybackEngine.localAssetOptions(for: withExtension)[CachingResourceLoaderDelegate.outOfBandMIMETypeOptionKey] == nil)
        let missing = bare.deletingLastPathComponent().appendingPathComponent("0000000000000000")
        #expect(PlaybackEngine.localAssetOptions(for: missing)[CachingResourceLoaderDelegate.outOfBandMIMETypeOptionKey] == nil)
        #expect(PlaybackEngine.localAssetOptions(for: missing)[AVURLAssetPreferPreciseDurationAndTimingKey] as? Bool == true)
    }

    @Test("the AutoMix decks read the same extensionless file as-is")
    func deckReadsIt() throws {
        let bare = try Self.extensionlessFLAC()
        let file = try AVAudioFile(forReading: bare)
        #expect(file.length == 44_100)
    }
}
