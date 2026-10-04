import Foundation

enum LyricsSource: String, Sendable {
    case qq, netease, lrclib

    static func forPlayer(_ bundle: String?) -> LyricsSource {
        switch bundle?.lowercased() {
        case "com.tencent.qqmusicmac": return .qq
        case "com.netease.163music": return .netease
        default: return .lrclib
        }
    }
}

struct LyricsSong: Hashable, Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
}

struct LyricsCandidate: Sendable {
    let id: String
    let title: String
    let artists: [String]
    let album: String
    let duration: Double
}

enum LyricsMatching {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func artistNames(_ text: String) -> Set<String> {
        // Platforms may publish a renamed singer as “new name(old name)”.
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "()（）"))
        return Set(([text] + parts).map(normalized).filter { !$0.isEmpty })
    }

    static func best(_ candidates: [LyricsCandidate], for song: LyricsSong) -> LyricsCandidate? {
        let artists = song.artist.components(separatedBy: CharacterSet(charactersIn: "/、,&;；＆")).map(normalized).filter { !$0.isEmpty }
        return candidates.compactMap { candidate -> (LyricsCandidate, Double)? in
            guard !candidate.id.isEmpty, normalized(candidate.title) == normalized(song.title),
                  !artists.isEmpty,
                  artists.allSatisfy({ name in candidate.artists.contains { artistNames($0).contains(name) } }) else { return nil }
            let delta = abs(candidate.duration - song.duration)
            if song.duration > 0 && candidate.duration > 0 && delta > 3 { return nil }
            let albumBonus = !song.album.isEmpty && normalized(song.album) == normalized(candidate.album) ? 10.0 : 0
            return (candidate, albumBonus - (song.duration > 0 && candidate.duration > 0 ? delta : 5))
        }.max { $0.1 < $1.1 }?.0
    }

    /// QQ's ranked results can contain the original recording before a cover.
    /// Keep only candidates that agree with the player metadata, then rank by
    /// title, album and runtime. QQ may append a version label or an alias to
    /// the title, so allow one normalized title to contain the other.
    static func bestPlayerMatch(_ candidates: [LyricsCandidate], for song: LyricsSong) -> LyricsCandidate? {
        let title = normalized(song.title)
        let artists = song.artist.components(separatedBy: CharacterSet(charactersIn: "/、,&;；＆"))
            .map(normalized).filter { !$0.isEmpty }
        guard !title.isEmpty, !artists.isEmpty else { return nil }

        return candidates.enumerated().compactMap { index, candidate -> (LyricsCandidate, Double)? in
            guard !candidate.id.isEmpty else { return nil }
            let candidateTitle = normalized(candidate.title)
            let names = candidate.artists.flatMap { artistNames($0) }
            guard artists.allSatisfy({ names.contains($0) }) else { return nil }

            let exactTitle = candidateTitle == title
            let versionTitle = !candidateTitle.isEmpty && (candidateTitle.contains(title) || title.contains(candidateTitle))
            let albumMatch = !song.album.isEmpty && normalized(song.album) == normalized(candidate.album)
            let hasDurations = song.duration > 0 && candidate.duration > 0
            let durationDelta = hasDurations ? abs(candidate.duration - song.duration) : 0
            let durationLimit = max(12, song.duration * 0.08)
            guard !hasDurations || durationDelta <= durationLimit else { return nil }
            // An unrelated title is acceptable only when both album and runtime
            // strongly identify it; this covers localized title aliases safely.
            guard exactTitle || versionTitle || (albumMatch && hasDurations && durationDelta <= 3) else { return nil }

            let titleScore = exactTitle ? 100.0 : (versionTitle ? 65.0 : 35.0)
            let albumScore = albumMatch ? 25.0 : 0
            let durationScore = hasDurations ? -durationDelta * 2 : 0
            return (candidate, titleScore + albumScore + durationScore - Double(index) * 0.001)
        }.max { $0.1 < $1.1 }?.0
    }
}

enum LyricsTimeline {
    static func parse(_ lrc: String) -> [(time: Double, text: String)] {
        guard let tags = try? NSRegularExpression(pattern: #"\[(\d+):([0-5]\d)(?:\.(\d{1,3}))?\]"#),
              let offsetTag = try? NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive) else { return [] }
        let entire = lrc as NSString
        let offset = offsetTag.firstMatch(in: lrc, range: NSRange(location: 0, length: entire.length)).flatMap {
            Double(entire.substring(with: $0.range(at: 1)))
        }.map { $0 / 1000 } ?? 0
        var result: [(time: Double, text: String)] = []
        for line in lrc.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = tags.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                let fraction = match.range(at: 3).location == NSNotFound ? 0 : Double("0." + ns.substring(with: match.range(at: 3))) ?? 0
                result.append((max(0, minutes * 60 + seconds + fraction + offset), text))
            }
        }
        return result.enumerated().sorted { a, b in
            a.element.time == b.element.time ? a.offset < b.offset : a.element.time < b.element.time
        }.map(\.element)
    }

    static func line(at elapsed: Double, in lines: [(time: Double, text: String)]) -> String {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= elapsed { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? "" : lines[low - 1].text
    }
}

