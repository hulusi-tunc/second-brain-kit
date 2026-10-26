import CWhisper
import Foundation

/// Silero voice detection, fetched by scripts/models.sh
let vadModelPath = Config.models.appendingPathComponent("ggml-silero-v5.1.2.bin").path

/// Whisper large-v3-turbo, loaded once and kept warm on the GPU. Built from vendor/whisper.cpp with
/// one patch (one encode for language and text), and the window sized to each clip.
final class Whisper {
  struct Result {
    let text: String
    let language: String
    let millis: Int
  }

  private let queue = DispatchQueue(label: "brain.whisper", qos: .userInitiated)
  private var ctx: OpaquePointer?

  /// Loads the model on the whisper queue. `done` gets false if the file is missing or broken.
  func load(model path: String, done: @escaping (Bool) -> Void) {
    queue.async {
      whisper_log_set({ _, _, _ in }, nil)
      // Homebrew's ggml ships Metal and CPU as plugins; load them before the model, as whisper-cli does
      ggml_backend_load_all()
      if ggml_backend_dev_count() == 0 { ggml_backend_load_all_from_path("/opt/homebrew/opt/ggml/libexec") }
      var cp = whisper_context_default_params()
      cp.use_gpu = true
      cp.flash_attn = ProcessInfo.processInfo.environment["BRAIN_NOFA"] == nil
      self.ctx = whisper_init_from_file_with_params(path, cp)
      DispatchQueue.main.async { done(self.ctx != nil) }
    }
  }

  private var lastRun = Date.distantPast

  func warmUp() {
    guard Date().timeIntervalSince(lastRun) > 20 else { return }
    lastRun = Date()
    queue.async {
      guard let ctx = self.ctx else { return }
      var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
      p.print_progress = false; p.print_realtime = false; p.print_timestamps = false
      p.no_timestamps = true; p.n_threads = 6; p.audio_ctx = 750; p.max_tokens = 1
      let silence = [Float](repeating: 0, count: 16_000)
      _ = "en".withCString { lang in
        p.language = lang
        return silence.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
      }
    }
  }

  func close() {
    queue.sync {
      if let s = state { whisper_free_state(s) }
      state = nil
      if let ctx { whisper_free(ctx) }
      ctx = nil
    }
  }

  struct Segment {
    let start: Double   // seconds from the start of the audio
    let end: Double
    let text: String
  }

  /// A whole recording (a call track) in, timed segments out.
  /// Voice detection only finds where people speak; the speech is cut into chunks of up to 28 s at
  /// pauses and each chunk is transcribed on its own, with a window sized to it and its own
  /// language. Feeding Whisper its own previous text loops ("So, we do a lot of work." for 30
  /// minutes), and whisper.cpp's built-in VAD mode, which stitches speech together, loses minutes.
  func transcribeLong(_ samples: [Float], prompt: String, done: @escaping ([Segment], String) -> Void) {
    queue.async {
      guard let ctx = self.ctx, !samples.isEmpty else { DispatchQueue.main.async { done([], "?") }; return }
      let rate = 16_000.0
      // 1. where is speech
      var regions: [(Double, Double)] = []
      var vcp = whisper_vad_default_context_params()
      vcp.n_threads = 4
      if let vctx = whisper_vad_init_from_file_with_params(vadModelPath, vcp) {
        var vp = whisper_vad_default_params()
        vp.min_silence_duration_ms = 300
        vp.speech_pad_ms = 200
        if let segs = samples.withUnsafeBufferPointer({ whisper_vad_segments_from_samples(vctx, vp, $0.baseAddress, Int32($0.count)) }) {
          for i in 0..<whisper_vad_segments_n_segments(segs) {
            // whisper.cpp reports these in centiseconds
            regions.append((Double(whisper_vad_segments_get_segment_t0(segs, i)) / 100, Double(whisper_vad_segments_get_segment_t1(segs, i)) / 100))
          }
          whisper_vad_free_segments(segs)
        }
        whisper_vad_free(vctx)
      } else {
        regions = [(0, Double(samples.count) / rate)]
      }
      // 2. chunks of up to 28 s, cut at pauses; one long speech is split hard at 28 s
      var chunks: [(Double, Double)] = []
      for (a, b) in regions {
        var a = a
        while b - a > 28 { chunks.append((a, a + 28)); a += 28 }
        if let last = chunks.last, b - last.0 <= 28, a - last.1 < 3 { chunks[chunks.count - 1].1 = b } else { chunks.append((a, b)) }
      }
      // 3. each chunk on its own, each its own turn on the queue, so a dictation released meanwhile
      // waits for one chunk (under a second), not for the whole recording
      let acc = Acc()
      for (a, b) in chunks { self.queue.async { self.piece(a, b, samples, prompt, acc) } }
      self.queue.async {
        let main = acc.langs.max { $0.value < $1.value }?.key ?? "?"
        let out = acc.out
        DispatchQueue.main.async { done(out, main) }
      }
    }
  }

