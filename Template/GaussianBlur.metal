#include <metal_stdlib>
using namespace metal;

kernel void gaussianBlur(texture2d<half, access::sample> inputTexture [[texture(0)]],
                         texture2d<half, access::write> outputTexture [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);

    float2 coord = float2(gid);
    coord = float2(gid.x * inputTexture.get_width() / outputTexture.get_width() ,
                   gid.y * inputTexture.get_height() / outputTexture.get_height());
    half4 color = inputTexture.sample(s, coord);

    outputTexture.write(color, gid);
}
