import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MixMedia
import MixEngine

/// Testbild: einfarbig, w×h, als JPEG oder PNG
private func picture(_ w: Int, _ h: Int, red: CGFloat, type: UTType = .jpeg) -> Data {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: red, green: 0.2, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let out = NSMutableData()
    let dst = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dst)
    return out as Data
}

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("minos-art-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// m4a mit eingebettetem Cover (covr) aus einer WAV-Testdatei
private func m4aWithCover(_ jpeg: Data, in dir: URL) async throws -> URL {
    let wav = try writeWAV(rate: 44100, channels: 2, seconds: 1)
    defer { try? FileManager.default.removeItem(at: wav) }
    let out = dir.appendingPathComponent("track.m4a")
    let item = AVMutableMetadataItem()
    item.identifier = .iTunesMetadataCoverArt
    item.dataType = kCMMetadataBaseDataType_JPEG as String
    item.value = jpeg as NSData
    let export = try #require(AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A))
    export.metadata = [item]
    try await export.export(to: out, as: .m4a)
    return out
}

@Test func embeddedCoverFromM4A() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = try await m4aWithCover(picture(500, 400, red: 0.9), in: dir)
    let data = try #require(await ArtworkCache.embedded(url: url))
    #expect(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?.width == 500)

    let cache = ArtworkCache(directory: dir.appendingPathComponent("cache"))
    let img = try #require(await cache.image(url.path, .small))
    #expect(img.width == 64 && img.height == 64)   // quadratisch beschnitten
    let large = try #require(await cache.image(url.path, .large))
    #expect(large.width == 320 && large.height == 320)
    #expect(cache.cached(url.path, .small) != nil)   // Speicher-Cache
    #expect(await cache.find(url.path)?.1 == .embedded)
}

@Test func folderCoverFallbackAndDiskCache() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let wav = try writeWAV(rate: 44100, channels: 2, seconds: 0.5)
    let track = dir.appendingPathComponent("song.wav")
    try FileManager.default.moveItem(at: wav, to: track)
    let cover = dir.appendingPathComponent("Folder.PNG")
    try picture(600, 600, red: 0.5, type: .png).write(to: cover)
    #expect(ArtworkCache.folderCover(in: dir.path) == cover.path)
    #expect(await ArtworkCache.embedded(url: track) == nil)

    let cacheDir = dir.appendingPathComponent("cache")
    let cache = ArtworkCache(directory: cacheDir)
    #expect(await cache.find(track.path)?.1 == .folder)
    #expect(await cache.image(track.path, .small)?.width == 64)
    let files = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).filter { $0.hasSuffix(".jpg") }
    #expect(files.count == 1)   // nur die verlangte Größe auf der Platte
    #expect(await cache.image(track.path, .large)?.width == 320)

    // Cache-Treffer: Quelle weg, Speicher leer -> kommt von der Platte
    try FileManager.default.removeItem(at: cover)
    let fresh = ArtworkCache(directory: cacheDir)
    #expect(fresh.cached(track.path, .large) == nil)
    #expect(await fresh.image(track.path, .large)?.width == 320)
}

@Test func noCoverIsRemembered() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let wav = try writeWAV(rate: 44100, channels: 1, seconds: 0.2)
    let track = dir.appendingPathComponent("plain.wav")
    try FileManager.default.moveItem(at: wav, to: track)
    let cacheDir = dir.appendingPathComponent("cache")
    let cache = ArtworkCache(directory: cacheDir)
    #expect(await cache.image(track.path, .small) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).contains { $0.hasSuffix(".none") })
    #expect(await cache.image(dir.appendingPathComponent("missing.mp3").path, .small) == nil)
}

/// FLAC: PICTURE-Block hinter STREAMINFO, Vorderseite (Typ 3) vor anderen Bildern
@Test func flacPictureBlock() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    func block(_ type: UInt8, last: Bool, _ body: [UInt8]) -> [UInt8] {
        [type | (last ? 0x80 : 0)] + be32(body.count).suffix(3) + body
    }
    func pic(_ kind: Int, _ img: Data) -> [UInt8] {
        let mime = Array("image/jpeg".utf8)
        return be32(kind) + be32(mime.count) + mime + be32(0) + be32(10) + be32(10) + be32(24) + be32(0) + be32(img.count) + [UInt8](img)
    }
    let back = picture(10, 10, red: 0.1), front = picture(12, 12, red: 0.8)
    let bytes = Array("fLaC".utf8) + block(0, last: false, [UInt8](repeating: 0, count: 34))
        + block(6, last: false, pic(4, back)) + block(6, last: true, pic(3, front))
    let url = dir.appendingPathComponent("t.flac")
    try Data(bytes).write(to: url)
    #expect(ArtworkCache.flacPicture(url: url) == front)
}
