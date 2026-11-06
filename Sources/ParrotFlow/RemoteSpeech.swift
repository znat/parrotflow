import Foundation

/// Text to audio through an OpenAI-style `/audio/speech` endpoint, such as
/// OpenRouter's. The body is read as it arrives and handed on in pieces, so
/// a provider that streams starts the voice before the sentence is done.
enum RemoteSpeech {

    /// OpenRouter's Gemini TTS pages give 24 kHz, 16-bit, mono for `pcm`.
    static let sampleRate = 24_000
    /// About 160 ms of 16-bit audio.
    static let pieceBytes = 7_680

    struct Timing {
        var firstAudio: TimeInterval
        var total: TimeInterval
        var contentType: String
        var rate: Int
    }

    /// The PCM rate: from `Content-Type` (`audio/pcm;rate=44100`) when the
    /// provider says it, else per provider. Fish Audio played as 24 kHz came
    /// out slow and low.
    static func rate(contentType: String, model: String) -> Int {
        // Only a plausible rate: a server saying rate=1 would make the resampler
        // ask for 24,000 samples per sample it sent.
        if let range = contentType.range(of: #"(^|;)\s*rate=\d{4,6}\b"#, options: .regularExpression),
           let value = Int(contentType[range].split(separator: "=").last ?? ""),
           (8_000...192_000).contains(value) {
            return value
        }
        return model.hasPrefix("fish-audio/") ? 44_100 : sampleRate
    }

    /// Linear interpolation to the player's 24 kHz.
    static func resample(_ samples: [Float], from rate: Int) -> [Float] {
        guard rate != sampleRate, (8_000...192_000).contains(rate), !samples.isEmpty else { return samples }
        let step = Double(rate) / Double(sampleRate)
        let count = Int(Double(samples.count) / step)
        return (0..<count).map { index in
            let position = Double(index) * step
            let low = Int(position)
            let high = min(low + 1, samples.count - 1)
            let weight = Float(position - Double(low))
            return samples[low] * (1 - weight) + samples[high] * weight
        }
    }

    /// `tone` goes out as `instructions`. A model that refuses it with a 400
    /// is asked once more without it. `emit` says false once the line is
    /// dropped. Throws only before any audio was handed on.
    static func stream(
        _ text: String, voice: String, tone: String?, speed: Float, config: ModelSpec,
        emit: @escaping @MainActor ([Float]) -> Bool
    ) async throws -> Timing {
        do {
            return try await request(text, voice: voice, tone: tone, speed: speed, config: config, emit: emit)
        } catch LLM.Failure.badStatus(_, 400, let detail) where tone != nil {
            Log.write("claude voice: \(config.name) refused the tone, saying it plain — \(detail)")
            return try await request(text, voice: voice, tone: nil, speed: speed, config: config, emit: emit)
        }
    }

    private static func request(
        _ text: String, voice: String, tone: String?, speed: Float, config: ModelSpec,
        emit: @escaping @MainActor ([Float]) -> Bool
    ) async throws -> Timing {
        guard let key = config.key.resolve() else { throw LLM.Failure.noKey(config) }
        guard let url = URL(string: "\(config.url)/audio/speech") else { throw LLM.Failure.unreachable(config) }
        var body: [String: Any] = [
            "model": config.model,
            "input": text,
            "response_format": "pcm",
        ]
        // Empty: the provider's default voice. Fish Audio lists none.
        if !voice.isEmpty { body["voice"] = voice }
        // Some providers return 400 for any speed but 1.
        if speed != 1 { body["speed"] = speed }
        if let tone, !tone.isEmpty { body["instructions"] = tone }
        LLM.merge(config.params, into: &body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = config.timeout

        let started = Date()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw LLM.Failure.unreachable(config)
        }
        guard let http = response as? HTTPURLResponse else { throw LLM.Failure.unreachable(config) }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            throw LLM.Failure.badStatus(config, http.statusCode, detail)
        }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard !type.contains("json"), !type.contains("mpeg") else {
            throw LLM.Failure.badStatus(config, http.statusCode, "expected pcm audio, got \(type)")
        }

        let pcmRate = rate(contentType: type, model: config.model)
        var buffer = Data()
        var header: Bool?
        var first: TimeInterval?
        for try await byte in bytes {
            buffer.append(byte)
            // Gemini 3.8 answers a plain request with a WAV header; skip it if it comes.
            if header == nil, buffer.count >= 4 {
                header = buffer.prefix(4) == Data("RIFF".utf8)
            }
            if header == true {
                guard let start = dataStart(buffer) else { continue }
                buffer.removeSubrange(..<start)
                header = false
            }
            guard header == false, buffer.count >= pieceBytes else { continue }
            let piece = buffer.prefix(pieceBytes - pieceBytes % 2)
            buffer.removeSubrange(..<piece.count)
            if first == nil { first = Date().timeIntervalSince(started) }
            guard await emit(resample(samples(fromPCM16: Data(piece)), from: pcmRate)) else { break }
        }
        if buffer.count >= 2 {
            if first == nil { first = Date().timeIntervalSince(started) }
            _ = await emit(resample(samples(fromPCM16: buffer.prefix(buffer.count - buffer.count % 2)), from: pcmRate))
        }
        return Timing(firstAudio: first ?? Date().timeIntervalSince(started), total: Date().timeIntervalSince(started),
                      contentType: type, rate: pcmRate)
    }

    /// Where the samples start in a WAV: after the `data` chunk's 8-byte header.
    private static func dataStart(_ wav: Data) -> Int? {
        guard let range = wav.range(of: Data("data".utf8)), wav.count >= range.upperBound + 4 else { return nil }
        return range.upperBound + 4
    }

    /// Signed 16-bit little-endian, as `pcm` is everywhere it is documented.
    static func samples(fromPCM16 data: Data) -> [Float] {
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                out[index] = Float(value) / 32_768
            }
        }
        return out
    }
}
