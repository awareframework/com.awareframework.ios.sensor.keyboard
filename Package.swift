// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "com.awareframework.ios.sensor.keyboard",
    platforms: [.iOS(.v16)],
    products: [
        .library(
            name: "com.awareframework.ios.sensor.keyboard",
            targets: ["com.awareframework.ios.sensor.keyboard"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/awareframework/com.awareframework.ios.core.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "com.awareframework.ios.sensor.keyboard",
            dependencies: [
                .product(
                    name: "com.awareframework.ios.core",
                    package: "com.awareframework.ios.core",
                    condition: .when(platforms: [.iOS])
                )
            ],
            path: "Sources/com.awareframework.ios.sensor.keyboard"
        ),
        .testTarget(
            name: "com.awareframework.ios.sensor.keyboardTests",
            dependencies: [.target(name: "com.awareframework.ios.sensor.keyboard")],
            path: "Tests/com.awareframework.ios.sensor.keyboardTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
