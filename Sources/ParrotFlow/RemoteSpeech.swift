import Foundation

/// Text to audio through an OpenAI-style `/audio/speech` endpoint, such as
/// OpenRouter's. Returns samples at `sampleRate`, ready for `Speaker`.
enum RemoteSpeech {

    /// OpenRouter's Gemini TTS pages give 24 kHz, 16-bit, mono for `pcm`.
    static let sampleRate = 24_000

    /// `tone` goes out as `instructions`. A model that refuses it with a 400
    /// is asked once more without it.
    static func synthesize(
        _ text: String, voice: String, tone: String?, speed: Float, config: ModelSpec
    ) async throws -> [Float] {
        do {
            return try await request(text, voice: voice, tone: tone, speed: speed, config: config)
        } catch LLM.Failure.badStatus(_, 400, let detail) where tone != nil {
            Log.write("claude voice: \(config.name) refused the tone, saying it plain — \(detail)")
            return try await request(text, voice: voice, tone: nil, speed: speed, config: config)
        }
    }

    private static func request(
        _ text: String, voice: String, tone: String?, speed: Float, config: ModelSpec
    ) async throws -> [Float] {
        guard let key = config.key.resolve() else { throw LLM.Failure.noKey(config) }
        guard let url = URL(string: "\(config.url)/audio/speech") else { throw LLM.Failure.unreachable(config) }
        var body: [String: Any] = [
            "model": config.model,
            "input": text,
            "voice": voice,
            "response_format": "pcm",
        ]
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLM.Failure.unreachable(config)
        }
        guard let http = response as? HTTPURLResponse else { throw LLM.Failure.unreachable(config) }
        guard http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            throw LLM.Failure.badStatus(config, http.statusCode, detail)
        }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard !type.contains("json"), !type.contains("mpeg") else {
            throw LLM.Failure.badStatus(config, http.statusCode, "expected pcm audio, got \(type)")
        }
        return samples(fromPCM16: data)
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
