// Renders an SVG to PNGs with a transparent background.
//
//     swift scripts/rasterize.swift drawing.svg 512:big.png 32:small.png
//
// Called by scripts/make-icons.py. It exists because qlmanage — the obvious
// tool, and the one this used to use — composites onto opaque white before it
// writes a thumbnail. Every pixel of the alpha channel it produces is 1.0, so
// the menu bar got a white tile with a bird cut out of it rather than a bird.
//
// AppKit reads SVG on its own (macOS 13+, as _NSSVGImageRep), and drawing it
// into a bitmap we allocate ourselves means we choose the background, which is
// none.
//
// Each size is drawn from the vector rather than resampled from a larger
// raster, so a 16px icon is rendered at 16px and not squeezed. Sizes are given
// with their output path attached rather than derived from a convention: the
// icon and the menu bar name their files differently, and a convention that
// serves one of them is a trap for the other.

import AppKit
import Foundation

struct Job {
    let size: Int
    let url: URL
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: rasterize.swift <input.svg> <size>:<output.png> [...]\n".utf8)
    )
    exit(2)
}

let input = URL(fileURLWithPath: arguments[0])
let jobs: [Job] = arguments.dropFirst().map { argument in
    let parts = argument.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, let size = Int(parts[0]), size > 0 else {
        fail("expected <size>:<output.png>, got \(argument)")
    }
    return Job(size: size, url: URL(fileURLWithPath: String(parts[1])))
}

guard let drawing = NSImage(contentsOf: input) else {
    fail("cannot read \(input.path)")
}

for job in jobs {
    // sRGB explicitly. The device profile would bake this display's calibration
    // into a file that ships to other people's screens.
    guard
        let context = CGContext(
            data: nil,
            width: job.size,
            height: job.size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        fail("cannot allocate a \(job.size)px context")
    }

    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high

    drawing.draw(
        in: NSRect(x: 0, y: 0, width: job.size, height: job.size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )

    NSGraphicsContext.restoreGraphicsState()

    guard
        let image = context.makeImage(),
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
        fail("cannot encode the \(job.size)px png")
    }

    do {
        try png.write(to: job.url)
    } catch {
        fail("cannot write \(job.url.path): \(error)")
    }
}
