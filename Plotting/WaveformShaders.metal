//
//  WaveformShaders.metal
//  Plotting
//
//  GPU shaders for the ECG waveform canvas. Three vertex functions:
//
//    traceVertex      — Reads a Float32 sample from a buffer using vertex_id as
//                       the sample index. Used for raw line-strip rendering.
//    lineVertex       — Reads (xData, yData) pairs from a buffer. Used for grid
//                       lines and annotation rules.
//    envelopeVertex   — Instanced quad rendering for pyramid (min, max) bins.
//                       4 vertices per instance, with vid bits selecting
//                       left/right and bottom/top corners.
//
//  One fragment function: colorFragment reads a single float4 color and outputs
//  it directly. Lets us blend translucent passes (grid, envelope, annotation)
//  over the paper background cleared at the start of the render pass.
//

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float startSample;
    float endSample;
    float yMin;
    float yMax;
};

struct EnvelopeUniforms {
    float startSample;
    float endSample;
    float yMin;
    float yMax;
    float binSamples;
};

struct VertexOut {
    float4 position [[position]];
};

static float4 toClipSpace(float xData, float yData, constant Uniforms& u) {
    float xClip = 2.0 * (xData - u.startSample) / (u.endSample - u.startSample) - 1.0;
    float yClip = 2.0 * (yData - u.yMin) / (u.yMax - u.yMin) - 1.0;
    return float4(xClip, yClip, 0.0, 1.0);
}

vertex VertexOut traceVertex(uint vid [[vertex_id]],
                             constant float* samples [[buffer(0)]],
                             constant Uniforms& u [[buffer(1)]]) {
    VertexOut out;
    float yData = samples[vid];
    // Drop out-of-range samples: emit a NaN position so any line-strip segment
    // adjacent to this vertex is discarded by the rasterizer. We never paint
    // a fake horizontal segment along the chart edge — the trace just gaps.
    if (yData < u.yMin || yData > u.yMax) {
        float nanV = 0.0 / 0.0;
        out.position = float4(nanV, nanV, nanV, nanV);
    } else {
        out.position = toClipSpace(float(vid), yData, u);
    }
    return out;
}

vertex VertexOut lineVertex(uint vid [[vertex_id]],
                            constant float2* points [[buffer(0)]],
                            constant Uniforms& u [[buffer(1)]]) {
    VertexOut out;
    float2 p = points[vid];
    out.position = toClipSpace(p.x, p.y, u);
    return out;
}

vertex VertexOut envelopeVertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                constant float2* bins [[buffer(0)]],
                                constant EnvelopeUniforms& u [[buffer(1)]]) {
    float2 bin = bins[iid];                     // (min, max)
    bool isRight = (vid & 1u) != 0u;            // vid 1 or 3
    bool isTop   = (vid & 2u) != 0u;            // vid 2 or 3
    float xData = (float(iid) + (isRight ? 1.0 : 0.0)) * u.binSamples;
    float yData = isTop ? bin.y : bin.x;

    VertexOut out;
    float xClip = 2.0 * (xData - u.startSample) / (u.endSample - u.startSample) - 1.0;
    float yClip = 2.0 * (yData - u.yMin) / (u.yMax - u.yMin) - 1.0;
    out.position = float4(xClip, yClip, 0.0, 1.0);
    return out;
}

/// Translucent full-height range quad. One instance per annotation; the range
/// buffer holds (startSample, endSample) and we fill the entire vertical extent
/// inside that window. Used to mark VF/VT episodes, AFib runs, noise gaps, etc.
vertex VertexOut rangeVertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             constant float2* ranges [[buffer(0)]],
                             constant Uniforms& u [[buffer(1)]]) {
    float2 r = ranges[iid];                     // (startSample, endSample)
    bool isRight = (vid & 1u) != 0u;
    bool isTop   = (vid & 2u) != 0u;
    float xData = isRight ? r.y : r.x;
    float yData = isTop ? u.yMax : u.yMin;

    VertexOut out;
    out.position = toClipSpace(xData, yData, u);
    return out;
}

fragment float4 colorFragment(VertexOut in [[stage_in]],
                              constant float4& color [[buffer(0)]]) {
    return color;
}
