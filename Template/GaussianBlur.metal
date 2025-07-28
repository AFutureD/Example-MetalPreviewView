#include <metal_stdlib>
using namespace metal;


kernel void gaussianBlur(texture2d<half, access::write> outputTexture [[texture(0)]],
                         texture2d<half, access::sample> inputTexture [[texture(1)]],
                         texture2d<half, access::sample> blurTexture [[texture(2)]],
                         texture2d<float, access::read> mask         [[texture(3)]],
                         const device float3x3& transform             [[ buffer(0) ]],
                         uint2 gid [[thread_position_in_grid]]) {
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);

    float3 homoCoord = float3(gid.x, gid.y, 1.0);

    float3 transformed = transform * homoCoord;
    float2 coord = transformed.xy;

    half4 color;
    if (coord.x < 0.0 || coord.x > inputTexture.get_width() || coord.y < 0.0 || coord.y > inputTexture.get_height()) {
        color = half4(0,1,0,0);
    } else {
        // Read the single channel from the r8Unorm mask texture.
        float maskValue = mask.read(gid).r;

        half4 background = inputTexture.sample(s, coord);
        half4 foreground = blurTexture.sample(s, coord);

        // blend the color
        color = mix(foreground, background, half(maskValue));
    }

    outputTexture.write(color, gid);
}
