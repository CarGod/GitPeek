// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitPeek",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "GitPeek",
            path: "Sources/GitPeek"
        )
    ]
)
