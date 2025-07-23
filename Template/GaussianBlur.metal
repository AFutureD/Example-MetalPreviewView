#include <metal_stdlib>
using namespace metal;

kernel void gaussianBlur(texture2d<half, access::read> inputTexture [[texture(0)]],
                        texture2d<half, access::write> outputTexture [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    half4 color = inputTexture.read(gid);
    outputTexture.write(color, gid);
}
