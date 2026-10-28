# Third-party notices

## amanu — MIT

Granula adapts code from [amanu](https://github.com/gsamat/amanu):

- `Sources/GranulaCore/Audio/SystemAudioCapture.swift` — from `Sources/amanu/Audio/SystemAudioRecorder.swift` (process tap, private aggregate device, IOProc).
- `Sources/GranulaCore/Audio/AudioProcesses.swift` — from `Sources/amanu/Audio/AudioProcesses.swift` (Core Audio process objects).
- `Sources/GranulaCore/Audio/CallDetector.swift` — call-app bundle IDs from `Sources/amanu/Audio/MicActivityMonitor.swift`.
- `Sources/GranulaCore/Processing/EchoFilter.swift` — from `Sources/amanu/Transcription/EchoFilter.swift`.
- `Sources/GranulaCore/Processing/SummaryGenerator.swift` — `claude` CLI flags from `Sources/amanu/Summary/LLMBackend.swift`.

```
MIT License

Copyright (c) 2026 Andrew Jones
Copyright (c) 2026 Samat Galimov

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## FluidAudio — Apache License 2.0

Speech recognition runs on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Swift package dependency, Apache-2.0) with the Parakeet TDT 0.6B v3 Ultra Core ML model from Hugging Face (`FluidInference/parakeet-ultra-coreml`; see its model card for the model license).
