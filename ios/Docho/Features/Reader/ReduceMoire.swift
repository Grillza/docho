import CoreGraphics
import Metal
import Nuke
import UIKit

/// Reduce moiré (Android 0.32.8): while a page is shown shrunk, fine screentone is smoothed into
/// the flat grey it stands for and line art is kept sharp, so tone finer than the screen can't
/// beat into wavy patterns. Runs as a Nuke processor on the full-size page, before it's resized;
/// the kernels are in ReduceMoire.metal.
struct ReduceMoireProcessor: ImageProcessing, Hashable {
    /// The pixel box the page is fitted into on screen. Long strip passes an unbounded height.
    var boxWidth: CGFloat
    var boxHeight: CGFloat
    /// Zoom on top of the fitted size.
    var zoom: CGFloat = 1

    /// Pages are left alone from this scale up, as on Android.
    static let threshold: CGFloat = 0.95

    var identifier: String { "io.github.grillza.docho.reduceMoire?w=\(boxWidth)&h=\(boxHeight)&z=\(zoom)" }

    /// The scale the page will be shown at, in screen pixels per page pixel.
    func scale(for pixelSize: CGSize) -> CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        return min(boxWidth / pixelSize.width, boxHeight / pixelSize.height) * zoom
    }

    func process(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return image }
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let scale = scale(for: pixelSize)
        guard scale < Self.threshold,
              let filtered = ReduceMoireFilter.shared?.apply(to: cgImage, scale: max(0.3, scale))
        else { return image }
        return UIImage(cgImage: filtered, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// The Metal side of Reduce moiré. Metal devices, queues and pipelines are thread-safe, so one
/// filter serves every Nuke processing queue.
final class ReduceMoireFilter: @unchecked Sendable {
    static let shared = ReduceMoireFilter()

    /// Pages larger than this are shown as they are: the intermediate textures would take too
    /// much memory (a long strip image, which is rarely screentone anyway).
    static let maxPixels = 12_000_000

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let blurAcross, blurDown, findLines, spreadAcross, spreadDown, combine: MTLComputePipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .main)
        else { return nil }
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            library.makeFunction(name: name).flatMap { try? device.makeComputePipelineState(function: $0) }
        }
        guard let blurAcross = pipeline("moire_blur_across"),
              let blurDown = pipeline("moire_blur_down"),
              let findLines = pipeline("moire_find_lines"),
              let spreadAcross = pipeline("moire_spread_across"),
              let spreadDown = pipeline("moire_spread_down"),
              let combine = pipeline("moire_combine")
        else { return nil }
        self.device = device
        self.queue = queue
        self.blurAcross = blurAcross
        self.blurDown = blurDown
        self.findLines = findLines
        self.spreadAcross = spreadAcross
        self.spreadDown = spreadDown
        self.combine = combine
    }

    /// The page filtered for showing at `scale` (0.3...1, output pixels per page pixel), or nil
    /// if it couldn't be.
    func apply(to image: CGImage, scale: CGFloat) -> CGImage? {
        let width = image.width
        let height = image.height
        let limit = 16384
        guard width > 0, height > 0, width * height <= Self.maxPixels, width <= limit, height <= limit,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        // The page as 8-bit sRGB RGBA, as Android's renderer has it.
        let bytesPerRow = width * 4
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 16)
        defer { pixels.deallocate() }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func texture(_ format: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false
            )
            descriptor.usage = usage
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor)
        }
        let readWrite: MTLTextureUsage = [.shaderRead, .shaderWrite]
        guard let page = texture(.rgba8Unorm, .shaderRead),
              let bh = texture(.rgba16Float, readWrite),
              let blurred = texture(.rgba16Float, readWrite),
              let edge = texture(.r16Float, readWrite),
              let eh = texture(.r16Float, readWrite),
              let mask = texture(.r16Float, readWrite),
              let output = texture(.rgba8Unorm, .shaderWrite),
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder()
        else { return nil }
        let region = MTLRegionMake2D(0, 0, width, height)
        page.replace(region: region, mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)

        var shaderScale = Float(min(max(scale, 0.3), 1))
        let groups = MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1)
        let groupSize = MTLSize(width: 8, height: 8, depth: 1)
        func pass(_ pipeline: MTLComputePipelineState, _ textures: [MTLTexture]) {
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
            encoder.setBytes(&shaderScale, length: MemoryLayout<Float>.size, index: 0)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: groupSize)
        }
        pass(blurAcross, [page, bh])
        pass(blurDown, [bh, blurred])
        pass(findLines, [blurred, edge])
        pass(spreadAcross, [edge, eh])
        pass(spreadDown, [eh, mask])
        pass(combine, [page, blurred, mask, output])
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }

        output.getBytes(pixels, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        return context.makeImage()
    }
}
