// SPDX-License-Identifier: GPL-3.0-or-later

/// Metal source for the Immersive visualizer family (`ImmersiveRenderer`):
/// GPU-simulated particles, a fluid simulation and raymarched 3D scenes.
/// Compiled at runtime like `visualizerShaderSource`, as its own library.
///
/// `SU` must stay in step with `SceneUniforms` in `ImmersiveRenderer.swift`:
/// twenty floats, 80-byte stride.
///
/// The silence rule holds here too: every motion is integrated with `u.dt`
/// or reads `u.time` / `u.travel`, all of which stop with the audio, and
/// nothing reads a frame counter or the wall clock.
///
/// Colour here is linear light; the renderer's composite pass applies the
/// filmic curve and the display gamma.
let immersiveShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct SU {
    float time;
    float bass;
    float mid;
    float treb;
    float level;
    float beat;
    float aspect;
    float dt;
    float seed;
    float hue;
    float variant;
    float fade;
    float travel;
    float gridW;
    float resX;
    float resY;
    float gain;
    float count;
    float gridH;
    float dof;
};

struct FS { float4 position [[position]]; float2 uv; };

vertex FS v_full(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    FS o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// --- Helpers ---

static float rnd(uint n) {
    uint h = n * 747796405u + 2891336453u;
    h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
    h ^= h >> 22u;
    return float(h & 0xFFFFFFu) / 16777216.0;
}

static float hash21(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

/// Curated gradients rather than a rainbow: the whole part of `sel` picks one,
/// the fraction slides along it.
static float3 pal(float t, float sel) {
    int k = int(sel) & 3;
    float3 c = float3(1.0, 1.0, 1.0);
    float3 d = float3(0.0, 0.10, 0.20);            // ember and ice
    if (k == 1) { c = float3(1.0, 0.7, 0.4); d = float3(0.0, 0.15, 0.20); }   // dusk
    if (k == 2) { c = float3(2.0, 1.0, 0.0); d = float3(0.50, 0.20, 0.25); }  // neon
    if (k == 3) { d = float3(0.30, 0.20, 0.20); }                            // orchid
    float3 v = 0.5 + 0.5 * cos(6.28318 * (c * (t + fract(sel)) + d));
    // To linear light, which also deepens the colours.
    return v * v;
}

/// The same gradients at full strength, for dye that should glow.
static float3 palv(float t, float sel) {
    return sqrt(pal(t, sel));
}

static float bandAt(const device float* spectrum, float x) {
    float f = clamp(x, 0.0, 0.9999) * 63.0;
    int i = int(f);
    return mix(spectrum[i], spectrum[min(i + 1, 63)], fract(f));
}

static float2 rot2(float2 p, float a) {
    float c = cos(a);
    float s = sin(a);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// --- Particles ---

struct Particle { float4 pos; float4 vel; };   // pos.w = life, vel.w = band level

/// A divergence-free flow: no component depends on its own axis, so the field
/// neither bunches particles up nor thins them out, it only stirs.
static float3 flow(float3 p, float t) {
    float3 v = float3(sin(p.y * 1.3 + t) + cos(p.z * 1.7 - t * 0.7),
                      sin(p.z * 1.1 - t * 0.8) + cos(p.x * 1.9 + t * 0.5),
                      sin(p.x * 1.5 + t * 0.6) + cos(p.y * 1.2 - t));
    float3 q = p.zxy * 2.3 + 1.7;
    float3 w = float3(sin(q.y * 1.3 - t * 1.3) + cos(q.z * 1.7),
                      sin(q.z * 1.1 + t) + cos(q.x * 1.9),
                      sin(q.x * 1.5) + cos(q.y * 1.2 + t * 1.1));
    return v + 0.5 * w.yzx;
}

static float3 onSphere(uint id, uint salt) {
    float z = rnd(id * 3u + salt) * 2.0 - 1.0;
    float a = rnd(id * 3u + salt + 1u) * 6.28318;
    float r = sqrt(max(0.0, 1.0 - z * z));
    return float3(r * cos(a), z, r * sin(a));
}

static float3 inCube(uint id, uint salt) {
    return float3(rnd(id + salt), rnd(id + salt + 1u), rnd(id + salt + 2u)) - 0.5;
}

/// Where source `k` of the Murmuration sits: a slow orbit on a sphere.
static float3 sourcePos(int k, SU u) {
    float fk = float(k);
    float a = fk * 2.39996 + u.time * (0.05 + 0.013 * fk) + u.seed * 6.0;
    float y = sin(fk * 1.7 + u.time * 0.04 + u.seed * 9.0) * 0.75;
    float r = sqrt(max(0.0, 1.0 - y * y));
    return float3(cos(a) * r, y, sin(a) * r) * 0.95;
}

kernel void k_particles(device Particle* ps [[buffer(0)]],
                        constant SU& u [[buffer(1)]],
                        const device float* sp [[buffer(2)]],
                        uint id [[thread_position_in_grid]]) {
    Particle p = ps[id];
    float seed = rnd(id);
    float seed2 = rnd(id + 7919u);
    float dt = u.dt;
    int variant = int(u.variant);
    float3 x = p.pos.xyz;
    float3 v = p.vel.xyz;
    float life = p.pos.w - dt * (0.045 + 0.06 * seed2);
    float band = bandAt(sp, seed * 0.92);
    uint salt = uint(u.time * 60.0) * 2654435761u;

    bool dead = life <= 0.0 || dot(x, x) > 300.0 || !all(isfinite(x));

    if (variant == 0) {
        // Murmuration: nine sources, one per band, each bleeding a ribbon of
        // tracers into a flow field. Tracers have no inertia, which is what
        // keeps the ribbons thin instead of smearing into fog.
        int k = int(id % 9u);
        band = bandAt(sp, (float(k) + 0.5) / 9.0 * 0.9);
        if (dead) {
            x = sourcePos(k, u) + onSphere(id, salt) * 0.10 * rnd(id + salt + 5u);
            life = 0.75 + 0.25 * rnd(id + salt + 3u);
        }
        float r = length(x) + 1e-4;
        float3 n = x / r;
        v = flow(x * 1.15 + u.seed * 9.0, u.time * 0.24) * (0.20 + 0.55 * u.mid + 0.35 * u.level);
        v += cross(float3(0.0, 1.0, 0.0), x) * 0.22;
        v -= n * (r - 1.0) * 1.1;
        v += n * u.beat * 1.7 * band;
        x += v * dt;
    } else if (variant == 1) {
        // Singularity: an accretion disk with jets thrown out on the beat.
        if (dead || length(x) < 0.06) {
            float r0 = 0.22 + 1.45 * pow(rnd(id + salt + 1u), 1.6);
            float arm = floor(rnd(id + salt) * 3.0) * 2.0944;
            float a0 = arm + log(r0 + 0.2) * 3.2 + (rnd(id + salt + 4u) - 0.5) * 0.45 + u.seed * 6.0;
            x = float3(cos(a0) * r0, (rnd(id + salt + 2u) - 0.5) * 0.035 * (0.3 + r0), sin(a0) * r0);
            v = float3(-sin(a0), 0.0, cos(a0)) * sqrt(0.9 / r0);
            life = 0.5 + 0.5 * rnd(id + salt + 3u);
        }
        float r = length(x) + 0.05;
        float3 a = -x / (r * r * r) * (0.9 + 0.35 * u.bass);
        a.y -= x.y * 6.0;
        a += flow(x * 2.6 + u.seed * 9.0, u.time * 0.4) * (0.01 + 0.12 * u.treb + 0.05 * band);
        if (r < 0.5) {
            a.y += (seed2 > 0.5 ? 1.0 : -1.0) * u.beat * 30.0 * (0.5 - r);
        }
        // The beat also kicks a ring of the disk outward: a ripple that
        // travels to the rim.
        float ring = (r - 0.55) / 0.22;
        a.xz += normalize(x.xz + 1e-4) * u.beat * 5.0 * exp(-ring * ring);
        v += a * dt;
        v *= exp(-0.04 * dt);
        x += v * dt;
    } else {
        // Strange attractors: the particles are tracers in the system's flow.
        float3 f;
        float S;
        float speed;
        if (variant == 2) {
            // Thomas
            S = 0.36; speed = 2.4;
            float3 q = x / S;
            float b = 0.2082 - 0.022 * u.bass;
            f = sin(q.yzx) - b * q;
            if (dead) { x = inCube(id, salt) * 6.0 * S; }
        } else if (variant == 3) {
            // Lorenz, stood upright: its z runs up the screen.
            S = 0.058; speed = 0.12;
            float3 q = float3(x.x, x.z, x.y) / S + float3(0.0, 0.0, 25.0);
            float rho = 28.0 + 5.0 * u.bass;
            float3 g = float3(10.0 * (q.y - q.x), q.x * (rho - q.z) - q.y, q.x * q.y - 2.6667 * q.z);
            f = float3(g.x, g.z, g.y);
            if (dead) { x = inCube(id, salt) * 0.9; }
        } else {
            // Halvorsen
            S = 0.115; speed = 0.16;
            float3 q = x / S + float3(-2.2, -2.2, -2.2);
            float a1 = 1.89 - 0.25 * u.bass;
            f = float3(-a1 * q.x - 4.0 * q.y - 4.0 * q.z - q.y * q.y,
                       -a1 * q.y - 4.0 * q.z - 4.0 * q.x - q.z * q.z,
                       -a1 * q.z - 4.0 * q.x - 4.0 * q.y - q.x * q.x);
            if (dead) { x = inCube(id, salt) * 3.0 * S; }
        }
        if (dead) { life = 0.3 + 0.7 * rnd(id + salt + 3u); }
        v = f * S * speed * (0.7 + 0.9 * u.level + 0.6 * band);
        x += v * dt;
        x += flow(x * 5.0, u.time) * dt * (0.004 + 0.05 * u.treb * seed2);
        x += normalize(x + 1e-4) * u.beat * dt * 0.35 * band;
    }

    if (!all(isfinite(x)) || !all(isfinite(v))) {
        x = float3(0.0);
        v = float3(0.0);
        life = 0.0;
    }
    p.pos = float4(x, life);
    p.vel = float4(v, band);
    ps[id] = p;
}

/// Projects every particle and adds its light to a fixed-point grid with
/// atomic adds. A million one-pixel splats cost a fraction of what a million
/// point sprites do, and the cost no longer depends on how big they look.
/// Depth of field is stochastic: each particle is pushed off its true spot
/// by a fixed random offset that grows with its distance from the focal plane.
kernel void k_splat(const device Particle* ps [[buffer(0)]],
                    constant SU& u [[buffer(1)]],
                    device atomic_uint* grid [[buffer(2)]],
                    uint id [[thread_position_in_grid]]) {
    Particle p = ps[id];
    float seed = rnd(id);
    float seed2 = rnd(id + 7919u);
    int variant = int(u.variant);

    float yaw = u.time * 0.085 + u.seed * 6.28318;
    float pitch = 0.42 + 0.30 * sin(u.time * 0.05 + u.seed * 3.0);
    if (variant == 1) { pitch = 0.50 + 0.26 * sin(u.time * 0.045 + u.seed * 3.0); }
    float3 x = p.pos.xyz;
    x.xz = rot2(x.xz, yaw);
    x.yz = rot2(x.yz, pitch);

    float dist = (variant == 1 ? 3.0 : 3.4) - 0.22 * u.bass;
    float3 c = float3(x.x, x.y, x.z + dist);
    if (!(c.z >= 0.2) || !all(isfinite(c)) || p.pos.w <= 0.0) { return; }

    float f = 1.75;
    float2 ndc = float2(c.x * f / u.aspect, c.y * f) / c.z;
    float coc = abs(c.z - dist) * u.dof;
    float ang = rnd(id + 101u) * 6.28318;
    float rad = sqrt(rnd(id + 211u)) * coc;
    ndc += float2(cos(ang) / u.aspect, sin(ang)) * rad;

    float2 pix = (ndc * float2(0.5, -0.5) + 0.5) * float2(u.gridW, u.gridH) - 0.5;
    int2 i0 = int2(floor(pix));
    float2 fr = pix - float2(i0);
    int W = int(u.gridW);
    int H = int(u.gridH);
    if (i0.x < -1 || i0.y < -1 || i0.x >= W || i0.y >= H) { return; }

    float heat = length(p.vel.xyz);
    float band = p.vel.w;
    float star = step(0.994, seed2);
    float r = length(p.pos.xyz);
    float t;
    if (variant == 0) {
        t = float(id % 9u) / 9.0 * 0.85 + heat * 0.05 + u.time * 0.006;
    } else if (variant == 1) {
        t = 0.08 + clamp(r * 0.36, 0.0, 0.62) + seed * 0.05 + heat * 0.06;
    } else {
        t = seed * 0.16 + heat * 0.22 + r * 0.10 + u.time * 0.008;
    }
    float3 col = pal(t, u.hue);
    float bright = 0.30 + (variant == 0 ? 1.5 : 2.6) * band * band + 0.8 * u.beat * step(0.6, seed) + star * (4.0 + 12.0 * u.treb);
    if (variant == 1) {
        // The inner disk runs hot.
        // The inner disk runs hot, but it is also where the particles
        // crowd, so it needs far less light each than the rim does.
        bright *= 0.16 + 1.5 * smoothstep(0.25, 1.3, r);
        col = mix(col, float3(1.0, 0.86, 0.66), exp(-r * 3.0) * 0.8);
    }
    // Ease in and out at the ends of a life so respawns never pop, and let
    // near particles count for more, as light does.
    bright *= smoothstep(0.0, 0.05, p.pos.w);
    float near = dist / c.z;
    bright *= clamp(near * near, 0.25, 3.0);
    float3 e = col * (u.gain * bright * u.fade * 16384.0);

    for (int j = 0; j < 4; j++) {
        int2 q = i0 + int2(j & 1, j >> 1);
        if (q.x < 0 || q.y < 0 || q.x >= W || q.y >= H) { continue; }
        float w = ((j & 1) == 1 ? fr.x : 1.0 - fr.x) * ((j >> 1) == 1 ? fr.y : 1.0 - fr.y);
        uint base = uint(q.y * W + q.x) * 4u;
        atomic_fetch_add_explicit(&grid[base], uint(e.r * w), memory_order_relaxed);
        atomic_fetch_add_explicit(&grid[base + 1u], uint(e.g * w), memory_order_relaxed);
        atomic_fetch_add_explicit(&grid[base + 2u], uint(e.b * w), memory_order_relaxed);
    }
}

static float3 gridAt(const device uint* grid, int2 q, int W, int H) {
    q = clamp(q, int2(0), int2(W - 1, H - 1));
    uint base = uint(q.y * W + q.x) * 4u;
    return float3(float(grid[base]), float(grid[base + 1u]), float(grid[base + 2u]));
}

/// Adds the splat grid to the picture, scaling it up when the window is
/// larger than the grid.
fragment float4 f_splat(FS in [[stage_in]],
                        constant SU& u [[buffer(0)]],
                        const device uint* grid [[buffer(1)]]) {
    int W = int(u.gridW);
    int H = int(u.gridH);
    float2 g = in.uv * float2(u.gridW, u.gridH) - 0.5;
    int2 i0 = int2(floor(g));
    float2 fr = g - float2(i0);
    float3 c = mix(mix(gridAt(grid, i0, W, H), gridAt(grid, i0 + int2(1, 0), W, H), fr.x),
                   mix(gridAt(grid, i0 + int2(0, 1), W, H), gridAt(grid, i0 + int2(1, 1), W, H), fr.x), fr.y);
    return float4(c / 16384.0, 1.0);
}

// --- Fluid ---

constexpr sampler lin(address::clamp_to_edge, filter::linear);

/// What the music pushes into the fluid at `p` (aspect-corrected, origin at
/// the centre): a force and a dye colour, both per unit time.
static void emitters(float2 p, SU u, const device float* sp, thread float2& force, thread float3& dye) {
    force = float2(0.0);
    dye = float3(0.0);
    int variant = int(u.variant);
    if (variant == 0) {
        // A ring of jets, one per band, aimed inward and across each other.
        const int n = 7;
        for (int i = 0; i < n; i++) {
            float fi = float(i);
            float band = bandAt(sp, (fi + 0.4) / float(n) * 0.86);
            // Fourth power: a jet is nearly off until its band is really
            // sounding, so the dye arrives in strokes rather than a steady
            // flood, and each stroke is drawn by a nozzle that keeps moving.
            float e = band * band * band * band * (1.6 + 1.2 * fi / float(n));
            float a = fi * 6.28318 / float(n) + u.time * (0.45 + 0.05 * fi) + u.seed * 6.0;
            float2 c = float2(cos(a), sin(a)) * (0.27 + 0.11 * sin(u.time * 0.61 + fi * 1.9));
            float2 dir = rot2(-normalize(c), (fmod(fi, 2.0) < 1.0 ? 1.0 : -1.0) * (0.75 + 0.3 * sin(u.time * 0.17 + fi)));
            float2 d = p - c;
            float g = exp(-dot(d, d) / (0.00035 + 0.0005 * e));
            force += dir * g * e * 40.0;
            dye += pal(fi / float(n) * 0.45 + u.time * 0.05, u.hue) * g * e * 26.0;
        }
        // The beat twists the middle. A twist survives the pressure solve,
        // where an outward shove would only blow a flat disc of dye.
        float r = length(p);
        float g = exp(-r * r / 0.03);
        force += float2(-p.y, p.x) / (r + 0.05) * g * u.beat * 14.0 * sign(sin(u.time * 0.23));
    } else {
        // Jets along the bottom, low notes on the left: an organ of smoke.
        const int n = 9;
        for (int i = 0; i < n; i++) {
            float fi = float(i);
            float band = bandAt(sp, (fi + 0.3) / float(n) * 0.88);
            float e = band * band * band * band * (1.6 + 1.6 * fi / float(n));
            float2 c = float2(((fi + 0.5) / float(n) - 0.5) * u.aspect * 0.86
                              + 0.035 * sin(u.time * 1.3 + fi * 2.7), 0.46);
            float2 dir = normalize(float2(0.35 * sin(u.time * 0.31 + fi * 2.1), -1.0));
            float2 d = p - c;
            float g = exp(-dot(d, d) / (0.0003 + 0.00045 * e));
            force += dir * g * e * 52.0;
            dye += pal(fi / float(n) * 0.45 + u.time * 0.05, u.hue) * g * e * 28.0;
        }
        float2 d = p - float2(0.0, 0.1);
        force += float2(sign(sin(u.time * 0.9)), -0.2) * exp(-dot(d, d) / 0.05) * u.beat * 7.0;
    }
}

kernel void k_fluid_advect(texture2d<float, access::sample> vel [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant SU& u [[buffer(0)]],
                           const device float* sp [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    float2 size = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float2 v = vel.sample(lin, uv).xy;
    float2 back = uv - u.dt * v * float2(1.0 / u.aspect, 1.0);
    float2 nv = vel.sample(lin, back).xy * exp(-0.22 * u.dt);
    float2 force;
    float3 dye;
    emitters((uv - 0.5) * float2(u.aspect, 1.0), u, sp, force, dye);
    nv += force * u.dt;
    dst.write(float4(nv, 0.0, 1.0), gid);
}

static float2 velAt(texture2d<float, access::read> t, int2 p) {
    int2 m = int2(t.get_width() - 1, t.get_height() - 1);
    return t.read(uint2(clamp(p, int2(0), m))).xy;
}

static float valAt(texture2d<float, access::read> t, int2 p) {
    int2 m = int2(t.get_width() - 1, t.get_height() - 1);
    return t.read(uint2(clamp(p, int2(0), m))).x;
}

kernel void k_fluid_curl(texture2d<float, access::read> vel [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    int2 p = int2(gid);
    float c = velAt(vel, p + int2(1, 0)).y - velAt(vel, p - int2(1, 0)).y
            - velAt(vel, p + int2(0, 1)).x + velAt(vel, p - int2(0, 1)).x;
    dst.write(float4(0.5 * c, 0.0, 0.0, 1.0), gid);
}

/// Vorticity confinement: puts back the small swirls the grid smooths away.
kernel void k_fluid_vorticity(texture2d<float, access::read> vel [[texture(0)]],
                              texture2d<float, access::read> curl [[texture(1)]],
                              texture2d<float, access::write> dst [[texture(2)]],
                              constant SU& u [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    int2 p = int2(gid);
    float l = abs(valAt(curl, p - int2(1, 0)));
    float r = abs(valAt(curl, p + int2(1, 0)));
    float b = abs(valAt(curl, p - int2(0, 1)));
    float t = abs(valAt(curl, p + int2(0, 1)));
    float c = valAt(curl, p);
    float2 g = 0.5 * float2(r - l, t - b);
    g /= length(g) + 1e-4;
    float2 f = float2(g.y, -g.x) * c * 3.5;
    float2 v = velAt(vel, p) + f * u.dt;
    dst.write(float4(clamp(v, float2(-6.0), float2(6.0)), 0.0, 1.0), gid);
}

kernel void k_fluid_divergence(texture2d<float, access::read> vel [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    int2 p = int2(gid);
    int2 m = int2(vel.get_width() - 1, vel.get_height() - 1);
    float2 l = velAt(vel, p - int2(1, 0));
    float2 r = velAt(vel, p + int2(1, 0));
    float2 b = velAt(vel, p - int2(0, 1));
    float2 t = velAt(vel, p + int2(0, 1));
    // Walls: the flow turns back at the edges instead of leaving the frame.
    float2 c = velAt(vel, p);
    if (p.x == 0) { l.x = -c.x; }
    if (p.x == m.x) { r.x = -c.x; }
    if (p.y == 0) { b.y = -c.y; }
    if (p.y == m.y) { t.y = -c.y; }
    dst.write(float4(0.5 * (r.x - l.x + t.y - b.y), 0.0, 0.0, 1.0), gid);
}

kernel void k_fluid_pressure(texture2d<float, access::read> pr [[texture(0)]],
                             texture2d<float, access::read> dv [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int2 p = int2(gid);
    float s = valAt(pr, p - int2(1, 0)) + valAt(pr, p + int2(1, 0))
            + valAt(pr, p - int2(0, 1)) + valAt(pr, p + int2(0, 1));
    dst.write(float4((s - valAt(dv, p)) * 0.25, 0.0, 0.0, 1.0), gid);
}

kernel void k_fluid_gradient(texture2d<float, access::read> vel [[texture(0)]],
                             texture2d<float, access::read> pr [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int2 p = int2(gid);
    float2 g = 0.5 * float2(valAt(pr, p + int2(1, 0)) - valAt(pr, p - int2(1, 0)),
                            valAt(pr, p + int2(0, 1)) - valAt(pr, p - int2(0, 1)));
    dst.write(float4(velAt(vel, p) - g, 0.0, 1.0), gid);
}

kernel void k_fluid_dye(texture2d<float, access::sample> vel [[texture(0)]],
                        texture2d<float, access::sample> src [[texture(1)]],
                        texture2d<float, access::write> dst [[texture(2)]],
                        constant SU& u [[buffer(0)]],
                        const device float* sp [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    float2 size = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float2 v = vel.sample(lin, uv).xy;
    float2 back = uv - u.dt * v * float2(1.0 / u.aspect, 1.0);
    float3 c = src.sample(lin, back).rgb * exp(-1.5 * u.dt);
    float2 force;
    float3 dye;
    emitters((uv - 0.5) * float2(u.aspect, 1.0), u, sp, force, dye);
    c += dye * u.dt;
    // Roll bright regions off smoothly, keeping the hue.
    float m = max(c.r, max(c.g, c.b));
    c *= 1.0 / (1.0 + max(0.0, m - 3.0) * 0.5);
    dst.write(float4(c, 1.0), gid);
}

/// The dye as light in dark water: thin where it is thin, and brightest
/// along its edges, where the folds of the flow stack up.
fragment float4 f_fluid(FS in [[stage_in]],
                        constant SU& u [[buffer(0)]],
                        texture2d<float> dye [[texture(0)]]) {
    float2 px = 1.5 / float2(dye.get_width(), dye.get_height());
    float3 c = dye.sample(lin, in.uv).rgb;
    float3 w = float3(0.35, 0.45, 0.20);
    float hl = dot(dye.sample(lin, in.uv - float2(px.x, 0.0)).rgb, w);
    float hr = dot(dye.sample(lin, in.uv + float2(px.x, 0.0)).rgb, w);
    float hb = dot(dye.sample(lin, in.uv - float2(0.0, px.y)).rgb, w);
    float ht = dot(dye.sample(lin, in.uv + float2(0.0, px.y)).rgb, w);
    float2 wide = px * 4.0;
    float wl = dot(dye.sample(lin, in.uv - float2(wide.x, 0.0)).rgb, w);
    float wr = dot(dye.sample(lin, in.uv + float2(wide.x, 0.0)).rgb, w);
    float wb = dot(dye.sample(lin, in.uv - float2(0.0, wide.y)).rgb, w);
    float wt = dot(dye.sample(lin, in.uv + float2(0.0, wide.y)).rgb, w);
    float lum = dot(c, w);
    float fine = length(float2(hr - hl, ht - hb));
    float soft = length(float2(wr - wl, wt - wb));
    float3 hue = c / (lum + 0.03);
    // The body of the dye stays a thin veil; its folds carry the light.
    float3 col = c * 0.16;
    col += hue * (1.0 - exp(-fine * 5.0)) * 0.95;
    col += hue * (1.0 - exp(-soft * 2.0)) * 0.35;
    col += float3(0.0006, 0.0010, 0.003) * (1.0 - in.uv.y * 0.6);
    return float4(col, u.fade);
}

// --- Deep Field ---

constexpr sampler rep(address::repeat, filter::linear);

/// Stars in depth, flown through. Each layer is a sheet of stars at one
/// distance that comes toward the camera and wraps back to the far end with
/// a new set. A pixel looks along a short stretch of depth (`dz`, the
/// exposure), which is what draws the stars out into streaks at speed.
static float3 warpStars(float2 p, SU u, float dz, float px) {
    float3 acc = float3(0.0);
    const int N = 24;
    const float G = 8.0;
    for (int i = 0; i < N; i++) {
        float fi = float(i);
        float ph = (fi + 0.5) / float(N) - u.travel * 0.030;
        float zf = fract(ph);
        float cyc = floor(ph);
        float z = 0.05 + zf;
        float2 off = float2(hash21(float2(fi * 3.1, cyc * 1.7 + 0.3)),
                            hash21(float2(cyc * 2.3 + 5.0, fi * 1.3))) * 64.0;
        float2 w = p * z * G + off;
        float2 cell = floor(w);
        float h = hash21(cell + fi * 17.31);
        if (h > 0.46) { continue; }
        float m = hash21(cell * 1.7 + 3.3 + fi);
        float2 s = cell + 0.3 + 0.4 * float2(hash21(cell + 1.37), hash21(cell.yx + 9.11));
        float2 seg = p * G * dz;
        float sl = length(seg);
        seg *= min(1.0, 0.28 / max(sl, 1e-6));
        float2 d = s - w;
        float t = clamp(dot(d, seg) / max(dot(seg, seg), 1e-9), 0.0, 1.0);
        float2 dd = (d - seg * t) / (z * G);
        float dist = length(dd);
        float big = pow(m, 9.0);
        float r = max(0.0008, px * 0.75) * (1.0 + 1.2 * big);
        // The tail narrows to nothing.
        float rt = r * (1.0 - 0.65 * t);
        float core = exp(-dist * dist / (rt * rt));
        float streakPx = min(sl, 0.28) / (z * G) / r;
        float bright = (0.30 + 7.0 * big + 0.6 * m * m) * (1.0 - 0.8 * t) / (1.0 + 0.12 * streakPx);
        bright *= smoothstep(1.0, 0.80, zf) * smoothstep(0.0, 0.05, zf);
        bright *= 0.75 + 0.5 * u.treb * sin(u.time * (3.0 + 6.0 * h) + m * 40.0);
        bright *= 1.0 + 1.5 * u.beat * step(0.86, m);
        float temp = hash21(cell + 31.7);
        float3 tint = mix(float3(0.62, 0.76, 1.0), float3(1.0, 0.82, 0.62), temp * temp);
        tint = mix(tint, float3(1.0), 0.45);
        // At speed a streak runs from a blue-white head to a warm tail.
        float longness = smoothstep(2.0, 14.0, streakPx);
        tint = mix(tint, mix(float3(0.70, 0.84, 1.0), float3(1.0, 0.62, 0.40), t), longness * 0.75);
        // The brightest stars carry a soft halo and a four-point glint
        // while they are still points.
        float still = 1.0 - smoothstep(1.0, 6.0, streakPx);
        float halo = big * still * 0.05 / (1.0 + dist * dist / (r * r * 14.0));
        float2 ad = abs(dd) / r;
        float glint = big * big * still * 0.45 * (exp(-ad.x * 0.16 - ad.y * 2.2) + exp(-ad.y * 0.16 - ad.x * 2.2));
        acc += tint * (core + halo + glint) * bright;
    }
    return acc;
}

constexpr sampler tri(address::clamp_to_edge, filter::linear, mip_filter::linear);
constexpr sampler mir(address::mirrored_repeat, filter::linear, mip_filter::linear);

/// Deep Field: the view ahead from a ship at speed. Speed is carried by the
/// stars alone: they stream out of the point the ship is heading for and
/// stretch into streaks as the bass pushes it faster. Everything else is too
/// far away to rush. The galaxies are Hubble photographs (a 6 by 4 sheet,
/// `DeepFieldGalaxies`), kept small; each takes minutes to drift outward and
/// grow a little, and none is ever reached. Behind them is a Hubble deep
/// field, drawn twice at different magnifications that cross-fade, so the
/// far sky creeps closer without ever arriving.
fragment float4 f_nebula(FS in [[stage_in]],
                         constant SU& u [[buffer(0)]],
                         const device float* sp [[buffer(1)]],
                         texture3d<float> nz [[texture(0)]],
                         texture2d<float> sheet [[texture(1)]],
                         texture2d<float> sky [[texture(2)]]) {
    float2 p = (in.uv - 0.5) * float2(u.aspect, -1.0);
    float px = 1.0 / min(u.resY, 810.0);
    // The heading wanders, so the flight banks instead of running on rails.
    float2 heading = float2(0.16 * sin(u.time * 0.050 + u.seed * 6.0),
                            0.09 * sin(u.time * 0.037 + u.seed * 11.0));
    float roll = 0.25 * sin(u.time * 0.031 + u.seed * 4.0);
    float2 v = rot2(p - heading, roll);

    float3 col = float3(0.0004, 0.0006, 0.0016);
    for (int k = 0; k < 2; k++) {
        float ph = fract(u.travel * 0.0010 + 0.5 * float(k));
        float mag = 0.56 * exp2(-ph);
        float2 suv = v * mag + float2(0.31 + 0.47 * float(k), 0.63) + u.seed * 2.0
                   + floor(u.travel * 0.0010 + 0.5 * float(k)) * 0.377;
        float w = sin(3.14159 * ph);
        float3 far = sky.sample(mir, suv, level(0.3)).rgb;
        col += max(far - 0.012, 0.0) * w * w * 0.30;
    }

    // Galaxies, far to near.
    const int NG = 6;
    const float tiles = 23.0;
    for (int i = 0; i < NG; i++) {
        float fi = float(i);
        float ph = (fi + 0.5) / float(NG) - u.travel * 0.0022;
        float zf = fract(ph);
        float cyc = floor(ph);
        float id = hash21(float2(fi * 1.9 + 0.7, cyc * 3.1 + u.seed * 20.0));
        float z = 0.85 + zf * 1.5;
        float ang = hash21(float2(cyc + 3.0, fi + 11.0)) * 6.28318;
        float rad = 0.22 + 0.62 * hash21(float2(fi + 21.0, cyc + 1.0));
        float2 c = float2(cos(ang), sin(ang) * 0.62) * rad / z;
        float size = (0.09 + 0.11 * fract(id * 7.7)) / z;
        float2 q = (v - c) / size;
        if (max(abs(q.x), abs(q.y)) > 1.0) { continue; }
        q = rot2(q, id * 6.28318 + u.time * 0.008 * (fract(id * 2.3) > 0.5 ? 1.0 : -1.0));
        if (max(abs(q.x), abs(q.y)) > 0.995) { continue; }
        if (fract(id * 5.9) > 0.5) { q.x = -q.x; }
        float tile = floor(fract(id * 13.1 + fi * 0.37) * tiles);
        float2 cell = float2(fmod(tile, 6.0), floor(tile / 6.0));
        float2 tuv = (cell + clamp(q * 0.5 + 0.5, 0.002, 0.998)) / float2(6.0, 4.0);
        float lod = max(0.0, log2(640.0 * px / (2.0 * size)));
        float3 g = sheet.sample(tri, tuv, level(lod)).rgb;
        float lum = dot(g, float3(0.3, 0.5, 0.2));
        float fade = smoothstep(1.0, 0.90, zf) * smoothstep(0.0, 0.12, zf);
        // The bass swells the light of the whole galaxy; the beat flares
        // only what is already bright, the core and the star-forming knots.
        col += g * fade * (0.42 + 0.14 * u.bass + 0.5 * u.beat * lum * lum + 0.10 * u.mid * lum);
    }

    float dz = 0.0006 + 0.006 * u.level * u.level + 0.050 * u.bass * u.bass * u.bass + 0.010 * u.beat;
    col += warpStars(v, u, dz, px) * 1.2;
    return float4(col, 1.0);
}

// --- Cathedral ---

static float apollonian(float3 p, float s, thread float4& trap) {
    float scale = 1.0;
    trap = float4(1000.0);
    for (int i = 0; i < 8; i++) {
        p = -1.0 + 2.0 * fract(0.5 * p + 0.5);
        float r2 = dot(p, p);
        trap = min(trap, float4(abs(p), r2));
        float k = s / r2;
        p *= k;
        scale *= k;
    }
    return 0.25 * abs(p.y) / scale;
}

static float2 naveXY(float z, float seed) {
    return float2(0.5 + 0.18 * sin(z * 0.35 + seed * 6.0), 0.5 + 0.14 * cos(z * 0.27));
}

/// The lattice with a corridor bored through it, so the camera always has
/// clear air ahead and carved stone on every side.
static float cathedral(float3 p, float s, float seed, thread float4& trap) {
    float d = apollonian(p, s, trap);
    float bore = 0.34 - length(p.xy - naveXY(p.z, seed));
    return max(d, bore);
}

/// Cathedral: a flight down a corridor cut through an endless
/// inverted-sphere lattice, lit by a lamp at the camera. The stone carries
/// the spectrum: each band lights the ribs whose orbit trap falls in it.
fragment float4 f_fractal(FS in [[stage_in]],
                          constant SU& u [[buffer(0)]],
                          const device float* sp [[buffer(1)]]) {
    float2 p = (in.uv - 0.5) * float2(u.aspect, -1.0) * 2.0;
    float z0 = u.travel * 0.16 + u.seed * 40.0;
    float s = 1.14 + 0.30 * smoothstep(-0.4, 0.4, cos(0.21 * z0)) + 0.010 * u.bass;

    float3 ro = float3(naveXY(z0, u.seed), z0);
    float3 ta = float3(naveXY(z0 + 0.9, u.seed), z0 + 0.9);
    float3 cw = normalize(ta - ro);
    float roll = 0.35 * sin(z0 * 0.23);
    float3 cp = float3(sin(roll), cos(roll), 0.0);
    float3 cu = normalize(cross(cw, cp));
    float3 cv = normalize(cross(cu, cw));
    float3 rd = normalize(p.x * cu + p.y * cv + 1.5 * cw);

    float4 trap;
    float t = 0.02 + hash21(in.position.xy) * 0.01;
    float glow = 0.0;
    bool hit = false;
    for (int i = 0; i < 96; i++) {
        float h = cathedral(ro + rd * t, s, u.seed, trap);
        glow += exp(-h * 30.0) * exp(-t * 0.5);
        if (h < 0.0012 * t) { hit = true; break; }
        if (t > 14.0) { break; }
        t += h * 0.9;
    }

    float3 fogCol = pal(0.62, u.hue) * 0.012;
    float3 col = fogCol;
    if (hit) {
        float3 pos = ro + rd * t;
        float e = 0.0008 * t + 0.0002;
        float4 tr2;
        float2 k = float2(1.0, -1.0);
        float3 n = normalize(k.xyy * cathedral(pos + k.xyy * e, s, u.seed, tr2)
                           + k.yyx * cathedral(pos + k.yyx * e, s, u.seed, tr2)
                           + k.yxy * cathedral(pos + k.yxy * e, s, u.seed, tr2)
                           + k.xxx * cathedral(pos + k.xxx * e, s, u.seed, tr2));
        float ao = pow(clamp(trap.w * 2.2, 0.0, 1.0), 1.3);
        float facing = clamp(dot(n, -rd), 0.0, 1.0);
        // The lamp flies ahead of the camera down the corridor, so the way
        // forward is the bright thing and the walls beside the camera fall
        // back into silhouette.
        float3 lampPos = float3(naveXY(z0 + 1.5, u.seed), z0 + 1.5);
        float3 toLamp = lampPos - pos;
        float ld = length(toLamp);
        float lambert = clamp(dot(n, toLamp / ld), 0.0, 1.0);
        float lamp = (0.12 + 0.88 * lambert) * 1.15 / (1.0 + ld * ld * 1.6)
                   + (0.25 + 0.75 * facing) * 0.22 * smoothstep(0.1, 0.9, t) / (1.0 + t * t * 0.55);
        float rim = pow(1.0 - facing, 3.0);

        float3 stone = mix(float3(0.26, 0.23, 0.21), pal(0.1 + trap.x * 0.7, u.hue) * 0.6, 0.45);
        float3 lit = stone * lamp * float3(1.0, 0.90, 0.78) * ao;
        lit += stone * pal(0.7, u.hue) * 0.05 * ao;

        // The spectrum, written onto the stone.
        float band = bandAt(sp, clamp(trap.x * 1.15, 0.0, 0.95));
        float line = smoothstep(0.80, 1.0, cos(trap.z * 34.0 + trap.x * 11.0) * 0.5 + 0.5);
        float3 neon = pal(0.25 + trap.x * 0.9 + u.time * 0.01, u.hue + 0.5);
        lit += neon * band * band * (0.10 + 2.6 * line) * ao * smoothstep(0.15, 1.0, t);
        lit += neon * u.beat * 1.2 * smoothstep(0.03, 0.0, abs(trap.w - 0.25)) * ao;
        lit += rim * pal(0.8, u.hue) * 0.10 * ao;

        col = mix(fogCol, lit, exp(-0.30 * t));
    }
    col += pal(0.45 + u.time * 0.004, u.hue) * min(glow, 30.0) * 0.0028 * (0.4 + 1.2 * u.bass);
    return float4(col, 1.0);
}

fragment float4 f_blit(FS in [[stage_in]],
                       constant SU& u [[buffer(0)]],
                       texture2d<float> tex [[texture(0)]]) {
    return float4(tex.sample(lin, in.uv).rgb, u.fade);
}
"""
