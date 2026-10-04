import Foundation

@main struct LyricsTests {
    static func main() async throws {
        let lines = LyricsTimeline.parse("[offset:500]\n[00:01.5][00:03.125]你好\n[00:05.00]\n[00:07]再见")
        precondition(lines.count == 4)
        precondition(abs(lines[0].time - 2) < 0.001)
        precondition(abs(lines[1].time - 3.625) < 0.001)
        precondition(LyricsTimeline.line(at: 0, in: lines) == "")
        precondition(LyricsTimeline.line(at: 2.1, in: lines) == "你好")
        precondition(LyricsTimeline.line(at: 6, in: lines) == "")
        precondition(LyricsSource.forPlayer("com.tencent.QQMusicMac") == .qq)
        precondition(LyricsSource.forPlayer("com.netease.163music") == .netease)
        let song = LyricsSong(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269)
        let wrong = LyricsCandidate(id: "live", title: "晴天 (Live)", artists: ["周杰伦"], album: "", duration: 249)
        let right = LyricsCandidate(id: "original", title: "晴天", artists: ["周杰伦"], album: "叶惠美", duration: 269)
        let cover = LyricsCandidate(id: "cover", title: "晴天", artists: ["其他歌手"], album: "", duration: 269)
        precondition(LyricsMatching.best([wrong, cover, right], for: song)?.id == "original")
        precondition(LyricsMatching.best([wrong, cover], for: song) == nil)
        precondition(LyricsText.decode("&#91;00:01&#93;A &amp; B &#x4F60;") == "[00:01]A & B 你")
        precondition(LyricsText.decode(Data("[00:01]你好".utf8).base64EncodedString()) == "[00:01]你好")
        let renamed = LyricsCandidate(id: "alias", title: "起风了", artists: ["冯沁苑(买辣椒也用券)"], album: "起风了", duration: 325.868)
        precondition(LyricsMatching.best([renamed], for: LyricsSong(title: "起风了", artist: "买辣椒也用券", album: "起风了", duration: 325.868))?.id == "alias", "Singer aliases should match")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsFixtureProtocol.self]
        let service = LyricsService(session: URLSession(configuration: config))
        for (player, source) in [("com.tencent.QQMusicMac", LyricsSource.qq), ("com.netease.163music", .netease)] {
            let result = try await service.lookup(song: song, player: player)
            precondition(result?.source == source)
            precondition(LyricsTimeline.parse(result?.text ?? "").first?.text == "测试歌词")
        }
        let requestsBeforeCache = LyricsFixtureProtocol.requestCount
        _ = try await service.lookup(song: song, player: "com.tencent.QQMusicMac")
        precondition(LyricsFixtureProtocol.requestCount == requestsBeforeCache)
        for failure in ["http", "json", "empty", "code"] {
            LyricsFixtureProtocol.platformFailure = failure
            let recovered = try await LyricsService(session: URLSession(configuration: config)).lookup(song: song, player: "com.tencent.QQMusicMac")
            precondition(recovered?.source == .lrclib)
        }
        LyricsFixtureProtocol.platformFailure = ""
        LyricsFixtureProtocol.failPlatforms = true
        let fallback = try await LyricsService(session: URLSession(configuration: config)).lookup(song: song, player: "com.tencent.QQMusicMac")
        precondition(fallback?.source == .lrclib)
        let canceled = Task { () throws -> LyricsResult? in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return try await service.lookup(song: song, player: "com.tencent.QQMusicMac")
        }
        canceled.cancel()
        do { _ = try await canceled.value; preconditionFailure("Canceled lookup must not return lyrics") }
        catch is CancellationError {} catch { preconditionFailure("Unexpected cancellation error") }
        if CommandLine.arguments.contains("--live") {
            let live = LyricsService()
            let qq = try await live.lookup(song: song, player: "com.tencent.QQMusicMac")
            precondition(qq?.source == .qq && !LyricsTimeline.parse(qq?.text ?? "").isEmpty)
            print("LIVE PASS: QQ source, timed lyrics")
            let netSong = LyricsSong(title: "起风了", artist: "冯沁苑(买辣椒也用券)", album: "起风了", duration: 325.868)
            let net = try await live.lookup(song: netSong, player: "com.netease.163music")
            precondition(net?.source == .netease && !LyricsTimeline.parse(net?.text ?? "").isEmpty)
            print("LIVE PASS: NetEase source, timed lyrics")
        }
        print("PASS: platform requests, fallback, cancellation;  LRC timestamps, repeated tags, offset, blank intervals, player routing, version matching, lyric decoding")
    }
}

final class LyricsFixtureProtocol: URLProtocol {
    static var failPlatforms = false
    static var platformFailure = ""
    static var requestCount = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        let url = request.url!
        let path = url.path
        let lrc = "[00:01.5]测试歌词\n[00:05.0]"
        var body: Any = [:]
        if url.host == "lrclib.net" {
            body = [["trackName": "晴天", "artistName": "周杰伦", "albumName": "叶惠美", "duration": 269, "syncedLyrics": lrc]]
        } else if Self.failPlatforms {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        } else if path.contains("client_search") {
            body = ["code": 0, "data": ["song": ["list": [["songmid": "qq-id", "songname": "晴天", "singer": [["name": "周杰伦"]], "albumname": "叶惠美", "interval": 269]]]]]
        } else if path.contains("fcg_query_lyric") {
            precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "songmid" }?.value == "qq-id")
            body = ["retcode": 0, "lyric": Data(lrc.utf8).base64EncodedString()]
        } else if path.contains("search") {
            body = ["code": 200, "result": ["songs": [["id": 123, "name": "晴天", "artists": [["name": "周杰伦"]], "album": ["name": "叶惠美"], "duration": 269000]]]]
        } else {
            precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value == "123")
            body = ["code": 200, "lrc": ["lyric": lrc]]
        }
        let failed = url.host != "lrclib.net" ? Self.platformFailure : ""
        if failed == "empty" { body = ["code": 0, "data": ["song": ["list": []]]] }
        if failed == "code" { body = ["code": 403] }
        let data = failed == "json" ? Data("not json".utf8) : try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: failed == "http" ? 503 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
