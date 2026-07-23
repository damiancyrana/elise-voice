// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EliseVoice",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "EliseVoice", targets: ["EliseVoice"]),
        .executable(name: "EliseVoiceASRCheck", targets: ["EliseVoiceASRCheck"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.0.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "EliseVoice",
            dependencies: [
                "EliseVoiceCore"
            ]
        ),
        .target(
            name: "EliseVoiceCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            exclude: [
                "PersonalWakeWordAudioNormalizer.swift",
                "PersonalWakeWordVerifier.swift",
                "WakeWordDecisionGate.swift",
                "WakeWordDetector.swift",
                "WakeWordTranscriptMatcher.swift"
            ]
        ),
        .executableTarget(
            name: "EliseVoiceASRCheck",
            dependencies: ["EliseVoiceCore"],
            path: "Integration"
        )
    ]
)
