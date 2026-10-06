import AppKit
import MetalKit

/// A deterministic 3D noise texture provides coherent turbulence cheaply on Intel
/// and Apple GPUs. Domain warping moves the gas itself instead of rotating an image.
final class NebulaRenderer {
    static let shared: NebulaRenderer? = MTLCreateSystemDefaultDevice().flatMap { try? NebulaRenderer(device: $0) }
    private var cachedImage: CGImage?
    private var cachedTime: Float = -1
    private var cachedSize = CGSize.zero
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let noise: MTLTexture
    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Self.error() }
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "nebulaVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "nebulaFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let texture = MTLTextureDescriptor()
        texture.textureType = .type3D; texture.pixelFormat = .r8Unorm
        texture.width = 32; texture.height = 32; texture.depth = 32
        texture.usage = .shaderRead; texture.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let noise = device.makeTexture(descriptor: texture) else { throw Self.error() }
        self.noise = noise
        var seed: UInt32 = 0x4e656275
        let bytes: [UInt8] = (0..<(32 * 32 * 32)).map { _ in
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return UInt8(truncatingIfNeeded: seed)
        }
        bytes.withUnsafeBytes { data in
            noise.replace(region: MTLRegionMake3D(0, 0, 0, 32, 32, 32), mipmapLevel: 0, slice: 0, withBytes: data.baseAddress!, bytesPerRow: 32, bytesPerImage: 32 * 32)
        }
    }
    private static func error() -> NSError { NSError(domain: "GitNebula.NebulaRenderer", code: 1) }
    private func encode(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer, size: CGSize, time: Float) {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var parameters = SIMD4<Float>(Float(size.width), Float(size.height), time, 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(noise, index: 0)
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
    /// Offscreen rendering also checks the real GPU path in preview tests.
    func image(size: CGSize, time: Float) throws -> CGImage {
        if let cachedImage, cachedTime == time, cachedSize == size { return cachedImage }
        let width = Int(size.width), height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]; descriptor.storageMode = .private
        let rowBytes = ((width * 4 + 255) / 256) * 256
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared), let command = queue.makeCommandBuffer() else { throw Self.error() }
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        encode(pass: pass, command: command, size: size, time: time)
        let blit = command.makeBlitCommandEncoder()
        blit?.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
        blit?.endEncoding()
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        let bytes = Data(bytes: buffer.contents(), count: rowBytes * height)
        guard let provider = CGDataProvider(data: bytes as CFData), let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)], provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw Self.error() }
        cachedImage = image; cachedTime = time; cachedSize = size
        return image
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex nebulaVertex(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        return {float4(uv * 2.0 - 1.0, 0, 1), float2(uv.x, 1.0 - uv.y)};
    }
    float turbulent(texture3d<float> tex, float3 p) {
        constexpr sampler s(coord::normalized, address::repeat, filter::linear);
        float value = 0.0, amplitude = 0.55;
        for (int i = 0; i < 5; ++i) {
            // Smooth interpolation keeps the gas continuous between noise cells.
            float3 cell = floor(p), f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            value += amplitude * tex.sample(s, (cell + f + 0.5) / 32.0).r;
            p = p * 2.03 + float3(7.1, 13.7, 3.9); amplitude *= 0.48;
        }
        return value;
    }
    fragment float4 nebulaFragment(Vertex in [[stage_in]], texture3d<float> tex [[texture(0)]], constant float4 &params [[buffer(0)]]) {
        float2 uv = in.uv;
        float2 p = (uv - 0.5) * float2(params.x / params.y, 1.0) * 3.4;
        float t = params.z * 0.09;
        float3 q = float3(p, 0.3);
        float2 warp = float2(turbulent(tex, q * 1.8 + float3(t * 0.25, 0, t * 0.32)), turbulent(tex, q * 1.6 + float3(9, 3 - t * 0.2, t * 0.28))) - 0.5;
        float2 shape = p + warp * 0.65;
        shape = float2(shape.x * 0.93 + shape.y * 0.36, -shape.x * 0.36 + shape.y * 0.93);
        float envelope = exp(-dot(shape * float2(0.68, 1.3), shape * float2(0.68, 1.3)) * 1.25);
        float3 color = float3(0);
        float alpha = 0;
        // Thin depth slices scatter light through differently moving layers.
        for (int layer = 0; layer < 6; ++layer) {
            float depth = float(layer) * 0.43;
            float3 gas = float3(p * 3.3 + warp * 3.6 + float2(t * (0.13 + depth * 0.06), -t * 0.19), depth + t * 0.15);
            float n = turbulent(tex, gas);
            float density = smoothstep(0.29, 0.73, n) * envelope;
            float filaments = pow(max(0.0, 1.0 - abs(n * 2.0 - 1.02)), 9.0);
            float dust = smoothstep(0.52, 0.70, turbulent(tex, gas * 1.2 + float3(12, 1, 7)));
            float warmth = smoothstep(-0.8, 1.0, shape.x + warp.y * 2.0 + depth * 0.1);
            float3 emission = mix(float3(0.08, 0.52, 0.85), float3(0.85, 0.19, 0.40), warmth);
            emission = mix(emission, float3(0.67, 0.32, 0.91), 0.25);
            emission += float3(0.85, 0.73, 0.87) * filaments * 0.23;
            float a = density * (0.22 + filaments * 0.08);
            emission *= 1.0 - dust * 0.84;
            color += (1.0 - alpha) * emission * a;
            alpha += (1.0 - alpha) * a;
        }
        float edge = smoothstep(0.0, 0.13, uv.x) * smoothstep(0.0, 0.13, 1.0 - uv.x) * smoothstep(0.0, 0.15, uv.y) * smoothstep(0.0, 0.15, 1.0 - uv.y);
        color *= edge * 1.4; alpha *= edge;
        return float4(min(color, float3(alpha)), alpha);
    }
    """
}