enum LyricsText {
    static func decode(_ value: String) -> String {
        var text = value
        if !text.contains("["), !text.contains("\n"), let data = Data(base64Encoded: text),
           let decoded = String(data: data, encoding: .utf8), decoded.contains("[") || decoded.contains("\n") {
            text = decoded
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#) {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                let raw = ns.substring(with: match.range(at: 1))
                let number = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
                if let number, let scalar = UnicodeScalar(number), let range = Range(match.range, in: text) {
                    text.replaceSubrange(range, with: String(scalar))
                }
            }
        }
        for (entity, replacement) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LyricsResult: Sendable {
    let text: String
    let source: LyricsSource
}

actor LyricsService {
    private let session: URLSession
    private struct Key: Hashable { let song: LyricsSong; let source: LyricsSource }
    private var cache: [Key: LyricsResult] = [:]

    init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 12
            self.session = URLSession(configuration: config)
        }
    }

    func lookup(song: LyricsSong, player: String?) async throws -> LyricsResult? {
        let source = LyricsSource.forPlayer(player)
        let key = Key(song: song, source: source)
        try Task.checkCancellation()
        if let cached = cache[key] { return cached }
        var result: LyricsResult?
        if source != .lrclib {
            do { result = try await platform(song: song, source: source) }
            catch { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        if result == nil { result = try await generic(song: song) }
        try Task.checkCancellation()
        if let result {
            if cache.count >= 128 { cache.removeAll() }
            cache[key] = result
        }
        return result
    }

    private func json(_ endpoint: String, params: [String: String], source: LyricsSource) async throws -> Any {
        try Task.checkCancellation()
        var url = URLComponents(string: endpoint)!
        url.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 8
        request.setValue("Mozilla/5.0 BoringNotch", forHTTPHeaderField: "User-Agent")
        if source != .lrclib {
            request.setValue(source == .qq ? "https://y.qq.com/" : "https://music.163.com/", forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func platform(song: LyricsSong, source: LyricsSource) async throws -> LyricsResult? {
        let query = song.title + " " + song.artist
        var candidates: [LyricsCandidate] = []
        if source == .qq {
            let root = try await json("https://c.y.qq.com/soso/fcgi-bin/client_search_cp", params: ["w": query, "format": "json", "n": "20", "p": "1"], source: source) as? [String: Any]
            guard root?["code"] as? Int == 0 else { throw URLError(.badServerResponse) }
            let data = root?["data"] as? [String: Any]
            let songs = data?["song"] as? [String: Any]
            candidates = (songs?["list"] as? [[String: Any]] ?? []).map {
                LyricsCandidate(id: $0["songmid"] as? String ?? "", title: $0["songname"] as? String ?? "", artists: ($0["singer"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }, album: $0["albumname"] as? String ?? "", duration: ($0["interval"] as? NSNumber)?.doubleValue ?? 0)
            }
        } else {
            let root = try await json("https://music.163.com/api/search/get/web", params: ["s": query, "type": "1", "limit": "20", "offset": "0"], source: source) as? [String: Any]
            guard root?["code"] as? Int == 200 else { throw URLError(.badServerResponse) }
            let result = root?["result"] as? [String: Any]
            candidates = (result?["songs"] as? [[String: Any]] ?? []).map {
                let album = $0["album"] as? [String: Any]
                return LyricsCandidate(id: ($0["id"] as? NSNumber)?.stringValue ?? "", title: $0["name"] as? String ?? "", artists: ($0["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }, album: album?["name"] as? String ?? "", duration: (($0["duration"] as? NSNumber)?.doubleValue ?? 0) / 1000)
            }
        }
        let selected = source == .qq
            ? LyricsMatching.bestPlayerMatch(candidates, for: song)
            : LyricsMatching.best(candidates, for: song)
        guard let selected else { return nil }
        let text: String
        if source == .qq {
            let root = try await json("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", params: ["songmid": selected.id, "format": "json", "nobase64": "1", "g_tk": "5381"], source: source) as? [String: Any]
            guard root?["retcode"] as? Int == 0 else { throw URLError(.badServerResponse) }
            text = LyricsText.decode(root?["lyric"] as? String ?? "")
        } else {
            let root = try await json("https://music.163.com/api/song/lyric", params: ["id": selected.id, "lv": "-1", "kv": "-1", "tv": "-1"], source: source) as? [String: Any]
            guard root?["code"] as? Int == 200 else { throw URLError(.badServerResponse) }
            let lrc = root?["lrc"] as? [String: Any]
            text = LyricsText.decode(lrc?["lyric"] as? String ?? "")
        }
        return text.isEmpty ? nil : LyricsResult(text: text, source: source)
    }

    private func generic(song: LyricsSong) async throws -> LyricsResult? {
        let rows = try await json("https://lrclib.net/api/search", params: ["track_name": song.title, "artist_name": song.artist], source: .lrclib) as? [[String: Any]] ?? []
        let candidates = rows.enumerated().map { index, row in
            LyricsCandidate(id: String(index), title: row["trackName"] as? String ?? "", artists: (row["artistName"] as? String ?? "").components(separatedBy: CharacterSet(charactersIn: "/、,&;")), album: row["albumName"] as? String ?? "", duration: (row["duration"] as? NSNumber)?.doubleValue ?? 0)
        }
        guard let match = LyricsMatching.best(candidates, for: song), let index = Int(match.id) else { return nil }
        let row = rows[index]
        let synced = (row["syncedLyrics"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = (row["plainLyrics"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = synced.isEmpty ? plain : synced
        return text.isEmpty ? nil : LyricsResult(text: text, source: .lrclib)
    }
}
