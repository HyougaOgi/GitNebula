import AppKit
import SceneKit
import Metal

/// Gas occupies a real bounding volume. Each viewing ray integrates density through
/// XYZ noise; orbiting or entering it reveals different filaments and cavities.
final class NebulaVolume: NSObject, SCNProgramDelegate {
    private static let creation: Result<NebulaVolume, Error> = Result {
        guard let source = NebulaRenderer.shared else { throw NSError(domain: "GitNebula.NebulaVolume", code: 1) }
        return try NebulaVolume(source: source)
    }
    static var shared: NebulaVolume? { try? creation.get() }
    static var initializationError: Error? { if case .failure(let error) = creation { return error }; return nil }
    private let program: SCNProgram
    private let noise: MTLTexture
    private(set) var renderError: Error?

    private init(source: NebulaRenderer) throws {
        noise = source.volumeNoise
        let library = try source.metalDevice.makeLibrary(source: Self.shader, options: nil)
        program = SCNProgram()
        super.init()
        program.library = library
        program.vertexFunctionName = "volumeVertex"
        program.fragmentFunctionName = "volumeFragment"
        program.isOpaque = false; program.delegate = self
    }
    func program(_ program: SCNProgram, handleError error: Error) { renderError = error }

    func node(radius: Float) -> SCNNode {
        let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        let material = SCNMaterial()
        material.program = program
        material.setValue(SCNMaterialProperty(contents: noise), forKey: "nebulaNoise")
        // Draw the exit faces so rays still cover the volume when the camera is inside.
        material.cullMode = .front; material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false; material.blendMode = .alpha
        box.materials = [material]
        let node = SCNNode(geometry: box); node.name = "nebula-volume"
        let extent = radius * 1.5
        node.simdScale = SIMD3<Float>(extent * 3.5, extent * 2.9, extent * 3.3)
        node.renderingOrder = -10
        return node
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    // Documented prefix of SceneKit's frame buffer. Runtime Metal compilation
    // cannot import SDK-only headers on machines without developer tools.
    struct SCNSceneBuffer { float4x4 viewTransform; float4x4 inverseViewTransform; };
    struct NodeBuffer { float4x4 inverseModelTransform; float4x4 modelViewProjectionTransform; };
    struct VertexInput { float3 position [[attribute(0)]]; };
    struct VolumeVertex { float4 position [[position]]; float3 local; };
    vertex VolumeVertex volumeVertex(VertexInput in [[stage_in]], constant NodeBuffer &scn_node [[buffer(1)]]) {
        return {scn_node.modelViewProjectionTransform * float4(in.position, 1), in.position};
    }
    float cloudNoise(texture3d<float> tex, float3 p) {
        constexpr sampler s(coord::normalized, address::repeat, filter::linear);
        float result = 0, amplitude = 0.57;
        for (int octave = 0; octave < 4; ++octave) {
            float3 cell = floor(p), f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            result += amplitude * tex.sample(s, (cell + f + 0.5) / 32.0).r;
            p = p * 2.07 + float3(8.1, 3.7, 11.9); amplitude *= 0.47;
        }
        return result;
    }
    fragment float4 volumeFragment(VolumeVertex in [[stage_in]],
                                  constant SCNSceneBuffer &scn_frame [[buffer(0)]],
                                  constant NodeBuffer &scn_node [[buffer(1)]],
                                  texture3d<float> nebulaNoise [[texture(0)]]) {
        float3 origin = (scn_node.inverseModelTransform * scn_frame.inverseViewTransform[3]).xyz;
        float3 ray = normalize(in.local - origin);
        float3 inverseRay = 1.0 / (ray + float3(0.000001));
        float3 a = (-0.5 - origin) * inverseRay, b = (0.5 - origin) * inverseRay;
        float3 lo = min(a, b), hi = max(a, b);
        float entry = max(0.0, max(lo.x, max(lo.y, lo.z)));
        float exit = min(hi.x, min(hi.y, hi.z));
        if (entry >= exit) { discard_fragment(); }
        float step = (exit - entry) / 56.0;
        float3 color = float3(0);
        float alpha = 0;
        for (int sample = 0; sample < 56; ++sample) {
            float3 p = origin + ray * (entry + (float(sample) + 0.5) * step);
            float3 q = p * 3.0;
            float warp = cloudNoise(nebulaNoise, q * 2.7 + float3(4, 7, 3)) - 0.5;
            float3 shape = q + float3(warp * 0.5, warp * 0.3, -warp * 0.45);
            float3 lobeA = (shape - float3(-0.3, 0.13, -0.22)) * float3(1.0, 1.65, 1.25);
            float3 lobeB = (shape - float3(0.43, -0.2, 0.3)) * float3(1.3, 1.2, 1.8);
            float envelope = exp(-dot(lobeA, lobeA) * 1.8) + exp(-dot(lobeB, lobeB) * 2.3) * 0.6;
            float noise = cloudNoise(nebulaNoise, q * 7.0 + float3(5.2, 17.3, 2.1));
            float dust = cloudNoise(nebulaNoise, q * 2.7 + float3(14, 2, 8));
            float density = pow(max(0.0, noise - 0.37) * 3.0, 1.7) * envelope * 6.0;
            density *= smoothstep(0.42, 0.65, dust);
            // Faint outskirts and bright, thin ionized gas remain distinct in depth.
            float filament = pow(saturate(noise * 1.25), 4.0);
            float hue = saturate(shape.x * 0.5 + shape.z * 0.45 + 0.5);
            float3 gas = mix(float3(0.12, 0.38, 0.82), float3(0.66, 0.12, 0.46), hue);
            gas = mix(gas, float3(0.45, 0.25, 0.78), saturate(shape.y + 0.6) * 0.5);
            gas *= 0.24 + filament * 1.2;
            float opacity = 1.0 - exp(-density * step * 2.3);
            color += (1.0 - alpha) * gas * opacity;
            alpha += (1.0 - alpha) * opacity;
            if (alpha > 0.96) { break; }
        }
        return float4(color / max(alpha, 0.001), alpha);
    }
    """
}