  private final class Acc { var out: [Segment] = []; var langs: [String: Int] = [:] }

  private func piece(_ a: Double, _ b: Double, _ samples: [Float], _ prompt: String, _ acc: Acc) {
      guard let ctx = self.ctx else { return }
      let rate = 16_000.0
      do {
        let i0 = max(0, Int((a - 0.1) * rate)), i1 = min(samples.count, Int((b + 0.1) * rate))
        guard i1 - i0 > Int(0.3 * rate) else { return }
        let slice = Array(samples[i0..<i1])
        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.print_progress = false; p.print_realtime = false; p.print_timestamps = false; p.print_special = false
        p.no_timestamps = false
        p.no_context = true
        p.suppress_nst = true
        p.n_threads = 8
        p.audio_ctx = Int32(min(1500, max(750, Int(Double(slice.count) / rate * 50) + 250)))
        let status: Int32 = "auto".withCString { lang in
          prompt.withCString { hint in
            p.language = lang
            p.initial_prompt = prompt.isEmpty ? nil : hint
            return slice.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
          }
        }
        guard status == 0 else { return }
        let lang = whisper_lang_str(whisper_full_lang_id(ctx)).map { String(cString: $0) } ?? "?"
        // with your languages set, a chunk heard as anything else is noise Whisper made words of
        if ProcessInfo.processInfo.environment["BRAIN_DEBUG"] != nil { print(String(format: "  %.1f-%.1f s: %@", a, b, lang)) }
        let mine = Config.languages
        guard mine.isEmpty || mine.contains(lang) else { return }
        acc.langs[lang, default: 0] += 1
        let offset = Double(i0) / rate
        for i in 0..<whisper_full_n_segments(ctx) {
          let text = (whisper_full_get_segment_text(ctx, i).map { String(cString: $0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty, !Whisper.ghost(text), !Whisper.stuck(text) else { continue }
          if acc.out.suffix(8).contains(where: { $0.text == text }) { continue }
          acc.out.append(Segment(start: offset + Double(whisper_full_get_segment_t0(ctx, i)) / 100,
                             end: offset + Double(whisper_full_get_segment_t1(ctx, i)) / 100, text: text))
        }
      }
  }

  /// A line that repeats one short phrase three times or more ("in the world in the world in the
  /// world", "it is a good thing, it is a good thing") is Whisper stuck, not speech.
  static func stuck(_ text: String) -> Bool {
    let w = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    guard w.count >= 6 else { return false }
    for n in 1...14 where w.count >= n * 3 {
      for i in 0...(w.count - n * 3) {
        let a = w[i..<i + n], b = w[i + n..<i + 2 * n], c = w[i + 2 * n..<i + 3 * n]
        if a == b && b == c { return true }
      }
    }
    return false
  }

  /// What Whisper says to near-silence (subtitle credits it learned from video); never a line in a transcript.
  static func ghost(_ text: String) -> Bool {
    let k = text.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
    return ["thank you", "thanks for watching", "thank you for watching", "you", "bye",
            "soustitres réalisés par la communauté damaraorg", "untertitel der amaraorgcommunity",
            "subtítulos realizados por la comunidad de amaraorg", "merci", "gracias", "danke"].contains(k)
  }

  /// 16 kHz mono samples in, text out. `prompt` carries the spelling hints (the dictionary).
  /// With your languages set (Config.languages), a short take sometimes comes back as a language
  /// you never speak; it is done again in your first language.
  func transcribe(_ samples: [Float], prompt: String, done: @escaping (Result?) -> Void) {
    let mine = Config.languages
    let first = mine.count == 1 ? mine[0] : "auto"
    run(samples, prompt: prompt, language: ProcessInfo.processInfo.environment["BRAIN_LANG"] ?? first) { [weak self] r in
      guard let self, let r, !mine.isEmpty, !mine.contains(r.language), !r.text.isEmpty else { done(r); return }
      let again = mine[0]
      Log.write("whisper: heard as \(r.language), done again in \(again)")
      self.run(samples, prompt: prompt, language: again) { r2 in
        done(r2.map { Result(text: $0.text, language: $0.language, millis: $0.millis + r.millis) } ?? r)
      }
    }
  }

  static func foldRepeats(_ text: String) -> String {
    var out: [String] = []
    var last = ""
    let parts = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var sentence: [String] = []
    func flush() {
      guard !sentence.isEmpty else { return }
      let s = sentence.joined(separator: " ")
      let key = s.lowercased().trimmingCharacters(in: .punctuationCharacters)
      if key != last { out.append(s) }
      last = key
      sentence = []
    }
    for w in parts {
      sentence.append(w)
      if let c = w.last, ".!?".contains(c) { flush() }
    }
    flush()
    return out.joined(separator: " ")
  }

  private var state: OpaquePointer?
  private var stateWindow: Int32 = 0

  private func takeState(_ ctx: OpaquePointer, window: Int32) -> OpaquePointer? {
    if state == nil || window < stateWindow { freshState(ctx) }
    return state
  }

  private func freshState(_ ctx: OpaquePointer) {
    if let s = state { whisper_free_state(s) }
    state = whisper_init_state(ctx)
    stateWindow = 0
  }

  private func run(_ samples: [Float], prompt: String, language: String, done: @escaping (Result?) -> Void) {
    queue.async {
      guard let ctx = self.ctx, !samples.isEmpty else {
        DispatchQueue.main.async { done(nil) }
        return
      }
      let start = Date()
      DispatchQueue.main.async { self.lastRun = Date() }
      var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
      p.print_progress = false
      p.print_realtime = false
      p.print_timestamps = false
      p.print_special = false
      p.no_timestamps = true
      p.translate = false
      p.suppress_nst = true
      p.n_threads = 6
      if ProcessInfo.processInfo.environment["BRAIN_NOFALLBACK"] != nil { p.temperature_inc = 0 }
      if ProcessInfo.processInfo.environment["BRAIN_NOPROMPT"] != nil { p.initial_prompt = nil }
      let seconds = Double(samples.count) / 16_000
      p.audio_ctx = Int32(min(1500, max(750, Int(seconds * 50) + 250)))
      if let o = ProcessInfo.processInfo.environment["BRAIN_AC"], let v = Int32(o) { p.audio_ctx = v }
      p.max_tokens = Int32(Int(seconds * 14) + 16)
      if let o = ProcessInfo.processInfo.environment["BRAIN_MAXTOK"], let v = Int32(o) { p.max_tokens = v }

      guard let st = self.takeState(ctx, window: p.audio_ctx) else {
        DispatchQueue.main.async { done(nil) }
        return
      }
      let langCode = language
      let status: Int32 = langCode.withCString { lang in
        prompt.withCString { hint in
          p.language = lang
          p.initial_prompt = prompt.isEmpty ? nil : hint
          return samples.withUnsafeBufferPointer { buf in
            whisper_full_with_state(ctx, st, p, buf.baseAddress, Int32(buf.count))
          }
        }
      }
      self.stateWindow = max(self.stateWindow, p.audio_ctx)
      if self.stateWindow > 750 { self.queue.async { self.freshState(ctx) } }
      guard status == 0 else {
        DispatchQueue.main.async { done(nil) }
        return
      }
      var text = ""
      for i in 0..<whisper_full_n_segments_from_state(st) {
        if let c = whisper_full_get_segment_text_from_state(st, i) { text += String(cString: c) }
      }
      let lang = whisper_lang_str(whisper_full_lang_id_from_state(st)).map { String(cString: $0) } ?? "?"
      let ms = Int(Date().timeIntervalSince(start) * 1000)
      if ProcessInfo.processInfo.environment["BRAIN_TIMINGS"] != nil, let t = whisper_get_timings(ctx) {
        let v = t.pointee
        FileHandle.standardError.write("  encode \(Int(v.encode_ms)) ms, decode \(Int(v.decode_ms)) ms, batch \(Int(v.batchd_ms)) ms, prompt \(Int(v.prompt_ms)) ms, total \(ms) ms\n".data(using: .utf8)!)
      }
      whisper_reset_timings(ctx)
      let result = Result(text: Whisper.foldRepeats(text.trimmingCharacters(in: .whitespacesAndNewlines)), language: lang, millis: ms)
      DispatchQueue.main.async { done(result) }
    }
  }
}
