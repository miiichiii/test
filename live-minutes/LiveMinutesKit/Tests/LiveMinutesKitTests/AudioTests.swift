import AVFAudio
import Testing
@testable import LiveMinutesKit

@Suite("音声の変換")
struct StreamingAudioConverterTests {
    /// SpeechAnalyzer.bestAvailableAudioFormat が実機で返した形式（1ch / 16kHz / Int16）
    let analyzerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    /// 出力（16kHz）の合計が、期待値より 100ms 分（1,600フレーム）以上少なくなく、期待値を超えない。
    /// 入力ブロックで `.endOfStream` を返す不具合があると、出力が途中で止まってこの範囲を外れる。
    static func isRealTime(_ total: Int, expected: Int) -> Bool {
        total >= expected - 1_600 && total <= expected
    }

    @Test("48kHz Float32 モノラルを 16kHz Int16 に変換し続けても、出力が途切れず実時間に合う")
    func resamplesContinuously() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let converter = try StreamingAudioConverter(from: input, to: analyzerFormat)

        var totalFrames = 0
        var peak: Int16 = 0
        for i in 0..<50 {
            let buffer = try #require(TestTone.sine(format: input, frameCount: 4_800, startFrame: i * 4_800))
            if let output = try converter.convert(buffer) {
                #expect(output.format.sampleRate == 16_000)
                totalFrames += Int(output.frameLength)
                let samples = try #require(output.int16ChannelData)[0]
                for f in 0..<Int(output.frameLength) {
                    peak = max(peak, abs(samples[f]))
                }
            }
        }

        // 5秒分（50 × 100ms）。変換器は内部に数十ms分を溜めるので、出力は少し短くなるが、
        // 不足は増え続けない（100バッファ流しても最大約60ms分だった）。100ms分以内なら正常とみなす。
        #expect(Self.isRealTime(totalFrames, expected: 80_000), "合計 \(totalFrames) フレーム")
        // 振幅 0.5 のサイン波なので、ピークは Int16 の最大値の半分前後になる。
        #expect(peak > 12_000 && peak < 20_000, "ピーク \(peak)")
    }

    @Test("44.1kHz ステレオ（多チャンネル）もモノラルに変換できる")
    func downmixesStereo() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let converter = try StreamingAudioConverter(from: input, to: analyzerFormat)

        var totalFrames = 0
        for i in 0..<50 {
            let buffer = try #require(TestTone.sine(format: input, frameCount: 4_410, startFrame: i * 4_410))
            totalFrames += Int(try converter.convert(buffer)?.frameLength ?? 0)
        }
        #expect(Self.isRealTime(totalFrames, expected: 80_000), "合計 \(totalFrames) フレーム")
    }

    @Test("Float32 の出力形式にも変換できる")
    func convertsToFloatOutput() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let output = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let converter = try StreamingAudioConverter(from: input, to: output)

        var totalFrames = 0
        for i in 0..<50 {
            let buffer = try #require(TestTone.sine(format: input, frameCount: 4_800, startFrame: i * 4_800))
            totalFrames += Int(try converter.convert(buffer)?.frameLength ?? 0)
        }
        #expect(Self.isRealTime(totalFrames, expected: 80_000), "合計 \(totalFrames) フレーム")
    }

    @Test("空のバッファは nil を返す")
    func emptyBufferReturnsNil() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let converter = try StreamingAudioConverter(from: input, to: analyzerFormat)
        let empty = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 16))
        #expect(try converter.convert(empty) == nil)
    }
}

@Suite("tap の処理（TapProcessor）")
struct TapProcessorTests {
    let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    @Test("形式が合うバッファは変換して流し、入力レベルも出す")
    func convertsAndReportsLevel() async throws {
        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self)
        let processor = TapProcessor(
            inputFormat: inputFormat,
            converter: try StreamingAudioConverter(from: inputFormat, to: outputFormat),
            chunks: chunkContinuation,
            levels: levelContinuation
        )

        for i in 0..<100 {
            processor.process(try #require(TestTone.sine(format: inputFormat, frameCount: 4_800, startFrame: i * 4_800)))
        }
        chunkContinuation.finish()
        levelContinuation.finish()

        var chunkCount = 0
        var totalFrames = 0
        var iterator = chunks.makeAsyncIterator()
        while let chunk = await iterator.next() {
            #expect(chunk.buffer.format.isEqual(outputFormat))
            chunkCount += 1
            totalFrames += Int(chunk.buffer.frameLength)
        }
        #expect(chunkCount > 90)
        #expect(StreamingAudioConverterTests.isRealTime(totalFrames, expected: 160_000), "合計 \(totalFrames) フレーム")

        var levelCount = 0
        var levelIterator = levels.makeAsyncIterator()
        while let level = await levelIterator.next() {
            #expect(level > 0.8)  // 振幅 0.5 のサイン波は約 -9dBFS
            levelCount += 1
        }
        #expect(levelCount == 100)
    }

