#include <metal_stdlib>
using namespace metal;


kernel void gaussianBlur(texture2d<half, access::write> outputTexture [[texture(0)]],
                         texture2d<half, access::sample> inputTexture [[texture(1)]],
                         texture2d<float, access::read> mask         [[texture(2)]],
                         const device float3x3& transform             [[ buffer(0) ]],
                         uint2 gid [[thread_position_in_grid]]) {
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);

    float3 homoCoord = float3(gid.x, gid.y, 1.0);

    float3 transformed = transform * homoCoord;
    float2 transformedCoord = transformed.xy;


    half4 color;
    // test if gid out of input texture.
    float2 uv = transformedCoord / float2(inputTexture.get_width(), inputTexture.get_height());
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        color = half4(0,0,0,0);
    } else {
        color = inputTexture.sample(s, transformedCoord);
    }

    // Read the single channel from the r8Unorm mask texture.
    float maskValue = mask.read(gid).r;

    color = mix(color, half4(0, 0, 0, 0), half(maskValue));

    outputTexture.write(color, gid);
}
