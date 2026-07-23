// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "meetrec",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "meetrec", targets: ["MeetRec"]),
        .executable(name: "MeetRecGUI", targets: ["MeetRecGUI"]),
    ],
    targets: [
        .target(
            name: "MeetRecCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .executableTarget(
            name: "MeetRec",
            dependencies: ["MeetRecCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .executableTarget(
            name: "MeetRecGUI",
            dependencies: ["MeetRecCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
