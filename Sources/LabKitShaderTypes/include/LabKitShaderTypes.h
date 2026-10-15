// Shared between Swift (via this C target's module) and MSL (via #include), so the CPU and GPU
// layouts can't drift. Gyre mirrors these by hand (HoloScene.swift:4-30 ↔ Holo.metal:8-31).
#pragma once
#include <simd/simd.h>

/// Per-frame uniforms every LabKit shader sees. Vertex buffer(1), fragment buffer(0).
typedef struct {
  simd_float4x4 viewProj;   // scene frame → clip
  simd_float4x4 attitude;   // scene frame → world (Z up); drives the world-anchored backdrop
  simd_float4 viewport;     // width, height, focus centre x, y (pixels)
  simd_float4 camera;       // focal (px), camera distance (scene units), time (s), EDR headroom
  simd_float4 post;         // bloom gain, scanline depth, chromatic aberration, reduce motion
  simd_float4 misc;         // focus radius (px), scan-band y, flicker gain, AR probe flag
  simd_float4 eye;          // eye position in the scene frame, AR flag
  simd_float4 camA;         // view → camera-image transform a, b, c, d
  simd_float4 camB;         // tx, ty, app slot, app slot
  simd_float4 world;        // north azimuth (world rad), has north, horizon glow, grid strength
} LabFrameUniforms;

/// A glowing segment: a/b.xyz scene-frame endpoints, .w width in pixels; ca/cb rgb × intensity, alpha.
typedef struct {
  simd_float4 a;
  simd_float4 b;
  simd_float4 ca;
  simd_float4 cb;
} LabLineInstance;

typedef struct {
  simd_float4 position;
  simd_float4 normal;
} LabMeshVertex;

/// A flat quad in scene units (y up) for 2D layers: tank walls, props, glass panes, test patches.
/// Drawn by `labQuadVertex` as a 4-vertex triangle strip per instance (vertex buffer 0 = instances,
/// buffer 1 = frame uniforms). 48 bytes.
typedef struct {
  simd_float4 rect;     // minX, minY, maxX, maxY (scene units, before rotation)
  simd_float4 color;    // linear rgb × intensity, alpha
  simd_float4 params;   // z (−1…1, +1 nearest), rotation about the centre (rad), corner radius (scene units), app slot
} LabQuadInstance;

enum LabBufferIndex {
  LabBufferInstances = 0,
  LabBufferFrame = 1,       // vertex stage
  LabBufferApp = 2,         // app-specific uniforms (vertex)
};

enum LabFragmentBufferIndex {
  LabFragmentFrame = 0,
  LabFragmentApp = 1,
};
