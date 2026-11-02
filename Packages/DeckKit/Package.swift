// swift-tools-version: 6.2
//
//  DeckKit — everything the deck is, minus the `@main` the app target owns.
//
//  The dependency rule is the manifest's to keep, not a comment's: `DeckCore`
//  declares no dependencies, so it *cannot* import `DeckPorts`, `DeckAdapters`
//  or `DeckApp`. The compiler refuses, at no cost.
//
//  Layering, innermost first:
//
//      DeckCore      pure model, reducer, layout, projection. No I/O, no clock.
//      DeckPorts     the protocols the core is spoken to through.
//      DeckAdapters  the implementations that touch the world.
//      DeckApp       the runtime, and every view the app shows.
//
//  Test fixtures are target resources rather than files found by walking up
//  from `#filePath`, so a test reads what its own bundle carries and the suite
//  does not depend on where the package sits in a repository.

import PackageDescription

let package = Package(
    name: "DeckKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DeckApp", targets: ["DeckApp"]),
        .library(name: "DeckCore", targets: ["DeckCore"]),
    ],
    targets: [
        .target(name: "DeckCore"),
        .target(name: "DeckPorts", dependencies: ["DeckCore"]),
        .target(name: "DeckAdapters", dependencies: ["DeckCore", "DeckPorts"]),
        .target(name: "DeckApp", dependencies: ["DeckCore", "DeckPorts", "DeckAdapters"]),

        .testTarget(name: "DeckCoreTests",
                    dependencies: ["DeckCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "DeckAdaptersTests",
                    dependencies: ["DeckAdapters", "DeckPorts", "DeckCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "DeckAppTests",
                    dependencies: ["DeckApp", "DeckCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
