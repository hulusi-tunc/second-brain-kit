// swift-tools-version:5.9
// Brain: the second brain's Mac app, in the notch. Dictation, asking the brain, call notes.
// Whisper is linked from vendor/whisper.cpp, built from source with one patch (scripts/whisper.sh,
// "brain patch"): with the language on auto, stock whisper.cpp encodes the audio twice, once to
// detect the language and once to transcribe; the patch reuses the first.
import PackageDescription

let w = Context.packageDirectory + "/vendor/whisper.cpp"
let package = Package(
  name: "Brain",
  platforms: [.macOS("26.0")],
  targets: [
    .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
    .executableTarget(
      name: "Brain",
      dependencies: ["CWhisper"],
      path: "Sources/Brain",
      swiftSettings: [.unsafeFlags(["-Xcc", "-I\(w)/include", "-Xcc", "-I\(w)/ggml/include"])],
      linkerSettings: [
        .unsafeFlags([
          "-L\(w)/build/src", "-L\(w)/build/ggml/src", "-L\(w)/build/ggml/src/ggml-metal", "-L\(w)/build/ggml/src/ggml-blas",
        ]),
        .linkedLibrary("whisper"), .linkedLibrary("ggml"), .linkedLibrary("ggml-base"), .linkedLibrary("ggml-cpu"),
        .linkedLibrary("ggml-metal"), .linkedLibrary("ggml-blas"), .linkedLibrary("c++"),
        .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("Accelerate"), .linkedFramework("Foundation"), .linkedFramework("EventKit"),
      ]
    ),
  ]
)