    @Test("サンプルレートかチャンネル数が違うバッファは捨てる（tap の付け直し直後に古い形式が来た場合）")
    func dropsMismatchedFormat() async throws {
        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self)
        let processor = TapProcessor(
            inputFormat: inputFormat,
            converter: try StreamingAudioConverter(from: inputFormat, to: outputFormat),
            chunks: chunkContinuation,
            levels: levelContinuation
        )

        let otherRate = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let otherChannels = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        processor.process(try #require(TestTone.sine(format: otherRate, frameCount: 4_410)))
        processor.process(try #require(TestTone.sine(format: otherChannels, frameCount: 4_800)))
        chunkContinuation.finish()
        levelContinuation.finish()

        var chunkIterator = chunks.makeAsyncIterator()
        #expect(await chunkIterator.next() == nil)
        var levelIterator = levels.makeAsyncIterator()
        #expect(await levelIterator.next() == nil)
    }
}

@Suite("エラーの文言")
struct ErrorMessageTests {
    @Test("画面に出しうるエラーは日本語の説明を持つ")
    func japaneseDescriptions() {
        let errors: [any Error] = [
            AudioSourceError.noInputDevice,
            AudioSourceError.converterUnavailable,
            AudioSourceError.engineStartFailed("x"),
            TranscriptionError.noCompatibleAudioFormat,
            TranscriptionError.recognitionEnded,
        ]
        for error in errors {
            let text = error.localizedDescription
            #expect(!text.contains("The operation"), "\(text)")
            #expect(text.unicodeScalars.contains { $0.value >= 0x3040 }, "\(text)")
        }
    }
}

@Suite("入力レベル")
struct AudioLevelTests {
    @Test("無音は 0")
    func silenceIsZero() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = try #require(TestTone.sine(format: format, amplitude: 0, frameCount: 4_800))
        #expect(AudioLevel.normalized(rms: AudioLevel.rms(of: buffer)) == 0)
    }

    @Test("フルスケールのサイン波は -3dBFS で、ほぼ上限になる")
    func fullScaleSine() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = try #require(TestTone.sine(format: format, amplitude: 1, frameCount: 4_800))
        let rms = AudioLevel.rms(of: buffer)
        #expect(abs(rms - 0.7071) < 0.01)
        #expect(AudioLevel.normalized(rms: rms) > 0.9)
    }

    @Test("Int16 のバッファでも Float32 と同じ RMS になる")
    func int16MatchesFloat() throws {
        let floatFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let intFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let a = AudioLevel.rms(of: try #require(TestTone.sine(format: floatFormat, amplitude: 0.25, frameCount: 1_600)))
        let b = AudioLevel.rms(of: try #require(TestTone.sine(format: intFormat, amplitude: 0.25, frameCount: 1_600)))
        #expect(abs(a - b) < 0.001)
    }

    @Test("dBFS から 0…1 への対応", arguments: [
        (Float(1), Float(1)),
        (Float(0.1), Float(2.0 / 3.0)),  // -20dBFS
        (Float(0.001), Float(0)),        // -60dBFS
        (Float(0.0001), Float(0)),       // 下限より小さい
        (Float.nan, Float(0)),
    ])
    func normalization(rms: Float, expected: Float) {
        #expect(abs(AudioLevel.normalized(rms: rms) - expected) < 0.001)
    }
}

@Suite("FakeAudioSource")
struct FakeAudioSourceTests {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    @Test("用意したバッファを順に流し、stop でストリームが終わる。もう一度 start できる")
    func streamsAndRestarts() async throws {
        let chunks = try (0..<3).map { i in
            AudioChunk(buffer: try #require(TestTone.sine(format: format, frameCount: 1_600, startFrame: i * 1_600)))
        }
        let source = FakeAudioSource(chunks: chunks)

        for round in 1...2 {
            let stream = try await source.start(outputFormat: format)
            await source.stop()
            var received = 0
            for await chunk in stream {
                #expect(chunk.buffer.frameLength == 1_600)
                received += 1
            }
            #expect(received == 3)
            #expect(await source.startCount == round)
        }
    }

    @Test("開始中にもう一度 start するとエラー")
    func rejectsDoubleStart() async throws {
        let source = FakeAudioSource(chunks: [])
        _ = try await source.start(outputFormat: format)
        await #expect(throws: AudioSourceError.alreadyRunning) {
            _ = try await source.start(outputFormat: format)
        }
        await source.stop()
    }
}
