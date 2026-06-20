#!/usr/bin/env swift

import AppKit
import Foundation

let fileManager = FileManager.default
let rootURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let sourceURL = rootURL
    .appendingPathComponent("artwork")
    .appendingPathComponent("AppIconSource.png")
let resourcesURL = rootURL
    .appendingPathComponent("Sources")
    .appendingPathComponent("MyFinder")
    .appendingPathComponent("Resources")
let buildURL = rootURL
    .appendingPathComponent(".build")
    .appendingPathComponent("appicon")
let iconsetURL = buildURL.appendingPathComponent("AppIcon.iconset")

struct RGBAImage {
    var pixels: [UInt8]
    let width: Int
    let height: Int
}

enum AppIconError: Error, LocalizedError {
    case missingSource(URL)
    case cannotLoadSource(URL)
    case cannotCreateBitmap(Int)
    case cannotCreateImage
    case cannotWritePNG(Int)
    case iconutilFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .missingSource(let url):
            "Missing source image at \(url.path)."
        case .cannotLoadSource(let url):
            "Could not load source image at \(url.path)."
        case .cannotCreateBitmap(let size):
            "Could not create \(size)px bitmap."
        case .cannotCreateImage:
            "Could not create processed icon image."
        case .cannotWritePNG(let size):
            "Could not write \(size)px PNG."
        case .iconutilFailed(let status):
            "iconutil failed with status \(status)."
        }
    }
}

func loadSourceImage() throws -> CGImage {
    guard fileManager.fileExists(atPath: sourceURL.path) else {
        throw AppIconError.missingSource(sourceURL)
    }

    guard let image = NSImage(contentsOf: sourceURL),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw AppIconError.cannotLoadSource(sourceURL)
    }

    return cgImage
}

func rgbaImage(from cgImage: CGImage) throws -> RGBAImage {
    let width = cgImage.width
    let height = cgImage.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    try pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw AppIconError.cannotCreateBitmap(width)
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    return RGBAImage(pixels: pixels, width: width, height: height)
}

func isBackgroundCandidate(_ pixels: [UInt8], at index: Int, soft: Bool = false) -> Bool {
    let offset = index * 4
    let red = CGFloat(pixels[offset]) / 255
    let green = CGFloat(pixels[offset + 1]) / 255
    let blue = CGFloat(pixels[offset + 2]) / 255
    let alpha = CGFloat(pixels[offset + 3]) / 255

    guard alpha > 0.04 else {
        return true
    }

    let brightest = max(red, green, blue)
    let darkest = min(red, green, blue)
    let saturation = brightest == 0 ? 0 : (brightest - darkest) / brightest

    if soft {
        return brightest > 0.52 && saturation < 0.40
    }

    return brightest > 0.64 && saturation < 0.28
}

func eraseEdgeConnectedBackground(from image: RGBAImage) -> RGBAImage {
    let width = image.width
    let height = image.height
    var pixels = image.pixels
    var background = [Bool](repeating: false, count: width * height)
    var queue = [Int]()
    queue.reserveCapacity(width * height / 3)

    func enqueueIfNeeded(_ index: Int) {
        guard !background[index],
              isBackgroundCandidate(pixels, at: index) else {
            return
        }

        background[index] = true
        queue.append(index)
    }

    for x in 0..<width {
        enqueueIfNeeded(x)
        enqueueIfNeeded((height - 1) * width + x)
    }

    for y in 0..<height {
        enqueueIfNeeded(y * width)
        enqueueIfNeeded(y * width + width - 1)
    }

    var head = 0
    while head < queue.count {
        let index = queue[head]
        head += 1

        let x = index % width
        let y = index / width

        if x > 0 { enqueueIfNeeded(index - 1) }
        if x < width - 1 { enqueueIfNeeded(index + 1) }
        if y > 0 { enqueueIfNeeded(index - width) }
        if y < height - 1 { enqueueIfNeeded(index + width) }
    }

    for _ in 0..<3 {
        var expanded = background

        for index in 0..<background.count where !background[index] && isBackgroundCandidate(pixels, at: index, soft: true) {
            let x = index % width
            let y = index / width

            let touchesBackground =
                (x > 0 && background[index - 1]) ||
                (x < width - 1 && background[index + 1]) ||
                (y > 0 && background[index - width]) ||
                (y < height - 1 && background[index + width])

            if touchesBackground {
                expanded[index] = true
            }
        }

        background = expanded
    }

    for index in 0..<background.count where background[index] {
        let offset = index * 4
        pixels[offset] = 0
        pixels[offset + 1] = 0
        pixels[offset + 2] = 0
        pixels[offset + 3] = 0
    }

    return RGBAImage(pixels: pixels, width: width, height: height)
}

func cgImage(from image: RGBAImage) throws -> CGImage {
    let data = Data(image.pixels)
    guard let provider = CGDataProvider(data: data as CFData),
          let cgImage = CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
          ) else {
        throw AppIconError.cannotCreateImage
    }

    return cgImage
}

func renderPNG(from source: CGImage, size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [.alphaFirst],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw AppIconError.cannotCreateBitmap(size)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let image = NSImage(cgImage: source, size: NSSize(width: source.width, height: source.height))
    image.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: NSRect(x: 0, y: 0, width: source.width, height: source.height),
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw AppIconError.cannotWritePNG(size)
    }

    return pngData
}

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sourceImage = try loadSourceImage()
let transparentImage = try cgImage(from: eraseEdgeConnectedBackground(from: try rgbaImage(from: sourceImage)))

let iconFiles: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

try renderPNG(from: transparentImage, size: 1024)
    .write(to: resourcesURL.appendingPathComponent("AppIcon.png"))

for file in iconFiles {
    try renderPNG(from: transparentImage, size: file.pixels)
        .write(to: iconsetURL.appendingPathComponent(file.name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c",
    "icns",
    iconsetURL.path,
    "-o",
    resourcesURL.appendingPathComponent("AppIcon.icns").path
]

try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw AppIconError.iconutilFailed(process.terminationStatus)
}

print(resourcesURL.appendingPathComponent("AppIcon.icns").path)
