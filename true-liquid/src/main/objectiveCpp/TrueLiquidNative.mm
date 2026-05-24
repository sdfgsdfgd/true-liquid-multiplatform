#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <simd/simd.h>
#import <unistd.h>

static NSString * const TrueLiquidContainerId = @"local.trueliquid.container";
static NSString * const TrueLiquidGlassId = @"local.trueliquid.nativeGlass";
static NSString * const TrueLiquidCaptureId = @"local.trueliquid.capture";
static NSString * const TrueLiquidTintId = @"local.trueliquid.tint";
static char TrueLiquidCoordinatorKey;
static BOOL TrueLiquidInstrumentationEnabled = NO;
static BOOL TrueLiquidWindowCaptureVisible = NO;
static BOOL TrueLiquidNativePositionDragEnabled = NO;
static FILE *TrueLiquidInstrumentationFile = NULL;
static dispatch_queue_t TrueLiquidInstrumentationQueue;
static mach_timebase_info_data_t TrueLiquidTimebase;

typedef NS_ENUM(NSInteger, TrueLiquidModeNative) {
    TrueLiquidModeAuto = 0,
    TrueLiquidModeNativeGlass = 1,
    TrueLiquidModeCaptureShader = 2,
    TrueLiquidModeVisualEffect = 3,
};

typedef struct {
    float glassAlpha;
    float tintAlpha;
    float refraction;
    float curve;
    float dispersion;
    float frost;
    float blur;
    float saturation;
    float contrast;
    float luminanceClamp;
    float edge;
    float depth;
    float innerShadow;
    float outerShadow;
    float cornerRadius;
    float captureScale;
    int fps;
    int mode;
} TrueLiquidNativeStyle;

typedef struct {
    vector_float2 size;
    vector_float2 uvOrigin;
    vector_float2 uvScale;
    float glassAlpha;
    float tintAlpha;
    float refraction;
    float curve;
    float dispersion;
    float frost;
    float blur;
    float saturation;
    float contrast;
    float luminanceClamp;
    float edge;
    float depth;
    float innerShadow;
    float cornerRadius;
    float settled;
    float edgeDiagnostic;
} TrueLiquidUniforms;

static float ClampFloat(double value, double minValue, double maxValue) {
    return (float)fmin(fmax(value, minValue), maxValue);
}

static BOOL EnvFlagEnabled(const char *name) {
    const char *value = getenv(name);
    if (!value || value[0] == '\0') return NO;
    return value[0] == '1' || value[0] == 't' || value[0] == 'T' || value[0] == 'y' || value[0] == 'Y';
}

static TrueLiquidNativeStyle MakeStyle(
    double glassAlpha,
    double tintAlpha,
    double refraction,
    double curve,
    double dispersion,
    double frost,
    double blur,
    double saturation,
    double contrast,
    double luminanceClamp,
    double edge,
    double depth,
    double innerShadow,
    double outerShadow,
    double cornerRadius,
    double captureScale,
    int fps,
    int mode
) {
    TrueLiquidNativeStyle style;
    style.glassAlpha = ClampFloat(glassAlpha, 0.0, 1.0);
    style.tintAlpha = ClampFloat(tintAlpha, 0.0, 1.0);
    style.refraction = ClampFloat(refraction, 0.0, 1.0);
    style.curve = ClampFloat(curve, 0.0, 1.0);
    style.dispersion = ClampFloat(dispersion, 0.0, 1.0);
    style.frost = ClampFloat(frost, 0.0, 1.0);
    style.blur = ClampFloat(blur, 0.0, 1.0);
    style.saturation = ClampFloat(saturation, 0.0, 2.0);
    style.contrast = ClampFloat(contrast, -1.0, 1.0);
    style.luminanceClamp = ClampFloat(luminanceClamp, 0.0, 1.0);
    style.edge = ClampFloat(edge, 0.0, 1.0);
    style.depth = ClampFloat(depth, 0.0, 1.0);
    style.innerShadow = ClampFloat(innerShadow, 0.0, 1.0);
    style.outerShadow = ClampFloat(outerShadow, 0.0, 1.0);
    style.cornerRadius = ClampFloat(cornerRadius, 0.0, 96.0);
    style.captureScale = ClampFloat(captureScale, 0.25, 1.0);
    style.fps = (int)fmin(fmax(fps, 15), 120);
    style.mode = mode;
    return style;
}

static BOOL SupportsScreenCaptureKit(void) {
    if (@available(macOS 12.3, *)) return NSClassFromString(@"SCStream") != nil;
    return NO;
}

static uint64_t TrueLiquidNowNs(void) {
    if (TrueLiquidTimebase.denom == 0) mach_timebase_info(&TrueLiquidTimebase);
    uint64_t now = mach_absolute_time();
    return now * TrueLiquidTimebase.numer / TrueLiquidTimebase.denom;
}

static double TrueLiquidNowMs(void) {
    return (double)TrueLiquidNowNs() / 1000000.0;
}

static double TrueLiquidAgeMs(uint64_t olderNs) {
    uint64_t now = TrueLiquidNowNs();
    if (olderNs == 0 || olderNs > now) return -1.0;
    return (double)(now - olderNs) / 1000000.0;
}

static uint64_t TrueLiquidNormalizeHostTimeNs(uint64_t hostTime) {
    if (hostTime == 0) return 0;
    uint64_t now = TrueLiquidNowNs();
    if (hostTime <= now && now - hostTime < 10000000000ULL) return hostTime;
    if (TrueLiquidTimebase.denom == 0) mach_timebase_info(&TrueLiquidTimebase);
    uint64_t scaled = hostTime * TrueLiquidTimebase.numer / TrueLiquidTimebase.denom;
    if (scaled <= now && now - scaled < 10000000000ULL) return scaled;
    return 0;
}

static NSString *TrueLiquidRectDescription(CGRect rect) {
    return [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height];
}

static void TrueLiquidConfigureInstrumentation(BOOL enabled, const char *path) {
    if (!TrueLiquidInstrumentationQueue) {
        TrueLiquidInstrumentationQueue = dispatch_queue_create("local.trueliquid.instrumentation", DISPATCH_QUEUE_SERIAL);
    }

    dispatch_sync(TrueLiquidInstrumentationQueue, ^{
        if (TrueLiquidInstrumentationFile) {
            fclose(TrueLiquidInstrumentationFile);
            TrueLiquidInstrumentationFile = NULL;
        }
        TrueLiquidInstrumentationEnabled = enabled;
        if (enabled && path && path[0] != '\0') {
            TrueLiquidInstrumentationFile = fopen(path, "a");
            if (TrueLiquidInstrumentationFile) {
                fprintf(TrueLiquidInstrumentationFile, "\n{\"t\":%.3f,\"event\":\"instrumentation-start\"}\n", TrueLiquidNowMs());
                fflush(TrueLiquidInstrumentationFile);
            }
        }
    });
}

static void TrueLiquidLogAtMs(NSString *event, NSString *detail, double tMs) {
    if (!TrueLiquidInstrumentationEnabled || !TrueLiquidInstrumentationFile) return;
    NSString *line = [NSString stringWithFormat:@"{\"t\":%.3f,\"event\":\"%@\"%@}\n",
                      tMs,
                      event,
                      detail.length > 0 ? [NSString stringWithFormat:@",%@", detail] : @""];
    dispatch_async(TrueLiquidInstrumentationQueue, ^{
        if (!TrueLiquidInstrumentationFile) return;
        fputs(line.UTF8String, TrueLiquidInstrumentationFile);
        fflush(TrueLiquidInstrumentationFile);
    });
}

static void TrueLiquidLog(NSString *event, NSString *detail) {
    TrueLiquidLogAtMs(event, detail, TrueLiquidNowMs());
}

static NSString *TrueLiquidShaderSource(void) {
    return @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct U {\n"
    "  float2 size;\n"
    "  float2 uvOrigin;\n"
    "  float2 uvScale;\n"
    "  float glassAlpha;\n"
    "  float tintAlpha;\n"
    "  float refraction;\n"
    "  float curve;\n"
    "  float dispersion;\n"
    "  float frost;\n"
    "  float blur;\n"
    "  float saturation;\n"
    "  float contrast;\n"
    "  float luminanceClamp;\n"
    "  float edge;\n"
    "  float depth;\n"
    "  float innerShadow;\n"
    "  float cornerRadius;\n"
    "  float settled;\n"
    "  float edgeDiagnostic;\n"
    "};\n"
    "struct V { float4 position [[position]]; float2 uv; };\n"
    "vertex V trueLiquidVertex(uint vid [[vertex_id]]) {\n"
    "  float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };\n"
    "  float2 uv[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };\n"
    "  V out; out.position = float4(pos[vid], 0.0, 1.0); out.uv = uv[vid]; return out;\n"
    "}\n"
    "float roundedRectSdf(float2 p, float2 halfSize, float radius) {\n"
    "  float2 q = abs(p) - halfSize + radius;\n"
    "  return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;\n"
    "}\n"
    "float2 roundedRectNormal(float2 p, float2 halfSize, float radius, float sd) {\n"
    "  float dx = roundedRectSdf(p + float2(1.0, 0.0), halfSize, radius) - sd;\n"
    "  float dy = roundedRectSdf(p + float2(0.0, 1.0), halfSize, radius) - sd;\n"
    "  return normalize(float2(dx, dy) + float2(0.0001));\n"
    "}\n"
    "float circleMap(float x) {\n"
    "  x = clamp(x, 0.0, 1.0);\n"
    "  return 1.0 - sqrt(max(0.0, 1.0 - x * x));\n"
    "}\n"
    "float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }\n"
    "float3 blurSample(texture2d<half> frame, sampler s, float2 uv, float2 texel, float radiusPx) {\n"
    "  float3 sum = float3(frame.sample(s, uv).rgb) * 4.0;\n"
    "  float weight = 4.0;\n"
    "  if (radiusPx > 0.35) {\n"
    "    float2 o = texel * radiusPx;\n"
    "    sum += float3(frame.sample(s, clamp(uv + float2( o.x, 0.0), float2(0.0), float2(1.0))).rgb); weight += 1.0;\n"
    "    sum += float3(frame.sample(s, clamp(uv + float2(-o.x, 0.0), float2(0.0), float2(1.0))).rgb); weight += 1.0;\n"
    "    sum += float3(frame.sample(s, clamp(uv + float2(0.0,  o.y), float2(0.0), float2(1.0))).rgb); weight += 1.0;\n"
    "    sum += float3(frame.sample(s, clamp(uv + float2(0.0, -o.y), float2(0.0), float2(1.0))).rgb); weight += 1.0;\n"
    "  }\n"
    "  if (radiusPx > 2.0) {\n"
    "    float2 o = texel * radiusPx * 0.72;\n"
    "    sum += float3(frame.sample(s, clamp(uv + float2( o.x,  o.y), float2(0.0), float2(1.0))).rgb); weight += 1.0;\n"
    "    sum += float3(frame.sample(s, clamp(uv + float2(-o.x,  o.y), float2(0.0), float2(1.0))).rgb); weight += 1.0;\n"
    "    sum += float3(frame.sample(s, clamp(uv + float2( o.x, -o.y), float2(0.0), float2(1.0))).rgb); weight += 1.0;\n"
    "    sum += float3(frame.sample(s, clamp(uv + float2(-o.x, -o.y), float2(0.0), float2(1.0))).rgb); weight += 1.0;\n"
    "  }\n"
    "  return sum / weight;\n"
    "}\n"
    "fragment half4 trueLiquidFragment(V in [[stage_in]], constant U& u [[buffer(0)]], texture2d<half> frame [[texture(0)]]) {\n"
    "  constexpr sampler s(address::clamp_to_edge, min_filter::linear, mag_filter::linear);\n"
    "  float2 panelSize = max(u.size, float2(1.0));\n"
    "  float2 panelTexel = u.uvScale / panelSize;\n"
    "  float2 baseUv = u.uvOrigin + in.uv * u.uvScale;\n"
    "  float2 uvEdge = min(baseUv, 1.0 - baseUv);\n"
    "  float validUv = smoothstep(-0.015, 0.018, min(uvEdge.x, uvEdge.y));\n"
    "  float2 p = (in.uv - 0.5) * panelSize;\n"
    "  float2 halfSize = panelSize * 0.5 - float2(1.0);\n"
    "  float radius = max(u.cornerRadius, 1.0);\n"
    "  float sd = roundedRectSdf(p, halfSize, radius);\n"
    "  float mask = 1.0 - smoothstep(0.0, 1.5, sd);\n"
    "  if (mask <= 0.001) return half4(0.0);\n"
    "  if (u.edgeDiagnostic > 0.5) {\n"
    "    float edgeRamp = 1.0 - smoothstep(0.0, 26.0, max(-sd, 0.0));\n"
    "    float2 stripe = step(0.5, fract((in.uv.x + in.uv.y) * 18.0)) * float2(1.0, 0.0);\n"
    "    float3 diagnosticColor = mix(float3(0.00, 0.82, 1.00), float3(1.00, 0.00, 0.72), edgeRamp);\n"
    "    diagnosticColor = mix(diagnosticColor, float3(1.0, 0.95, 0.12), stripe.x * 0.18);\n"
    "    return half4(half3(diagnosticColor), half(mask * validUv));\n"
    "  }\n"
    "  float inner = max(-sd, 0.0);\n"
    "  float minHalf = min(halfSize.x, halfSize.y);\n"
    "  float settled = smoothstep(0.0, 1.0, u.settled);\n"
    "  float refraction = u.refraction * (1.0 + 0.18 * settled);\n"
    "  float curve = clamp(u.curve + 0.045 * settled, 0.0, 1.0);\n"
    "  float dispersion = u.dispersion * (1.0 + 0.14 * settled);\n"
    "  float edge = min(1.0, u.edge * (1.0 + 0.18 * settled));\n"
    "  float depth = min(1.0, u.depth + 0.085 * settled);\n"
    "  float innerShadow = min(1.0, u.innerShadow + 0.075 * settled);\n"
    "  float refractionHeight = max(10.0, mix(radius * 1.25, minHalf * 0.24, curve));\n"
    "  float lensDepth = clamp(1.0 - inner / refractionHeight, 0.0, 1.0);\n"
    "  float edgeBand = circleMap(lensDepth);\n"
    "  float2 n = roundedRectNormal(p, halfSize, radius, sd);\n"
    "  float2 radial = normalize(p / max(panelSize * 0.5, float2(1.0)) + float2(0.0001));\n"
    "  float2 lensCoord = p / max(halfSize, float2(1.0));\n"
    "  float bodyLens = pow(max(0.0, 1.0 - dot(lensCoord, lensCoord)), mix(2.85, 0.72, curve));\n"
    "  float2 rimDir = normalize(n + radial * (0.18 + depth * 0.92));\n"
    "  float2 bodyCurve = float2(lensCoord.x * (1.0 - lensCoord.y * lensCoord.y * 0.46), lensCoord.y * (1.0 - lensCoord.x * lensCoord.x * 0.46));\n"
    "  float2 bodyDir = normalize(lensCoord + float2(0.0001));\n"
    "  float aspectBoost = clamp(sqrt(max(1.0, halfSize.x / max(halfSize.y, 1.0))), 1.0, 2.55);\n"
    "  float lensBasis = min(minHalf * aspectBoost * (1.02 + 0.22 * curve), halfSize.x * 0.42);\n"
    "  float refractionPx = lensBasis * refraction * (0.30 + 0.66 * curve) * (0.70 + 0.30 * depth);\n"
    "  float rimFold = pow(edgeBand, 0.74) * (0.76 + 0.24 * edge);\n"
    "  float2 refractPx = rimDir * rimFold * refractionPx;\n"
    "  refractPx += -bodyCurve * pow(bodyLens, 0.56) * refractionPx * (0.025 + 0.055 * depth);\n"
    "  refractPx += -bodyDir * pow(bodyLens, 0.82) * refractionPx * (0.012 + 0.026 * depth);\n"
    "  float capsuleY = pow(max(0.0, 1.0 - abs(lensCoord.y)), mix(3.60, 1.18, curve));\n"
    "  float capsuleX = 0.34 + 0.66 * pow(max(0.0, 1.0 - abs(lensCoord.x)), 0.42);\n"
    "  float capsuleLens = capsuleY * capsuleX;\n"
    "  refractPx += -float2(lensCoord.x * 0.22, lensCoord.y * 0.74) * capsuleLens * refractionPx * (0.018 + 0.040 * depth);\n"
    "  float causticBand = pow(bodyLens, 0.34) * (1.0 - pow(bodyLens, 1.72));\n"
    "  refractPx += bodyDir * causticBand * refractionPx * (0.022 + 0.042 * depth);\n"
    "  float2 focusCurve = float2(lensCoord.x * (1.0 - abs(lensCoord.y) * 0.34), lensCoord.y * (1.0 - abs(lensCoord.x) * 0.34));\n"
    "  refractPx += -focusCurve * pow(bodyLens, 0.50) * refractionPx * (0.014 + 0.036 * curve);\n"
    "  float productionBoost = 2.05;\n"
    "  float opticalBoost = mix(productionBoost, 3.4, clamp(u.edgeDiagnostic, 0.0, 1.0));\n"
    "  float2 uv = clamp(baseUv + refractPx * panelTexel * opticalBoost, float2(0.0), float2(1.0));\n"
    "  float blurPx = u.frost * 4.0 + u.blur * 8.0;\n"
    "  float3 sourceRgb = blurSample(frame, s, baseUv, panelTexel, blurPx);\n"
    "  float3 rgb = blurSample(frame, s, uv, panelTexel, blurPx);\n"
    "  if (dispersion > 0.001) {\n"
    "    float2 dispersionDir = normalize(rimDir * (0.75 + edgeBand) + radial * bodyLens * 0.55 + float2(0.0001));\n"
    "    float2 d = dispersionDir * panelTexel * dispersion * (20.0 + 72.0 * refraction + 32.0 * curve);\n"
    "    float spectral = clamp(dispersion * (0.92 + refraction * 0.70 + curve * 0.44), 0.0, 0.30);\n"
    "    float3 red = float3(frame.sample(s, clamp(uv + d * 1.30, float2(0.0), float2(1.0))).rgb);\n"
    "    float3 orange = float3(frame.sample(s, clamp(uv + d * 0.82, float2(0.0), float2(1.0))).rgb);\n"
    "    float3 yellow = float3(frame.sample(s, clamp(uv + d * 0.38, float2(0.0), float2(1.0))).rgb);\n"
    "    float3 green = float3(frame.sample(s, uv).rgb);\n"
    "    float3 cyan = float3(frame.sample(s, clamp(uv - d * 0.38, float2(0.0), float2(1.0))).rgb);\n"
    "    float3 blue = float3(frame.sample(s, clamp(uv - d * 0.82, float2(0.0), float2(1.0))).rgb);\n"
    "    float3 violet = float3(frame.sample(s, clamp(uv - d * 1.30, float2(0.0), float2(1.0))).rgb);\n"
    "    float3 prism = float3(red.r * 0.44 + orange.r * 0.24 + yellow.r * 0.17 + violet.r * 0.05,\n"
    "                         orange.g * 0.12 + yellow.g * 0.26 + green.g * 0.40 + cyan.g * 0.16,\n"
    "                         cyan.b * 0.20 + blue.b * 0.38 + violet.b * 0.30);\n"
    "    float spectralMask = clamp(edgeBand * 0.88, 0.0, 1.0);\n"
    "    rgb = mix(rgb, prism, spectral * spectralMask);\n"
    "  }\n"
    "  float foldBand = pow(edgeBand, 0.58) * (0.76 + 0.24 * edge);\n"
    "  float2 foldUv = clamp(baseUv - rimDir * panelTexel * refractionPx * opticalBoost * (0.36 + 0.38 * curve), float2(0.0), float2(1.0));\n"
    "  float3 folded = blurSample(frame, s, foldUv, panelTexel, blurPx * 0.72);\n"
    "  rgb = mix(rgb, folded, clamp(foldBand * (0.16 + edge * 0.22 + depth * 0.10), 0.0, 0.42));\n"
    "  float y = luma(rgb);\n"
    "  rgb = mix(float3(y), rgb, u.saturation);\n"
    "  rgb = (rgb - 0.5) * (1.0 + u.contrast * 1.35) + 0.5;\n"
    "  y = max(luma(rgb), 0.001);\n"
    "  float compressedY = 0.50 + (y - 0.50) * (1.0 - u.luminanceClamp * 0.52);\n"
    "  float targetY = clamp(compressedY, 0.08 + u.luminanceClamp * 0.06, 0.92 - u.luminanceClamp * 0.22);\n"
    "  rgb *= targetY / y;\n"
    "  rgb = mix(rgb, float3(0.035, 0.04, 0.045), u.tintAlpha);\n"
    "  y = luma(rgb);\n"
    "  float hotGuard = 1.0 - smoothstep(0.62, 0.86, y);\n"
    "  float rimColorGuard = 0.48 + 0.52 * hotGuard;\n"
    "  float topLight = smoothstep(0.90, 0.15, in.uv.y) * smoothstep(0.0, 0.45, in.uv.x) * smoothstep(1.0, 0.55, in.uv.x);\n"
    "  float bottomShade = smoothstep(0.35, 1.0, in.uv.y);\n"
    "  float3 bodyNormal = normalize(float3(-bodyCurve * (0.85 + 1.35 * depth) - n * edgeBand * 0.86, 1.0));\n"
    "  float3 sun = normalize(float3(-0.32, -0.72, 0.62));\n"
    "  float bodyLit = max(0.0, dot(bodyNormal, sun));\n"
    "  float bodySpec = pow(bodyLit, 7.5) * pow(bodyLens, 0.74) * depth * edge;\n"
    "  float bodyShade = pow(max(0.0, -dot(bodyNormal.xy, sun.xy)), 1.35) * pow(bodyLens, 0.62) * innerShadow;\n"
    "  float caustic = pow(bodyLens, 2.25) * depth * edge * (0.55 + 0.45 * smoothstep(0.95, -0.15, in.uv.y));\n"
    "  float2 lightDir = normalize(float2(-0.48, -0.88));\n"
    "  float litEdge = 0.35 + 0.65 * smoothstep(-0.35, 0.95, dot(n, lightDir));\n"
    "  float thinEdge = 1.0 - smoothstep(0.0, 5.0 + edge * 10.0, inner);\n"
    "  float rimSpec = pow(edgeBand, 1.28) * edge;\n"
    "  float shadowEdge = pow(edgeBand, 1.12) * smoothstep(-0.10, 0.92, dot(n, normalize(float2(0.70, 0.56))));\n"
    "  rgb += (rimSpec * 1.22 + thinEdge * litEdge * (0.86 + 0.30 * edge) * edge + topLight * 0.20 + caustic * 0.32) * hotGuard * float3(0.58, 0.70, 0.82);\n"
    "  rgb += bodySpec * hotGuard * float3(0.48, 0.62, 0.72);\n"
    "  rgb -= (bodyShade * (0.018 + bottomShade * 0.030) + shadowEdge * innerShadow * 0.026) * float3(0.86, 0.94, 1.0);\n"
    "  float rimOnly = max(thinEdge, pow(edgeBand, 2.35) * 0.38);\n"
    "  float glassEdge = pow(thinEdge, 1.22) * edge * (0.55 + 0.45 * litEdge);\n"
    "  float spectralRim = (rimOnly * dispersion * (0.38 + refraction * 0.82 + edge * 0.52) + glassEdge * dispersion * (0.45 + refraction * 0.75)) * rimColorGuard;\n"
    "  float2 splitDir = normalize(n + radial * (0.28 + depth * 0.34) + float2(0.0001));\n"
    "  float splitPx = (28.0 + refraction * 72.0 + curve * 24.0) * (thinEdge * 0.86 + pow(edgeBand, 2.10) * 0.18);\n"
    "  float2 splitD = splitDir * panelTexel * dispersion * splitPx;\n"
    "  float3 splitWarm = float3(frame.sample(s, clamp(uv + splitD, float2(0.0), float2(1.0))).rgb);\n"
    "  float3 splitCool = float3(frame.sample(s, clamp(uv - splitD, float2(0.0), float2(1.0))).rgb);\n"
    "  float3 splitRgb = float3(splitWarm.r, rgb.g, splitCool.b);\n"
    "  splitRgb *= max(luma(rgb), 0.001) / max(luma(splitRgb), 0.001);\n"
    "  rgb = mix(rgb, splitRgb, clamp(spectralRim * 0.40, 0.0, 0.30));\n"
    "  float warmSide = smoothstep(-0.55, 0.95, dot(n, normalize(float2(-0.72, -0.44))));\n"
    "  float3 rimPrism = mix(float3(0.02, 0.20, 0.34), float3(0.42, 0.12, 0.03), warmSide);\n"
    "  rgb += spectralRim * 0.28 * (rimPrism - float3(luma(rimPrism)));\n"
    "  rgb += pow(thinEdge, 1.80) * edge * hotGuard * (0.08 + 0.20 * dispersion) * (rimPrism - float3(luma(rimPrism)));\n"
    "  float innerShade = pow(edgeBand, 1.15) * innerShadow;\n"
    "  rgb -= (innerShade * (0.034 + bottomShade * 0.064) + thinEdge * (1.0 - litEdge) * innerShadow * 0.030) * float3(0.85, 0.95, 1.0);\n"
    "  float finalY = max(luma(rgb), 0.001);\n"
    "  float finalMaxY = 0.74 + (1.0 - u.luminanceClamp) * 0.12;\n"
    "  rgb *= min(1.0, finalMaxY / finalY);\n"
    "  rgb = mix(sourceRgb, rgb, u.glassAlpha);\n"
    "  return half4(half3(clamp(rgb, float3(0.0), float3(1.0))), half(mask * validUv));\n"
    "}\n";
}

static NSView *FindDirectSubview(NSView *root, NSString *identifier) {
    for (NSView *view in root.subviews) {
        if ([view.identifier isEqualToString:identifier]) return view;
    }
    return nil;
}

static NSWindow *ResolveWindow(void *nativePointer, NSView **viewOut) {
    if (!nativePointer) return nil;
    id object = (__bridge id)nativePointer;

    if ([object isKindOfClass:[NSWindow class]]) {
        NSWindow *window = (NSWindow *)object;
        if (viewOut) *viewOut = window.contentView;
        return window;
    }

    if ([object isKindOfClass:[NSView class]]) {
        NSView *view = (NSView *)object;
        if (viewOut) *viewOut = view;
        return view.window;
    }

    return nil;
}

static NSVisualEffectMaterial FallbackMaterial(void) {
    if (@available(macOS 10.14, *)) return NSVisualEffectMaterialUnderWindowBackground;
    return NSVisualEffectMaterialAppearanceBased;
}

static NSView *MakeNativeGlassView(NSRect frame, double cornerRadius, double glassAlpha, double tintAlpha, BOOL forceVisualEffect) {
    Class glassClass = NSClassFromString(@"NSGlassEffectView");
    if (glassClass && !forceVisualEffect) {
        id glass = [[glassClass alloc] initWithFrame:frame];
        if ([glass respondsToSelector:@selector(setCornerRadius:)]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(glass, @selector(setCornerRadius:), (CGFloat)cornerRadius);
        }
        if ([glass respondsToSelector:@selector(setTintColor:)]) {
            NSColor *tint = [NSColor colorWithCalibratedWhite:0.04 alpha:tintAlpha];
            ((void (*)(id, SEL, NSColor *))objc_msgSend)(glass, @selector(setTintColor:), tint);
        }
        NSView *view = (NSView *)glass;
        view.identifier = TrueLiquidGlassId;
        view.alphaValue = glassAlpha;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.wantsLayer = YES;
        view.layer.cornerRadius = cornerRadius;
        view.layer.masksToBounds = YES;
        return view;
    }

    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:frame];
    glass.identifier = TrueLiquidGlassId;
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glass.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    glass.material = FallbackMaterial();
    glass.state = NSVisualEffectStateActive;
    glass.alphaValue = glassAlpha;
    glass.wantsLayer = YES;
    glass.layer.cornerRadius = cornerRadius;
    glass.layer.masksToBounds = YES;
    return glass;
}

static void ConfigureLayer(NSView *view, CGFloat cornerRadius) {
    view.wantsLayer = YES;
    view.layer.backgroundColor = NSColor.clearColor.CGColor;
    view.layer.opaque = NO;
    view.layer.allowsGroupOpacity = NO;
    view.layer.cornerRadius = cornerRadius;
    view.layer.masksToBounds = NO;
}

static void ConfigureBackingLayers(CALayer *layer) {
    if (!layer) return;
    layer.backgroundColor = NSColor.clearColor.CGColor;
    layer.opaque = NO;
    layer.allowsGroupOpacity = NO;
    for (CALayer *sublayer in [layer.sublayers copy]) {
        ConfigureBackingLayers(sublayer);
    }
}

static void ConfigureLayerTree(NSView *view, CGFloat cornerRadius) {
    ConfigureLayer(view, cornerRadius);
    ConfigureBackingLayers(view.layer);
    for (NSView *subview in view.subviews) {
        ConfigureLayerTree(subview, cornerRadius);
    }
}

static void ConfigurePanelShadow(NSView *view, CGFloat cornerRadius, CGFloat outerShadow) {
    ConfigureLayer(view, cornerRadius);
    CGFloat strength = fmin(fmax(outerShadow, 0.0), 1.0);
    view.layer.shadowColor = NSColor.blackColor.CGColor;
    view.layer.shadowOpacity = 0.77f * strength;
    view.layer.shadowRadius = 12.0 + 36.0 * strength;
    view.layer.shadowOffset = CGSizeMake(0.0, -6.0 - 20.0 * strength);
    CGPathRef shadowPath = CGPathCreateWithRoundedRect(NSRectToCGRect(view.bounds), cornerRadius, cornerRadius, NULL);
    view.layer.shadowPath = shadowPath;
    CGPathRelease(shadowPath);
}

@class TrueLiquidMetalView;

@interface TrueLiquidCaptureOutput : NSObject<SCStreamOutput, SCStreamDelegate>
@property (nonatomic, weak) TrueLiquidMetalView *view;
@end

@interface TrueLiquidMetalView : NSView
- (void)applyStyle:(TrueLiquidNativeStyle)style;
- (void)startOrUpdateForWindow:(NSWindow *)window;
- (void)recenterForWindow:(NSWindow *)window;
- (BOOL)slideForWindow:(NSWindow *)window;
- (BOOL)syncPanelForCurrentWindow;
- (void)startWindowPolling;
- (void)stopWindowPolling;
- (void)pulseForWindow:(NSWindow *)window;
- (void)stopCapture;
- (void)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer frameHostTime:(uint64_t)frameHostTime status:(NSInteger)status;
- (void)renderLatestFrame;
- (void)renderLatestFrameNow;
- (void)renderLatestFrameFromFrame;
- (void)drawPixelBuffer:(CVPixelBufferRef)pixelBuffer captureRect:(CGRect)sourceCaptureRect frameHostTime:(uint64_t)sourceFrameHostTime latched:(BOOL)latched;
- (void)updateDragBackdropLatchForPanel:(CGRect)panelRect;
- (void)releaseDragBackdropLatch:(NSString *)reason;
- (void)clearDrawable;
@end

static CGRect ClampRectToDisplay(CGRect rect, SCDisplay *display, NSScreen *screen) {
    CGFloat maxWidth = display.width > 0 ? display.width : screen.frame.size.width;
    CGFloat maxHeight = display.height > 0 ? display.height : screen.frame.size.height;

    if (rect.origin.x < 0) {
        rect.size.width += rect.origin.x;
        rect.origin.x = 0;
    }
    if (rect.origin.y < 0) {
        rect.size.height += rect.origin.y;
        rect.origin.y = 0;
    }
    if (CGRectGetMaxX(rect) > maxWidth) rect.size.width = maxWidth - rect.origin.x;
    if (CGRectGetMaxY(rect) > maxHeight) rect.size.height = maxHeight - rect.origin.y;
    rect.size.width = fmax(1.0, rect.size.width);
    rect.size.height = fmax(1.0, rect.size.height);
    return rect;
}

static CGRect DisplayBoundsFor(SCDisplay *display, NSScreen *screen) {
    CGFloat maxWidth = display.width > 0 ? display.width : screen.frame.size.width;
    CGFloat maxHeight = display.height > 0 ? display.height : screen.frame.size.height;
    return CGRectMake(0.0, 0.0, maxWidth, maxHeight);
}

static CGRect VisiblePanelRect(CGRect panel, SCDisplay *display, NSScreen *screen) {
    CGRect visible = CGRectIntersection(panel, DisplayBoundsFor(display, screen));
    return CGRectIsNull(visible) ? CGRectZero : visible;
}

static CGRect VisiblePanelRectForDisplay(CGRect panel, SCDisplay *display) {
    CGFloat maxWidth = display && display.width > 0 ? display.width : fmax(1.0, CGRectGetMaxX(panel));
    CGFloat maxHeight = display && display.height > 0 ? display.height : fmax(1.0, CGRectGetMaxY(panel));
    CGRect visible = CGRectIntersection(panel, CGRectMake(0.0, 0.0, maxWidth, maxHeight));
    return CGRectIsNull(visible) ? CGRectZero : visible;
}

static CGRect PanelRectForWindow(NSWindow *window, SCDisplay *display) {
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    NSRect windowRect = [window convertRectToScreen:window.contentView.bounds];
    NSRect screenRect = screen.frame;

    CGFloat x = windowRect.origin.x - screenRect.origin.x;
    CGFloat y = NSMaxY(screenRect) - NSMaxY(windowRect);
    CGFloat width = windowRect.size.width;
    CGFloat height = windowRect.size.height;
    return CGRectMake(x, y, fmax(1.0, width), fmax(1.0, height));
}

static CGFloat RectArea(CGRect rect) {
    if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) return 0.0;
    return rect.size.width * rect.size.height;
}

static CGDirectDisplayID DisplayIDForGlobalRect(CGRect rect) {
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, displays, &count) != kCGErrorSuccess) return 0;

    CGDirectDisplayID bestDisplayID = 0;
    CGFloat bestArea = 0.0;
    for (uint32_t i = 0; i < count; i++) {
        CGRect intersection = CGRectIntersection(rect, CGDisplayBounds(displays[i]));
        CGFloat area = RectArea(intersection);
        if (area > bestArea) {
            bestArea = area;
            bestDisplayID = displays[i];
        }
    }
    return bestDisplayID;
}

static CGRect DisplayLocalRect(CGRect globalRect, CGDirectDisplayID displayID) {
    if (displayID == 0 || CGRectIsEmpty(globalRect)) return CGRectZero;
    CGRect displayBounds = CGDisplayBounds(displayID);
    return CGRectMake(
        globalRect.origin.x - displayBounds.origin.x,
        globalRect.origin.y - displayBounds.origin.y,
        globalRect.size.width,
        globalRect.size.height
    );
}

static CGRect GlobalPanelRectForWindowID(CGWindowID windowID) {
    if (windowID == 0) return CGRectZero;
    CFArrayRef descriptions = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, windowID);
    NSArray *windows = CFBridgingRelease(descriptions);
    NSDictionary *window = windows.firstObject;
    NSDictionary *bounds = window[(NSString *)kCGWindowBounds];
    if (!bounds) return CGRectZero;
    CGFloat x = [bounds[@"X"] doubleValue];
    CGFloat y = [bounds[@"Y"] doubleValue];
    CGFloat width = [bounds[@"Width"] doubleValue];
    CGFloat height = [bounds[@"Height"] doubleValue];
    if (width <= 0.0 || height <= 0.0) return CGRectZero;
    return CGRectMake(x, y, width, height);
}

static CGRect PanelRectForWindowIDInDisplay(CGWindowID windowID, CGDirectDisplayID displayID, CGDirectDisplayID *panelDisplayIDOut) {
    CGRect globalRect = GlobalPanelRectForWindowID(windowID);
    CGDirectDisplayID panelDisplayID = DisplayIDForGlobalRect(globalRect);
    if (panelDisplayIDOut) *panelDisplayIDOut = panelDisplayID;
    return DisplayLocalRect(globalRect, displayID);
}

static CGRect CaptureRectAroundPanel(CGRect panelRect, SCDisplay *display, NSScreen *screen) {
    CGFloat padX = fmax(420.0, fmin(620.0, panelRect.size.width * 0.45));
    CGFloat padY = fmax(460.0, fmin(640.0, panelRect.size.height * 0.88));
    CGRect capture = CGRectInset(panelRect, -padX, -padY);
    if (panelRect.size.width >= 600.0) {
        capture.origin.x = 0.0;
        capture.size.width = display.width > 0 ? display.width : screen.frame.size.width;
    }
    return ClampRectToDisplay(capture, display, screen);
}

static void StreamSizeForRect(CGRect source, NSWindow *window, TrueLiquidNativeStyle style, size_t *widthOut, size_t *heightOut) {
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    CGFloat scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 1.0;
    CGFloat captureScale = fmin(fmax(style.captureScale, 0.25f), 1.0f);
    if (widthOut) *widthOut = (size_t)fmax(16.0, ceil(source.size.width * scale * captureScale));
    if (heightOut) *heightOut = (size_t)fmax(16.0, ceil(source.size.height * scale * captureScale));
}

static BOOL RectNearlyEqual(CGRect a, CGRect b) {
    return fabs(a.origin.x - b.origin.x) < 0.5 &&
        fabs(a.origin.y - b.origin.y) < 0.5 &&
        fabs(a.size.width - b.size.width) < 0.5 &&
        fabs(a.size.height - b.size.height) < 0.5;
}

static BOOL RectContainsRectWithMargin(CGRect outer, CGRect inner, CGFloat margin) {
    CGRect safeOuter = CGRectInset(outer, margin, margin);
    return CGRectContainsRect(safeOuter, inner);
}

static BOOL CaptureNeedsRecenter(CGRect capture, CGRect panel, SCDisplay *display, NSScreen *screen, CGFloat margin) {
    CGRect visiblePanel = VisiblePanelRect(panel, display, screen);
    if (CGRectIsEmpty(capture) || CGRectIsEmpty(visiblePanel) || !CGRectContainsRect(capture, visiblePanel)) return YES;

    CGFloat maxWidth = display.width > 0 ? display.width : screen.frame.size.width;
    CGFloat maxHeight = display.height > 0 ? display.height : screen.frame.size.height;
    BOOL canGrowLeft = capture.origin.x > 0.5;
    BOOL canGrowTop = capture.origin.y > 0.5;
    BOOL canGrowRight = CGRectGetMaxX(capture) < maxWidth - 0.5;
    BOOL canGrowBottom = CGRectGetMaxY(capture) < maxHeight - 0.5;

    if (canGrowLeft && visiblePanel.origin.x - capture.origin.x < margin) return YES;
    if (canGrowTop && visiblePanel.origin.y - capture.origin.y < margin) return YES;
    if (canGrowRight && CGRectGetMaxX(capture) - CGRectGetMaxX(visiblePanel) < margin) return YES;
    if (canGrowBottom && CGRectGetMaxY(capture) - CGRectGetMaxY(visiblePanel) < margin) return YES;
    return NO;
}

static SCStreamConfiguration *MakeStreamConfiguration(CGRect source, NSWindow *window, TrueLiquidNativeStyle style, size_t *widthOut, size_t *heightOut) {
    StreamSizeForRect(source, window, style, widthOut, heightOut);

    SCStreamConfiguration *config = [SCStreamConfiguration new];
    config.width = widthOut ? *widthOut : 1;
    config.height = heightOut ? *heightOut : 1;
    config.sourceRect = source;
    config.pixelFormat = kCVPixelFormatType_32BGRA;
    config.colorSpaceName = kCGColorSpaceSRGB;
    config.minimumFrameInterval = CMTimeMake(1, (int32_t)fmin(fmax(style.fps, 15), 120));
    config.queueDepth = 2;
    config.showsCursor = NO;
    config.scalesToFit = YES;
    config.backgroundColor = NSColor.clearColor.CGColor;
    if (@available(macOS 14.0, *)) {
        config.preservesAspectRatio = NO;
        config.shouldBeOpaque = NO;
        config.ignoreShadowsDisplay = YES;
    }
    if (@available(macOS 15.0, *)) config.captureDynamicRange = SCCaptureDynamicRangeSDR;
    if (@available(macOS 14.0, *)) config.streamName = @"TrueLiquidBackdrop";
    return config;
}

static SCContentFilter *MakeBackdropFilter(SCShareableContent *content, SCDisplay *display, NSWindow *window, NSUInteger *appsOut, NSUInteger *windowsOut) {
    NSMutableArray<SCWindow *> *excludedWindows = [NSMutableArray array];
    NSMutableArray<SCRunningApplication *> *excludedApplications = [NSMutableArray array];
    CGWindowID ownWindowID = (CGWindowID)window.windowNumber;
    pid_t pid = getpid();

    for (SCRunningApplication *application in content.applications) {
        if (application.processID == pid && ![excludedApplications containsObject:application]) {
            [excludedApplications addObject:application];
        }
    }

    for (SCWindow *candidate in content.windows) {
        BOOL isOwnWindow = candidate.windowID == ownWindowID;
        BOOL isOwnProcess = candidate.owningApplication.processID == pid;
        BOOL intersectsPanel = CGRectIntersectsRect(candidate.frame, [window convertRectToScreen:window.contentView.bounds]);
        if (isOwnProcess && candidate.owningApplication && ![excludedApplications containsObject:candidate.owningApplication]) {
            [excludedApplications addObject:candidate.owningApplication];
        }
        if (isOwnWindow || isOwnProcess || (candidate.windowLayer > 0 && intersectsPanel)) {
            [excludedWindows addObject:candidate];
        }
    }

    SCContentFilter *filter = nil;
    if (excludedApplications.count > 0) {
        filter = [[SCContentFilter alloc] initWithDisplay:display excludingApplications:excludedApplications exceptingWindows:@[]];
        TrueLiquidLog(@"filter", [NSString stringWithFormat:@"\"excludedApps\":%lu,\"excludedWindows\":%lu",
                       (unsigned long)excludedApplications.count,
                       (unsigned long)excludedWindows.count]);
    } else {
        filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:excludedWindows];
        TrueLiquidLog(@"filter", [NSString stringWithFormat:@"\"excludedApps\":0,\"excludedWindows\":%lu",
                       (unsigned long)excludedWindows.count]);
    }
    if (appsOut) *appsOut = excludedApplications.count;
    if (windowsOut) *windowsOut = excludedWindows.count;
    if (@available(macOS 14.2, *)) filter.includeMenuBar = YES;
    return filter;
}

@implementation TrueLiquidMetalView {
    CAMetalLayer *_metalLayer;
    id<MTLDevice> _device;
    CVMetalTextureCacheRef _textureCache;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    dispatch_queue_t _sampleQueue;
    dispatch_queue_t _renderQueue;
    dispatch_queue_t _windowPollQueue;
    dispatch_source_t _windowPollTimer;
    TrueLiquidNativeStyle _style;
    SCStream *_stream;
    TrueLiquidCaptureOutput *_output;
    SCDisplay *_display;
    CGDirectDisplayID _displayID;
    CGWindowID _trackedWindowNumber;
    CGRect _captureRect;
    CGRect _pendingCaptureRect;
    CGRect _pendingPanelRect;
    CGRect _panelRect;
    size_t _streamWidth;
    size_t _streamHeight;
    int _streamFps;
    float _streamCaptureScale;
    CVPixelBufferRef _lastPixelBuffer;
    CVPixelBufferRef _dragPixelBuffer;
    CGRect _dragCaptureRect;
    uint64_t _dragFrameHostTimeNs;
    BOOL _starting;
    BOOL _awaitingFreshFrame;
    BOOL _recenterPending;
    BOOL _renderScheduled;
    BOOL _renderPending;
    BOOL _renderPendingImmediate;
    uint64_t _lastFrameHostTimeNs;
    NSUInteger _slideCount;
    NSUInteger _renderCount;
    NSUInteger _recenterCount;
    NSUInteger _drawCount;
    NSUInteger _frameSerial;
    NSUInteger _styleSerial;
    uint64_t _lastDirectSlideNs;
    uint64_t _lastDrawStartNs;
    uint64_t _lastSettledDrawNs;
    NSUInteger _filterRetryCount;
}

- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.identifier = TrueLiquidCaptureId;
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.wantsLayer = YES;

    _style = MakeStyle(0.50, 0.20, 0.42, 0.68, 0.18, 0.08, 0.02, 1.12, 0.05, 0.20, 0.26, 0.72, 0.42, 0.55, 34.0, 0.78, 60, TrueLiquidModeCaptureShader);
    _device = MTLCreateSystemDefaultDevice();
    if (_device) CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, _device, nil, &_textureCache);
    _commandQueue = [_device newCommandQueue];
    _sampleQueue = dispatch_queue_create("local.trueliquid.sample", DISPATCH_QUEUE_SERIAL);
    _renderQueue = dispatch_queue_create("local.trueliquid.render", DISPATCH_QUEUE_SERIAL);
    _windowPollQueue = dispatch_queue_create("local.trueliquid.window-poll", DISPATCH_QUEUE_SERIAL);

    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    CGColorSpaceRef outputColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (outputColorSpace) {
        _metalLayer.colorspace = outputColorSpace;
        CGColorSpaceRelease(outputColorSpace);
    }
    _metalLayer.framebufferOnly = YES;
    _metalLayer.opaque = NO;
    _metalLayer.presentsWithTransaction = NO;
    _metalLayer.allowsNextDrawableTimeout = YES;
    _metalLayer.backgroundColor = NSColor.clearColor.CGColor;
    _metalLayer.cornerRadius = _style.cornerRadius;
    _metalLayer.masksToBounds = YES;
    if (@available(macOS 10.13, *)) _metalLayer.maximumDrawableCount = 3;
    self.layer = _metalLayer;

    [self buildPipeline];
    [self updateDrawableSize];
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)dealloc {
    if (_textureCache) {
        CVMetalTextureCacheFlush(_textureCache, 0);
        CFRelease(_textureCache);
        _textureCache = nil;
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updateDrawableSize];
    [self renderLatestFrame];
}

- (void)setBoundsSize:(NSSize)newSize {
    [super setBoundsSize:newSize];
    [self updateDrawableSize];
    [self renderLatestFrame];
}

- (void)buildPipeline {
    if (!_device) return;

    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:TrueLiquidShaderSource() options:nil error:&error];
    if (!library) {
        NSLog(@"TrueLiquid Metal library error: %@", error);
        return;
    }

    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"trueLiquidVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"trueLiquidFragment"];
    descriptor.colorAttachments[0].pixelFormat = _metalLayer.pixelFormat;
    descriptor.colorAttachments[0].blendingEnabled = NO;

    _pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_pipeline) NSLog(@"TrueLiquid pipeline error: %@", error);
}

- (void)updateDrawableSize {
    CGFloat scale = self.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor ?: 1.0;
    CGSize size = self.bounds.size;
    _metalLayer.contentsScale = scale;
    _metalLayer.drawableSize = CGSizeMake(fmax(1.0, size.width * scale), fmax(1.0, size.height * scale));
}

- (void)applyStyle:(TrueLiquidNativeStyle)style {
    @synchronized (self) {
        _style = style;
        _styleSerial++;
    }
    _metalLayer.cornerRadius = style.cornerRadius;
    _metalLayer.masksToBounds = YES;
    [self updateDrawableSize];
    [self renderLatestFrame];
}

- (void)startOrUpdateForWindow:(NSWindow *)window {
    TrueLiquidLog(@"start-update", [NSString stringWithFormat:@"\"hasWindow\":%@,\"hasDevice\":%@,\"hasPipeline\":%@,\"hasStream\":%@",
                   window ? @"true" : @"false",
                   _device ? @"true" : @"false",
                   _pipeline ? @"true" : @"false",
                   _stream ? @"true" : @"false"]);
    if (!SupportsScreenCaptureKit() || !window || !_device || !_pipeline) return;
    [self updateDrawableSize];
    @synchronized (self) {
        _trackedWindowNumber = (CGWindowID)window.windowNumber;
    }
    [self startWindowPolling];

    NSNumber *screenNumber = window.screen.deviceDescription[@"NSScreenNumber"];
    CGDirectDisplayID targetDisplayID = screenNumber ? screenNumber.unsignedIntValue : CGMainDisplayID();

    TrueLiquidNativeStyle style;
    @synchronized (self) { style = _style; }

    if (_stream && _display && _displayID == targetDisplayID) {
        CGRect nextPanel = PanelRectForWindow(window, _display);
        CGRect nextCapture = _captureRect;
        size_t nextWidth = 0;
        size_t nextHeight = 0;
        BOOL canReuseCapture = !CaptureNeedsRecenter(_captureRect, nextPanel, _display, window.screen ?: NSScreen.mainScreen, 220.0) &&
            style.fps == _streamFps &&
            fabs(style.captureScale - _streamCaptureScale) <= 0.005f;

        if (canReuseCapture) {
            @synchronized (self) {
                _panelRect = nextPanel;
            }
            [self renderLatestFrame];
            return;
        }

        nextCapture = CaptureRectAroundPanel(nextPanel, _display, window.screen ?: NSScreen.mainScreen);
        SCStreamConfiguration *config = MakeStreamConfiguration(nextCapture, window, style, &nextWidth, &nextHeight);
        BOOL changed = !RectNearlyEqual(nextCapture, _captureRect) ||
            nextWidth != _streamWidth ||
            nextHeight != _streamHeight ||
            style.fps != _streamFps ||
            fabs(style.captureScale - _streamCaptureScale) > 0.005f;
        if (!changed) {
            @synchronized (self) {
                _panelRect = nextPanel;
                _recenterPending = NO;
            }
            [self renderLatestFrame];
            return;
        }

        BOOL recenterPending = NO;
        @synchronized (self) { recenterPending = _recenterPending; }
        if (recenterPending) {
            @synchronized (self) { _panelRect = nextPanel; }
            [self renderLatestFrame];
            return;
        }

        @synchronized (self) {
            _pendingCaptureRect = nextCapture;
            _pendingPanelRect = nextPanel;
            _streamWidth = nextWidth;
            _streamHeight = nextHeight;
            _streamFps = style.fps;
            _streamCaptureScale = style.captureScale;
            _recenterPending = YES;
            _recenterCount++;
        }
        TrueLiquidLog(@"recenter-request", [NSString stringWithFormat:@"\"panel\":\"%@\",\"capture\":\"%@\",\"nextCapture\":\"%@\",\"w\":%zu,\"h\":%zu",
                       TrueLiquidRectDescription(nextPanel),
                       TrueLiquidRectDescription(_captureRect),
                       TrueLiquidRectDescription(nextCapture),
                       nextWidth,
                       nextHeight]);
        [_stream updateConfiguration:config completionHandler:^(NSError *error) {
            if (error) {
                @synchronized (self) { self->_recenterPending = NO; }
                NSLog(@"TrueLiquid updateConfiguration error: %@", error);
                TrueLiquidLog(@"recenter-error", [NSString stringWithFormat:@"\"message\":\"%@\"", error.localizedDescription ?: @"unknown"]);
            } else {
                TrueLiquidLog(@"recenter-configured", @"");
            }
        }];
        return;
    }

    if (_starting) return;
    _starting = YES;
    [self stopCapture];

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_starting = NO;
            if (error || !content) {
                NSLog(@"TrueLiquid shareable content error: %@", error);
                TrueLiquidLog(@"shareable-error", [NSString stringWithFormat:@"\"message\":\"%@\"", error.localizedDescription ?: @"unknown"]);
                return;
            }

            SCDisplay *display = nil;
            for (SCDisplay *candidate in content.displays) {
                if (candidate.displayID == targetDisplayID) {
                    display = candidate;
                    break;
                }
            }
            if (!display) display = content.displays.firstObject;
            if (!display) {
                NSLog(@"TrueLiquid: no capturable display");
                TrueLiquidLog(@"display-error", @"\"message\":\"no capturable display\"");
                return;
            }

            NSUInteger excludedApps = 0;
            NSUInteger excludedWindows = 0;
            SCContentFilter *filter = MakeBackdropFilter(content, display, window, &excludedApps, &excludedWindows);
            if (TrueLiquidWindowCaptureVisible && excludedApps == 0 && excludedWindows == 0 && self->_filterRetryCount < 6) {
                self->_filterRetryCount++;
                TrueLiquidLog(@"filter-retry", [NSString stringWithFormat:@"\"attempt\":%lu", (unsigned long)self->_filterRetryCount]);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(140 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    [self startOrUpdateForWindow:window];
                });
                return;
            }
            self->_filterRetryCount = 0;
            CGRect panelRect = PanelRectForWindow(window, display);
            CGRect captureRect = CaptureRectAroundPanel(panelRect, display, window.screen ?: NSScreen.mainScreen);
            size_t width = 0;
            size_t height = 0;
            SCStreamConfiguration *config = MakeStreamConfiguration(captureRect, window, style, &width, &height);

            self->_output = [TrueLiquidCaptureOutput new];
            self->_output.view = self;
            self->_stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self->_output];
            self->_display = display;
            self->_displayID = display.displayID;
            @synchronized (self) {
                self->_captureRect = captureRect;
                self->_pendingCaptureRect = CGRectZero;
                self->_pendingPanelRect = CGRectZero;
                self->_panelRect = panelRect;
                self->_streamWidth = width;
                self->_streamHeight = height;
                self->_streamFps = style.fps;
                self->_streamCaptureScale = style.captureScale;
                self->_awaitingFreshFrame = YES;
                self->_recenterPending = NO;
            }
            TrueLiquidLog(@"stream-start", [NSString stringWithFormat:@"\"panel\":\"%@\",\"capture\":\"%@\",\"w\":%zu,\"h\":%zu",
                           TrueLiquidRectDescription(panelRect),
                           TrueLiquidRectDescription(captureRect),
                           width,
                           height]);
            [self clearDrawable];

            NSError *streamError = nil;
            [self->_stream addStreamOutput:self->_output type:SCStreamOutputTypeScreen sampleHandlerQueue:self->_sampleQueue error:&streamError];
            if (streamError) {
                NSLog(@"TrueLiquid addStreamOutput error: %@", streamError);
                return;
            }

            [self->_stream startCaptureWithCompletionHandler:^(NSError *startError) {
                if (startError) {
                    NSLog(@"TrueLiquid startCapture error: %@", startError);
                    TrueLiquidLog(@"stream-start-error", [NSString stringWithFormat:@"\"message\":\"%@\"", startError.localizedDescription ?: @"unknown"]);
                } else {
                    TrueLiquidLog(@"stream-started", @"");
                }
            }];
        });
    }];
}

- (void)recenterForWindow:(NSWindow *)window {
    [self releaseDragBackdropLatch:@"settle"];
    @synchronized (self) {
        _recenterCount++;
    }
    TrueLiquidLog(@"recenter-explicit", @"\"source\":\"coordinator\"");
    [self startOrUpdateForWindow:window];
}

- (void)pulseForWindow:(NSWindow *)window {
    if (!window) return;
    if (!_stream || !_display) {
        [self startOrUpdateForWindow:window];
        return;
    }

    BOOL awaiting = NO;
    @synchronized (self) {
        awaiting = _awaitingFreshFrame;
    }
    if (awaiting) return;

    NSNumber *screenNumber = window.screen.deviceDescription[@"NSScreenNumber"];
    CGDirectDisplayID targetDisplayID = screenNumber ? screenNumber.unsignedIntValue : CGMainDisplayID();
    if (_displayID != targetDisplayID) {
        [self startOrUpdateForWindow:window];
        return;
    }

    TrueLiquidNativeStyle style;
    @synchronized (self) { style = _style; }
    if (style.fps != _streamFps || fabs(style.captureScale - _streamCaptureScale) > 0.005f) {
        [self startOrUpdateForWindow:window];
        return;
    }

    [self slideForWindow:window];
}

- (BOOL)slideForWindow:(NSWindow *)window {
    if (!window || !_display || _displayID == 0) return NO;
    uint64_t nowNs = TrueLiquidNowNs();
    NSNumber *screenNumber = window.screen.deviceDescription[@"NSScreenNumber"];
    CGDirectDisplayID targetDisplayID = screenNumber ? screenNumber.unsignedIntValue : CGMainDisplayID();
    if (_displayID != targetDisplayID) {
        [self startOrUpdateForWindow:window];
        return NO;
    }

    CGRect nextPanel = PanelRectForWindow(window, _display);
    BOOL changed = NO;
    CGRect captureRect = CGRectZero;
    BOOL pending = NO;
    BOOL awaiting = NO;
    NSUInteger slideCount = 0;
    @synchronized (self) {
        changed = CGRectIsEmpty(_panelRect) || !RectNearlyEqual(_panelRect, nextPanel);
        if (!changed) return NO;
        _panelRect = nextPanel;
        _lastDirectSlideNs = nowNs;
        _slideCount++;
        slideCount = _slideCount;
        captureRect = _captureRect;
        pending = _recenterPending;
        awaiting = _awaitingFreshFrame;
    }
    [self updateDragBackdropLatchForPanel:nextPanel];
    [self renderLatestFrameNow];
    CGFloat left = nextPanel.origin.x - captureRect.origin.x;
    CGFloat top = nextPanel.origin.y - captureRect.origin.y;
    CGFloat right = CGRectGetMaxX(captureRect) - CGRectGetMaxX(nextPanel);
    CGFloat bottom = CGRectGetMaxY(captureRect) - CGRectGetMaxY(nextPanel);
    TrueLiquidLogAtMs(@"slide", [NSString stringWithFormat:@"\"n\":%lu,\"panel\":\"%@\",\"capture\":\"%@\",\"edge\":\"%.1f,%.1f,%.1f,%.1f\",\"pending\":%@,\"awaiting\":%@",
                       (unsigned long)slideCount,
                       TrueLiquidRectDescription(nextPanel),
                       TrueLiquidRectDescription(captureRect),
                       left,
                       top,
                       right,
                       bottom,
                       pending ? @"true" : @"false",
                       awaiting ? @"true" : @"false"],
                      (double)nowNs / 1000000.0);
    return YES;
}

- (BOOL)syncPanelForCurrentWindow {
    uint64_t nowNs = TrueLiquidNowNs();
    CGWindowID windowID = 0;
    CGDirectDisplayID displayID = 0;
    @synchronized (self) {
        windowID = _trackedWindowNumber;
        displayID = _displayID;
    }
    CGDirectDisplayID panelDisplayID = 0;
    CGRect nextPanel = PanelRectForWindowIDInDisplay(windowID, displayID, &panelDisplayID);
    if (CGRectIsEmpty(nextPanel)) return NO;
    if (panelDisplayID != 0 && displayID != 0 && panelDisplayID != displayID) {
        TrueLiquidLogAtMs(@"display-change-request", [NSString stringWithFormat:@"\"source\":\"frame\",\"from\":%u,\"to\":%u",
                           displayID,
                           panelDisplayID],
                          (double)nowNs / 1000000.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSWindow *window = self.window;
            if (window && !self.hidden) [self startOrUpdateForWindow:window];
        });
        return NO;
    }

    BOOL changed = NO;
    CGRect captureRect = CGRectZero;
    BOOL pending = NO;
    BOOL awaiting = NO;
    NSUInteger slideCount = 0;
    @synchronized (self) {
        if (_lastDirectSlideNs != 0 && (nowNs <= _lastDirectSlideNs || nowNs - _lastDirectSlideNs < 8000000ULL)) return NO;
        changed = CGRectIsEmpty(_panelRect) || !RectNearlyEqual(_panelRect, nextPanel);
        if (!changed) return NO;
        _panelRect = nextPanel;
        _slideCount++;
        slideCount = _slideCount;
        captureRect = _captureRect;
        pending = _recenterPending;
        awaiting = _awaitingFreshFrame;
    }
    [self updateDragBackdropLatchForPanel:nextPanel];
    [self renderLatestFrameNow];
    CGFloat left = nextPanel.origin.x - captureRect.origin.x;
    CGFloat top = nextPanel.origin.y - captureRect.origin.y;
    CGFloat right = CGRectGetMaxX(captureRect) - CGRectGetMaxX(nextPanel);
    CGFloat bottom = CGRectGetMaxY(captureRect) - CGRectGetMaxY(nextPanel);
    TrueLiquidLogAtMs(@"slide", [NSString stringWithFormat:@"\"source\":\"frame\",\"n\":%lu,\"panel\":\"%@\",\"capture\":\"%@\",\"edge\":\"%.1f,%.1f,%.1f,%.1f\",\"pending\":%@,\"awaiting\":%@",
                       (unsigned long)slideCount,
                       TrueLiquidRectDescription(nextPanel),
                       TrueLiquidRectDescription(captureRect),
                       left,
                       top,
                       right,
                       bottom,
                       pending ? @"true" : @"false",
                       awaiting ? @"true" : @"false"],
                      (double)nowNs / 1000000.0);
    return YES;
}

- (void)startWindowPolling {
    if (_windowPollTimer || !_windowPollQueue) return;
    _windowPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _windowPollQueue);
    dispatch_source_set_timer(_windowPollTimer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(1000000000.0 / 120.0), (uint64_t)(1000000000.0 / 240.0));
    __weak TrueLiquidMetalView *weakSelf = self;
    dispatch_source_set_event_handler(_windowPollTimer, ^{
        TrueLiquidMetalView *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf syncPanelForCurrentWindow];
    });
    dispatch_resume(_windowPollTimer);
}

- (void)stopWindowPolling {
    if (!_windowPollTimer) return;
    dispatch_source_cancel(_windowPollTimer);
    _windowPollTimer = nil;
}

- (void)stopCapture {
    [self stopWindowPolling];
    SCStream *stream = _stream;
    _stream = nil;
    _output = nil;
    _display = nil;
    _displayID = 0;
    _trackedWindowNumber = 0;
    CVPixelBufferRef oldPixelBuffer = nil;
    @synchronized (self) {
        _captureRect = CGRectZero;
        _pendingCaptureRect = CGRectZero;
        _pendingPanelRect = CGRectZero;
        _panelRect = CGRectZero;
        _awaitingFreshFrame = NO;
        _recenterPending = NO;
        _renderPending = NO;
        _renderPendingImmediate = NO;
        oldPixelBuffer = _lastPixelBuffer;
        _lastPixelBuffer = nil;
    }
    if (oldPixelBuffer) CVPixelBufferRelease(oldPixelBuffer);
    [self releaseDragBackdropLatch:@"stop"];
    _streamWidth = 0;
    _streamHeight = 0;
    if (stream) {
        [stream stopCaptureWithCompletionHandler:^(NSError *error) {
            if (error) NSLog(@"TrueLiquid stopCapture error: %@", error);
        }];
    }
}

- (void)updateDragBackdropLatchForPanel:(CGRect)panelRect {
    CVPixelBufferRef releasedPixelBuffer = nil;
    BOOL didRelease = NO;
    BOOL didLatch = NO;
    CGRect latchedCaptureRect = CGRectZero;
    uint64_t latchedFrameHostTime = 0;
    CGRect visiblePanelRect = VisiblePanelRectForDisplay(panelRect, _display);

    @synchronized (self) {
        if (_dragPixelBuffer && !RectContainsRectWithMargin(_dragCaptureRect, visiblePanelRect, 0.0)) {
            releasedPixelBuffer = _dragPixelBuffer;
            _dragPixelBuffer = nil;
            _dragCaptureRect = CGRectZero;
            _dragFrameHostTimeNs = 0;
            didRelease = YES;
        }

        if (!_dragPixelBuffer && _lastPixelBuffer && !_recenterPending && !_awaitingFreshFrame &&
            RectContainsRectWithMargin(_captureRect, visiblePanelRect, 24.0)) {
            _dragPixelBuffer = _lastPixelBuffer;
            CVPixelBufferRetain(_dragPixelBuffer);
            _dragCaptureRect = _captureRect;
            _dragFrameHostTimeNs = _lastFrameHostTimeNs;
            latchedCaptureRect = _dragCaptureRect;
            latchedFrameHostTime = _dragFrameHostTimeNs;
            didLatch = YES;
        }
    }

    if (releasedPixelBuffer) CVPixelBufferRelease(releasedPixelBuffer);
    if (didRelease) TrueLiquidLog(@"drag-unlatch", @"\"reason\":\"edge\"");
    if (didLatch) {
        TrueLiquidLog(@"drag-latch", [NSString stringWithFormat:@"\"capture\":\"%@\",\"frameAgeMs\":%.3f",
                       TrueLiquidRectDescription(latchedCaptureRect),
                       TrueLiquidAgeMs(latchedFrameHostTime)]);
    }
}

- (void)releaseDragBackdropLatch:(NSString *)reason {
    CVPixelBufferRef releasedPixelBuffer = nil;
    @synchronized (self) {
        releasedPixelBuffer = _dragPixelBuffer;
        _dragPixelBuffer = nil;
        _dragCaptureRect = CGRectZero;
        _dragFrameHostTimeNs = 0;
    }
    if (releasedPixelBuffer) {
        TrueLiquidLog(@"drag-unlatch", [NSString stringWithFormat:@"\"reason\":\"%@\"", reason ?: @"unknown"]);
        CVPixelBufferRelease(releasedPixelBuffer);
    }
}

- (void)renderLatestFrameImmediate:(BOOL)immediate {
    @synchronized (self) {
        if (_awaitingFreshFrame) return;
        if (!_lastPixelBuffer && !_dragPixelBuffer) return;
        if (_renderScheduled) {
            _renderPending = YES;
            if (immediate) _renderPendingImmediate = YES;
            TrueLiquidLog(immediate ? @"render-coalesce-immediate" : @"render-coalesce", @"");
            return;
        }
        _renderScheduled = YES;
        _renderPendingImmediate = NO;
        _renderCount++;
        TrueLiquidLog(@"render-schedule", [NSString stringWithFormat:@"\"n\":%lu", (unsigned long)_renderCount]);
    }

    void (^renderWork)(void) = ^{
        CVPixelBufferRef pixelBuffer = nil;
        CGRect sourceCaptureRect = CGRectZero;
        uint64_t sourceFrameHostTime = 0;
        BOOL latched = NO;
        @synchronized (self) {
            CGRect visiblePanelRect = VisiblePanelRectForDisplay(self->_panelRect, self->_display);
            if (self->_dragPixelBuffer && RectContainsRectWithMargin(self->_dragCaptureRect, visiblePanelRect, 0.0)) {
                pixelBuffer = self->_dragPixelBuffer;
                sourceCaptureRect = self->_dragCaptureRect;
                sourceFrameHostTime = self->_dragFrameHostTimeNs;
                latched = YES;
            } else {
                pixelBuffer = self->_lastPixelBuffer;
                sourceCaptureRect = self->_captureRect;
                sourceFrameHostTime = self->_lastFrameHostTimeNs;
            }
            if (pixelBuffer) CVPixelBufferRetain(pixelBuffer);
            self->_renderPending = NO;
        }

        if (pixelBuffer) {
            @autoreleasepool {
                [self drawPixelBuffer:pixelBuffer captureRect:sourceCaptureRect frameHostTime:sourceFrameHostTime latched:latched];
            }
            CVPixelBufferRelease(pixelBuffer);
        }

        BOOL shouldRenderAgain = NO;
        BOOL shouldRenderAgainImmediate = NO;
        @synchronized (self) {
            shouldRenderAgain = self->_renderPending;
            shouldRenderAgainImmediate = self->_renderPendingImmediate;
            self->_renderPending = NO;
            self->_renderPendingImmediate = NO;
            self->_renderScheduled = NO;
        }

        if (shouldRenderAgain) {
            if (shouldRenderAgainImmediate) {
                TrueLiquidLog(@"render-defer-immediate", @"");
                [self renderLatestFrame];
            } else {
                TrueLiquidLog(@"render-defer", @"");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000000000.0 / 240.0)), dispatch_get_main_queue(), ^{
                    [self renderLatestFrame];
                });
            }
        }
    };
    if (immediate) {
        renderWork();
    } else {
        dispatch_async(_renderQueue, renderWork);
    }
}

- (void)renderLatestFrame {
    [self renderLatestFrameImmediate:NO];
}

- (void)renderLatestFrameNow {
    [self renderLatestFrameImmediate:YES];
}

- (void)renderLatestFrameFromFrame {
    uint64_t nowNs = TrueLiquidNowNs();
    BOOL skip = NO;
    BOOL hotSlide = NO;
    @synchronized (self) {
        skip = _lastDrawStartNs != 0 && nowNs > _lastDrawStartNs && nowNs - _lastDrawStartNs < 8000000ULL;
        hotSlide = _lastDirectSlideNs != 0 && nowNs > _lastDirectSlideNs && nowNs - _lastDirectSlideNs < 24000000ULL;
    }
    if (skip) {
        TrueLiquidLog(@"render-frame-throttle", @"");
        return;
    }
    if (hotSlide) {
        TrueLiquidLog(@"render-frame-hot-slide", @"");
        return;
    }
    [self renderLatestFrame];
}

- (void)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer frameHostTime:(uint64_t)frameHostTime status:(NSInteger)status {
    if (!pixelBuffer) return;
    uint64_t receivedNs = TrueLiquidNowNs();
    CVPixelBufferRetain(pixelBuffer);
    CVPixelBufferRef oldPixelBuffer = nil;
    CVPixelBufferRef oldDragPixelBuffer = nil;
    BOOL appliedPending = NO;
    BOOL refreshedDragLatch = NO;
    CGRect refreshedDragCaptureRect = CGRectZero;
    @synchronized (self) {
        if (!CGRectIsEmpty(_pendingCaptureRect)) {
            _captureRect = _pendingCaptureRect;
            _panelRect = _pendingPanelRect;
            _pendingCaptureRect = CGRectZero;
            _pendingPanelRect = CGRectZero;
            _recenterPending = NO;
            appliedPending = YES;
        }
        _awaitingFreshFrame = NO;
        _lastFrameHostTimeNs = frameHostTime;
        oldPixelBuffer = _lastPixelBuffer;
        _lastPixelBuffer = pixelBuffer;
        _frameSerial++;
        BOOL hotDrag = _lastDirectSlideNs != 0 &&
            receivedNs > _lastDirectSlideNs &&
            receivedNs - _lastDirectSlideNs < 120000000ULL;
        if (_dragPixelBuffer && !_recenterPending && !hotDrag) {
            CGRect visiblePanelRect = VisiblePanelRectForDisplay(_panelRect, _display);
            if (RectContainsRectWithMargin(_captureRect, visiblePanelRect, 0.0)) {
                oldDragPixelBuffer = _dragPixelBuffer;
                _dragPixelBuffer = pixelBuffer;
                CVPixelBufferRetain(_dragPixelBuffer);
                _dragCaptureRect = _captureRect;
                _dragFrameHostTimeNs = frameHostTime;
                refreshedDragLatch = YES;
                refreshedDragCaptureRect = _dragCaptureRect;
            }
        }
    }
    if (oldPixelBuffer) CVPixelBufferRelease(oldPixelBuffer);
    if (oldDragPixelBuffer) CVPixelBufferRelease(oldDragPixelBuffer);
    double ageMs = TrueLiquidAgeMs(frameHostTime);
    TrueLiquidLog(@"frame", [NSString stringWithFormat:@"\"status\":%ld,\"ageMs\":%.3f,\"appliedPending\":%@",
                   (long)status,
                   ageMs,
                   appliedPending ? @"true" : @"false"]);
    if (refreshedDragLatch) {
        TrueLiquidLog(@"drag-latch-refresh", [NSString stringWithFormat:@"\"capture\":\"%@\",\"frameAgeMs\":%.3f",
                       TrueLiquidRectDescription(refreshedDragCaptureRect),
                       ageMs]);
    }
    [self renderLatestFrameFromFrame];
}

- (void)drawPixelBuffer:(CVPixelBufferRef)pixelBuffer captureRect:(CGRect)sourceCaptureRect frameHostTime:(uint64_t)sourceFrameHostTime latched:(BOOL)latched {
    if (!pixelBuffer || self.hidden || !self.window || !_pipeline || !_commandQueue) return;

    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    if (width == 0 || height == 0) return;

    uint64_t drawableStartNs = TrueLiquidNowNs();
    @synchronized (self) { _lastDrawStartNs = drawableStartNs; }
    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    uint64_t drawableReadyNs = TrueLiquidNowNs();
    double drawableWaitMs = (double)(drawableReadyNs - drawableStartNs) / 1000000.0;
    if (!drawable) {
        TrueLiquidLog(@"drawable-miss", [NSString stringWithFormat:@"\"waitMs\":%.3f", drawableWaitMs]);
        return;
    }

    TrueLiquidNativeStyle style;
    CGRect captureRect = CGRectZero;
    CGRect panelRect = CGRectZero;
    uint64_t frameHostTime = 0;
    uint64_t lastSlideNs = 0;
    NSUInteger drawCount = 0;
    @synchronized (self) {
        style = _style;
        captureRect = CGRectIsEmpty(sourceCaptureRect) ? _captureRect : sourceCaptureRect;
        panelRect = _panelRect;
        frameHostTime = sourceFrameHostTime != 0 ? sourceFrameHostTime : _lastFrameHostTimeNs;
        lastSlideNs = _lastDirectSlideNs;
        _drawCount++;
        drawCount = _drawCount;
    }
    if (lastSlideNs > drawableStartNs && drawableWaitMs > 2.0) {
        @synchronized (self) { _renderPending = YES; }
        TrueLiquidLog(latched ? @"draw-latched-late" : @"draw-obsolete", [NSString stringWithFormat:@"\"waitMs\":%.3f,\"slideLagMs\":%.3f",
                       drawableWaitMs,
                       (double)(lastSlideNs - drawableStartNs) / 1000000.0]);
        if (!latched || !RectContainsRectWithMargin(captureRect, panelRect, 0.0)) {
            return;
        }
    }

    CVMetalTextureRef cvTexture = nil;
    if (_textureCache) {
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, pixelBuffer, nil, MTLPixelFormatBGRA8Unorm, width, height, 0, &cvTexture);
    }
    id<MTLTexture> sourceTexture = cvTexture ? CVMetalTextureGetTexture(cvTexture) : nil;
    if (!sourceTexture) {
        if (cvTexture) {
            CFRelease(cvTexture);
            cvTexture = nil;
        }
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
        if (surface) {
            MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
            textureDescriptor.usage = MTLTextureUsageShaderRead;
            sourceTexture = [_device newTextureWithDescriptor:textureDescriptor iosurface:surface plane:0];
        }
    }
    if (!sourceTexture) return;

    CGFloat scale = _metalLayer.contentsScale > 0 ? _metalLayer.contentsScale : 1.0;
    CGFloat captureWidth = fmax(1.0, captureRect.size.width);
    CGFloat captureHeight = fmax(1.0, captureRect.size.height);
    vector_float2 uvOrigin = (vector_float2){0.0f, 0.0f};
    vector_float2 uvScale = (vector_float2){1.0f, 1.0f};
    if (!CGRectIsEmpty(captureRect) && !CGRectIsEmpty(panelRect)) {
        uvOrigin = (vector_float2){
            (float)((panelRect.origin.x - captureRect.origin.x) / captureWidth),
            (float)((panelRect.origin.y - captureRect.origin.y) / captureHeight)
        };
        uvScale = (vector_float2){
            (float)(panelRect.size.width / captureWidth),
            (float)(panelRect.size.height / captureHeight)
        };
    }
    double frameAgeMs = TrueLiquidAgeMs(frameHostTime);
    BOOL edgeDiagnostic = EnvFlagEnabled("TRUE_LIQUID_EDGE_DIAGNOSTIC");
    float settled = 1.0f;
    if (lastSlideNs != 0) {
        if (drawableReadyNs <= lastSlideNs) {
            settled = 0.0f;
        } else {
            double sinceSlideMs = (double)(drawableReadyNs - lastSlideNs) / 1000000.0;
            settled = ClampFloat(0.82 + sinceSlideMs / 260.0 * 0.18, 0.82, 1.0);
        }
    }
    if (settled >= 0.999f) {
        @synchronized (self) { _lastSettledDrawNs = drawableReadyNs; }
    }
    TrueLiquidLog(@"draw", [NSString stringWithFormat:@"\"n\":%lu,\"panel\":\"%@\",\"capture\":\"%@\",\"uv\":\"%.4f,%.4f,%.4f,%.4f\",\"frameAgeMs\":%.3f,\"drawableWaitMs\":%.3f,\"settled\":%.3f,\"latched\":%@,\"edgeDiagnostic\":%@",
                   (unsigned long)drawCount,
                   TrueLiquidRectDescription(panelRect),
                   TrueLiquidRectDescription(captureRect),
                   uvOrigin.x,
                   uvOrigin.y,
                   uvScale.x,
                   uvScale.y,
                   frameAgeMs,
                   drawableWaitMs,
                   settled,
                   latched ? @"true" : @"false",
                   edgeDiagnostic ? @"true" : @"false"]);

    TrueLiquidUniforms uniforms;
    uniforms.size = (vector_float2){(float)_metalLayer.drawableSize.width, (float)_metalLayer.drawableSize.height};
    uniforms.uvOrigin = uvOrigin;
    uniforms.uvScale = uvScale;
    uniforms.glassAlpha = style.glassAlpha;
    uniforms.tintAlpha = style.tintAlpha;
    uniforms.refraction = style.refraction;
    uniforms.curve = style.curve;
    uniforms.dispersion = style.dispersion;
    uniforms.frost = style.frost;
    uniforms.blur = style.blur;
    uniforms.saturation = style.saturation;
    uniforms.contrast = style.contrast;
    uniforms.luminanceClamp = style.luminanceClamp;
    uniforms.edge = style.edge;
    uniforms.depth = style.depth;
    uniforms.innerShadow = style.innerShadow;
    uniforms.cornerRadius = style.cornerRadius * scale;
    uniforms.settled = settled;
    uniforms.edgeDiagnostic = edgeDiagnostic ? 1.0f : 0.0f;

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (!commandBuffer) {
        if (cvTexture) CFRelease(cvTexture);
        return;
    }
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        if (cvTexture) CFRelease(cvTexture);
        return;
    }
    [encoder setRenderPipelineState:_pipeline];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:sourceTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    if (cvTexture) {
        CVMetalTextureRef textureToRelease = cvTexture;
        cvTexture = nil;
        [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> buffer) {
            CFRelease(textureToRelease);
        }];
    }
    [commandBuffer commit];
}

- (void)clearDrawable {
    if (!_commandQueue || self.hidden) return;
    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (!drawable) return;

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end

@implementation TrueLiquidCaptureOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    NSInteger status = -1;
    uint64_t frameHostTime = 0;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(attachments, 0);
        NSNumber *statusValue = info[SCStreamFrameInfoStatus];
        NSNumber *timeValue = info[SCStreamFrameInfoDisplayTime];
        if (statusValue) status = statusValue.integerValue;
        if (timeValue) {
            frameHostTime = TrueLiquidNormalizeHostTimeNs(timeValue.unsignedLongLongValue);
        }
    }

    [self.view renderPixelBuffer:pixelBuffer frameHostTime:frameHostTime status:status];
}
@end

@interface TrueLiquidCoordinator : NSObject
- (instancetype)initWithWindow:(NSWindow *)window metalView:(TrueLiquidMetalView *)metalView;
- (void)setNativePositionDragEnabled:(BOOL)enabled;
- (void)setNativePositionDragRegions:(const double *)rects count:(int)count;
- (void)beginNativePositionMove;
- (void)endNativePositionMove;
- (void)startTracking;
- (void)slide;
- (void)refreshAfterMoveSettles;
- (void)refresh;
- (void)renderSettled;
@end

@implementation TrueLiquidCoordinator {
    __weak NSWindow *_window;
    __weak TrueLiquidMetalView *_metalView;
    id _willMoveObserver;
    id _moveObserver;
    id _resizeObserver;
    id _screenObserver;
    id _eventMonitor;
    NSTimer *_trackingTimer;
    NSTimer *_settleTimer;
    NSTimer *_settledRenderTimer;
    BOOL _nativePositionDragEnabled;
    NSArray<NSValue *> *_nativePositionDragRegions;
    BOOL _nativeDragCandidate;
    BOOL _nativeDraggingWindow;
    NSPoint _nativeDragStartMouse;
    NSPoint _nativeDragStartOrigin;
    BOOL _nativeMoveActive;
    NSPoint _nativeMoveStartMouse;
    NSPoint _nativeMoveStartOrigin;
}

- (instancetype)initWithWindow:(NSWindow *)window metalView:(TrueLiquidMetalView *)metalView {
    self = [super init];
    if (!self) return nil;
    _window = window;
    _metalView = metalView;

    __weak TrueLiquidCoordinator *weakSelf = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSOperationQueue *queue = NSOperationQueue.mainQueue;
    _willMoveObserver = [center addObserverForName:NSWindowWillMoveNotification object:window queue:queue usingBlock:^(__unused NSNotification *note) {
        [weakSelf slide];
    }];
    _moveObserver = [center addObserverForName:NSWindowDidMoveNotification object:window queue:queue usingBlock:^(__unused NSNotification *note) {
        [weakSelf slide];
    }];
    _resizeObserver = [center addObserverForName:NSWindowDidResizeNotification object:window queue:queue usingBlock:^(__unused NSNotification *note) {
        [weakSelf slide];
    }];
    _screenObserver = [center addObserverForName:NSWindowDidChangeScreenNotification object:window queue:queue usingBlock:^(__unused NSNotification *note) {
        [weakSelf refresh];
    }];
    _eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp handler:^NSEvent *(NSEvent *event) {
        TrueLiquidCoordinator *strongSelf = weakSelf;
        if (strongSelf && [strongSelf handleNativePositionDragEvent:event]) {
            return nil;
        }
        if (strongSelf && event.window == strongSelf->_window) {
            if (event.type != NSEventTypeLeftMouseDragged) {
                [strongSelf slide];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf slide];
            });
        }
        return event;
    }];
    [self startTracking];
    return self;
}

- (BOOL)handleNativePositionDragEvent:(NSEvent *)event {
    if (!TrueLiquidNativePositionDragEnabled || !_nativePositionDragEnabled) return NO;
    NSWindow *window = _window;
    if (!window) return NO;

    if (event.type == NSEventTypeLeftMouseDown) {
        if (event.window != window || ![self nativePositionDragContainsEvent:event]) return NO;
        _nativeDragCandidate = YES;
        _nativeDraggingWindow = NO;
        _nativeDragStartMouse = [NSEvent mouseLocation];
        _nativeDragStartOrigin = window.frame.origin;
        return NO;
    }

    if (!_nativeDragCandidate && !_nativeDraggingWindow) return NO;

    if (event.type == NSEventTypeLeftMouseDragged) {
        NSPoint mouse = [NSEvent mouseLocation];
        CGFloat dx = mouse.x - _nativeDragStartMouse.x;
        CGFloat dy = mouse.y - _nativeDragStartMouse.y;
        if (!_nativeDraggingWindow && hypot(dx, dy) < 1.0) return NO;
        _nativeDraggingWindow = YES;
        [window setFrameOrigin:NSMakePoint(_nativeDragStartOrigin.x + dx, _nativeDragStartOrigin.y + dy)];
        return YES;
    }

    if (event.type == NSEventTypeLeftMouseUp) {
        BOOL handled = _nativeDraggingWindow;
        if (handled) {
            NSPoint mouse = [NSEvent mouseLocation];
            [window setFrameOrigin:NSMakePoint(
                _nativeDragStartOrigin.x + mouse.x - _nativeDragStartMouse.x,
                _nativeDragStartOrigin.y + mouse.y - _nativeDragStartMouse.y
            )];
        }
        _nativeDragCandidate = NO;
        _nativeDraggingWindow = NO;
        return handled;
    }

    return NO;
}

- (BOOL)nativePositionDragContainsEvent:(NSEvent *)event {
    if (_nativePositionDragRegions.count == 0) return YES;

    NSView *content = _window.contentView;
    if (!content) return NO;

    NSPoint point = [content convertPoint:event.locationInWindow fromView:nil];
    if (!content.isFlipped) point.y = content.bounds.size.height - point.y;

    for (NSValue *value in _nativePositionDragRegions) {
        if (NSPointInRect(point, value.rectValue)) return YES;
    }
    return NO;
}

- (void)setNativePositionDragEnabled:(BOOL)enabled {
    _nativePositionDragEnabled = enabled;
    if (!enabled) {
        _nativeDragCandidate = NO;
        _nativeDraggingWindow = NO;
    }
}

- (void)setNativePositionDragRegions:(const double *)rects count:(int)count {
    if (!rects || count <= 0) {
        _nativePositionDragRegions = nil;
        return;
    }

    NSMutableArray<NSValue *> *regions = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int i = 0; i < count; i++) {
        int offset = i * 4;
        CGFloat x = (CGFloat)rects[offset];
        CGFloat y = (CGFloat)rects[offset + 1];
        CGFloat width = (CGFloat)rects[offset + 2];
        CGFloat height = (CGFloat)rects[offset + 3];
        if (width > 0.5 && height > 0.5) {
            [regions addObject:[NSValue valueWithRect:NSMakeRect(x, y, width, height)]];
        }
    }
    _nativePositionDragRegions = regions.count > 0 ? regions.copy : nil;
}

- (void)beginNativePositionMove {
    if (!TrueLiquidNativePositionDragEnabled || !_nativePositionDragEnabled) return;

    NSWindow *window = _window;
    if (!window) return;

    _nativeMoveActive = YES;
    _nativeDragCandidate = NO;
    _nativeDraggingWindow = NO;
    _nativeMoveStartMouse = [NSEvent mouseLocation];
    _nativeMoveStartOrigin = window.frame.origin;
}

- (void)endNativePositionMove {
    [self updateNativePositionMove];
    _nativeMoveActive = NO;
}

- (BOOL)updateNativePositionMove {
    if (!_nativeMoveActive) return NO;

    NSWindow *window = _window;
    if (!window) {
        _nativeMoveActive = NO;
        return NO;
    }

    NSPoint mouse = [NSEvent mouseLocation];
    [window setFrameOrigin:NSMakePoint(
        _nativeMoveStartOrigin.x + mouse.x - _nativeMoveStartMouse.x,
        _nativeMoveStartOrigin.y + mouse.y - _nativeMoveStartMouse.y
    )];
    return YES;
}

- (void)startTracking {
    if (_trackingTimer) return;

    __weak TrueLiquidCoordinator *weakSelf = self;
    _trackingTimer = [NSTimer timerWithTimeInterval:(1.0 / 120.0) repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf updateNativePositionMove];
        [weakSelf slide];
    }];
    [NSRunLoop.mainRunLoop addTimer:_trackingTimer forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:_trackingTimer forMode:NSEventTrackingRunLoopMode];
}

- (void)slide {
    NSWindow *window = _window;
    TrueLiquidMetalView *metalView = _metalView;
    if (window && metalView && !metalView.hidden && [metalView slideForWindow:window]) {
        [self refreshAfterMoveSettles];
    }
}

- (void)refreshAfterMoveSettles {
    [_settleTimer invalidate];
    [_settledRenderTimer invalidate];
    __weak TrueLiquidCoordinator *weakSelf = self;
    _settleTimer = [NSTimer timerWithTimeInterval:0.14 repeats:NO block:^(__unused NSTimer *timer) {
        [weakSelf refresh];
    }];
    _settledRenderTimer = [NSTimer timerWithTimeInterval:0.30 repeats:NO block:^(__unused NSTimer *timer) {
        [weakSelf renderSettled];
    }];
    [NSRunLoop.mainRunLoop addTimer:_settleTimer forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:_settledRenderTimer forMode:NSRunLoopCommonModes];
}

- (void)refresh {
    NSWindow *window = _window;
    TrueLiquidMetalView *metalView = _metalView;
    if (window && metalView && !metalView.hidden) [metalView recenterForWindow:window];
}

- (void)renderSettled {
    NSWindow *window = _window;
    TrueLiquidMetalView *metalView = _metalView;
    if (window && metalView && !metalView.hidden) [metalView renderLatestFrame];
}

- (void)dealloc {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (_willMoveObserver) [center removeObserver:_willMoveObserver];
    if (_moveObserver) [center removeObserver:_moveObserver];
    if (_resizeObserver) [center removeObserver:_resizeObserver];
    if (_screenObserver) [center removeObserver:_screenObserver];
    if (_eventMonitor) [NSEvent removeMonitor:_eventMonitor];
    [_trackingTimer invalidate];
    [_settleTimer invalidate];
    [_settledRenderTimer invalidate];
}
@end

static NSWindow *BestApplicationWindow(void) {
    NSArray<NSWindow *> *windows = NSApp.orderedWindows.count > 0 ? NSApp.orderedWindows : NSApp.windows;
    for (NSWindow *window in windows) {
        if (!window.contentView || window.isMiniaturized) continue;
        if ([window.title containsString:@"True Liquid"]) return window;
    }
    for (NSWindow *window in windows) {
        if (!window.contentView || window.isMiniaturized) continue;
        if (window.isVisible && window.level == NSNormalWindowLevel) return window;
    }
    return windows.firstObject;
}

static NSWindow *ApplicationWindowNamed(const char *title) {
    NSString *needle = title ? [NSString stringWithUTF8String:title] : nil;
    if (needle.length == 0) return BestApplicationWindow();

    NSArray<NSWindow *> *windows = NSApp.orderedWindows.count > 0 ? NSApp.orderedWindows : NSApp.windows;
    for (NSWindow *window in windows) {
        if (!window.contentView || window.isMiniaturized) continue;
        if ([window.title isEqualToString:needle]) return window;
    }
    for (NSWindow *window in windows) {
        if (!window.contentView || window.isMiniaturized) continue;
        if ([window.title containsString:needle]) return window;
    }

    TrueLiquidLog(@"window-title-miss", [NSString stringWithFormat:@"\"title\":\"%@\"", needle]);
    return nil;
}

static NSWindow *TargetWindow(void *nativePointer, const char *title) {
    NSView *resolvedView = nil;
    NSWindow *window = nativePointer ? ResolveWindow(nativePointer, &resolvedView) : nil;
    if (window) return window;
    if (title && strlen(title) > 0) return ApplicationWindowNamed(title);
    return BestApplicationWindow();
}

static TrueLiquidCoordinator *CoordinatorForWindow(NSWindow *window) {
    NSView *content = window.contentView;
    NSView *container = [content.identifier isEqualToString:TrueLiquidContainerId] ? content : nil;
    return container ? objc_getAssociatedObject(container, &TrueLiquidCoordinatorKey) : nil;
}

static void InstallWindowOnMain(NSWindow *window, TrueLiquidNativeStyle style, BOOL nativeDragEnabled) {
    if (!window) return;

    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = NO;
    window.movableByWindowBackground = NO;
    window.sharingType = TrueLiquidWindowCaptureVisible ? NSWindowSharingReadOnly : NSWindowSharingNone;

    NSView *content = window.contentView;
    if (!content) return;

    NSView *container = nil;
    if ([content.identifier isEqualToString:TrueLiquidContainerId]) {
        container = content;
    } else {
        NSView *composeView = content;
        container = [[NSView alloc] initWithFrame:composeView.frame];
        container.identifier = TrueLiquidContainerId;
        container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        ConfigurePanelShadow(container, style.cornerRadius, style.outerShadow);

        composeView.frame = container.bounds;
        composeView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        ConfigureLayer(composeView, style.cornerRadius);

        window.contentView = container;
        [container addSubview:composeView positioned:NSWindowAbove relativeTo:nil];
    }

    ConfigurePanelShadow(container, style.cornerRadius, style.outerShadow);

    TrueLiquidMetalView *capture = (TrueLiquidMetalView *)FindDirectSubview(container, TrueLiquidCaptureId);
    if (!capture) {
        capture = [[TrueLiquidMetalView alloc] initWithFrame:container.bounds];
        [container addSubview:capture positioned:NSWindowBelow relativeTo:nil];
    }

    BOOL forceVisualEffect = style.mode == TrueLiquidModeVisualEffect;
    NSView *glass = FindDirectSubview(container, TrueLiquidGlassId);
    if (!glass) {
        glass = MakeNativeGlassView(container.bounds, style.cornerRadius, style.glassAlpha, style.tintAlpha, forceVisualEffect);
        [container addSubview:glass positioned:NSWindowAbove relativeTo:capture];
    }

    NSView *tint = FindDirectSubview(container, TrueLiquidTintId);
    if (!tint) {
        tint = [[NSView alloc] initWithFrame:container.bounds];
        tint.identifier = TrueLiquidTintId;
        tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [container addSubview:tint positioned:NSWindowAbove relativeTo:glass];
    }

    BOOL captureWanted = SupportsScreenCaptureKit() && (style.mode == TrueLiquidModeAuto || style.mode == TrueLiquidModeCaptureShader);
    TrueLiquidLog(@"install", [NSString stringWithFormat:@"\"mode\":%d,\"captureWanted\":%@,\"supportsSCK\":%@,\"glass\":%.3f,\"tint\":%.3f,\"refraction\":%.3f,\"curve\":%.3f,\"edge\":%.3f,\"depth\":%.3f,\"dispersion\":%.3f,\"scale\":%.3f,\"fps\":%d",
                   style.mode,
                   captureWanted ? @"true" : @"false",
                   SupportsScreenCaptureKit() ? @"true" : @"false",
                   style.glassAlpha,
                   style.tintAlpha,
                   style.refraction,
                   style.curve,
                   style.edge,
                   style.depth,
                   style.dispersion,
                   style.captureScale,
                   style.fps]);

    capture.frame = container.bounds;
    capture.alphaValue = 1.0;
    [capture applyStyle:style];
    capture.hidden = !captureWanted;
    if (captureWanted) {
        [capture startOrUpdateForWindow:window];
    } else {
        [capture stopCapture];
    }

    glass.frame = container.bounds;
    glass.hidden = captureWanted;
    glass.alphaValue = style.glassAlpha;
    glass.layer.cornerRadius = style.cornerRadius;
    glass.layer.masksToBounds = YES;
    if ([glass isKindOfClass:[NSVisualEffectView class]]) {
        ((NSVisualEffectView *)glass).material = FallbackMaterial();
        ((NSVisualEffectView *)glass).blendingMode = NSVisualEffectBlendingModeBehindWindow;
        ((NSVisualEffectView *)glass).state = NSVisualEffectStateActive;
    }
    if ([glass respondsToSelector:@selector(setCornerRadius:)]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)((id)glass, @selector(setCornerRadius:), (CGFloat)style.cornerRadius);
    }
    if ([glass respondsToSelector:@selector(setTintColor:)]) {
        NSColor *nativeTint = [NSColor colorWithCalibratedWhite:0.04 alpha:style.tintAlpha];
        ((void (*)(id, SEL, NSColor *))objc_msgSend)((id)glass, @selector(setTintColor:), nativeTint);
    }

    tint.frame = container.bounds;
    tint.hidden = captureWanted || style.tintAlpha <= 0.001f;
    tint.wantsLayer = YES;
    tint.layer.cornerRadius = style.cornerRadius;
    tint.layer.masksToBounds = YES;
    tint.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.04 alpha:style.tintAlpha].CGColor;

    for (NSView *view in container.subviews) {
        if (view != capture && view != glass && view != tint) {
            view.alphaValue = 1.0;
            ConfigureLayerTree(view, style.cornerRadius);
            [container addSubview:view positioned:NSWindowAbove relativeTo:tint];
        }
    }
    if (captureWanted) {
        [container addSubview:capture positioned:NSWindowBelow relativeTo:nil];
    }

    TrueLiquidCoordinator *coordinator = objc_getAssociatedObject(container, &TrueLiquidCoordinatorKey);
    if (!coordinator) {
        coordinator = [[TrueLiquidCoordinator alloc] initWithWindow:window metalView:capture];
        objc_setAssociatedObject(container, &TrueLiquidCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [coordinator setNativePositionDragEnabled:nativeDragEnabled];
}

static void InstallOnMain(void *nativePointer, TrueLiquidNativeStyle style, BOOL nativeDragEnabled) {
    NSView *resolvedView = nil;
    InstallWindowOnMain(ResolveWindow(nativePointer, &resolvedView), style, nativeDragEnabled);
}

static void PulseWindowOnMain(NSWindow *window) {
    if (!window) return;

    NSView *content = window.contentView;
    if (!content) return;
    NSView *container = [content.identifier isEqualToString:TrueLiquidContainerId] ? content : nil;
    if (!container) return;

    TrueLiquidMetalView *capture = (TrueLiquidMetalView *)FindDirectSubview(container, TrueLiquidCaptureId);
    if (!capture || capture.hidden) return;
    [capture pulseForWindow:window];
}

static void PulseOnMain(void *nativePointer) {
    NSView *resolvedView = nil;
    PulseWindowOnMain(ResolveWindow(nativePointer, &resolvedView));
}

static void SetNativePositionDragRegionsOnMain(NSWindow *window, NSData *regionData, int count) {
    TrueLiquidCoordinator *coordinator = CoordinatorForWindow(window);
    if (!coordinator) return;
    [coordinator setNativePositionDragRegions:regionData ? (const double *)regionData.bytes : nil count:count];
}

static void BeginNativePositionMoveOnMain(NSWindow *window) {
    [CoordinatorForWindow(window) beginNativePositionMove];
}

static void EndNativePositionMoveOnMain(NSWindow *window) {
    [CoordinatorForWindow(window) endNativePositionMove];
}

extern "C" int TrueLiquid_supportsGlassEffect(void) {
    return NSClassFromString(@"NSGlassEffectView") ? 1 : 0;
}

extern "C" void TrueLiquid_configureInstrumentation(int enabled, const char *path) {
    TrueLiquidConfigureInstrumentation(enabled == 1, path);
}

extern "C" void TrueLiquid_configureWindowCaptureVisibility(int visible) {
    TrueLiquidWindowCaptureVisible = visible == 1;
}

extern "C" void TrueLiquid_configureNativePositionDrag(int enabled) {
    TrueLiquidNativePositionDragEnabled = enabled == 1;
}

extern "C" int TrueLiquid_supportsScreenCaptureKit(void) {
    return SupportsScreenCaptureKit() ? 1 : 0;
}

extern "C" int TrueLiquid_hasScreenCapturePermission(void) {
    if (@available(macOS 10.15, *)) return CGPreflightScreenCaptureAccess() ? 1 : 0;
    return 1;
}

extern "C" void TrueLiquid_pulse(void *nativePointer) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PulseOnMain(nativePointer);
    });
}

extern "C" void TrueLiquid_pulseActiveWindow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PulseWindowOnMain(BestApplicationWindow());
    });
}

extern "C" void TrueLiquid_pulseWindowNamed(const char *title) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PulseWindowOnMain(ApplicationWindowNamed(title));
    });
}

extern "C" void TrueLiquid_setNativePositionDragRegions(void *nativePointer, const char *title, const double *rects, int count) {
    int safeCount = rects && count > 0 ? MIN(count, 128) : 0;
    NSData *regionData = safeCount > 0 ? [NSData dataWithBytes:rects length:sizeof(double) * (NSUInteger)safeCount * 4] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        SetNativePositionDragRegionsOnMain(TargetWindow(nativePointer, title), regionData, safeCount);
    });
}

extern "C" void TrueLiquid_beginNativeWindowMove(void *nativePointer, const char *title) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BeginNativePositionMoveOnMain(TargetWindow(nativePointer, title));
    });
}

extern "C" void TrueLiquid_endNativeWindowMove(void *nativePointer, const char *title) {
    dispatch_async(dispatch_get_main_queue(), ^{
        EndNativePositionMoveOnMain(TargetWindow(nativePointer, title));
    });
}

extern "C" void TrueLiquid_install(
    void *nativePointer,
    double glassAlpha,
    double tintAlpha,
    double refraction,
    double curve,
    double dispersion,
    double frost,
    double blur,
    double saturation,
    double contrast,
    double luminanceClamp,
    double edge,
    double depth,
    double innerShadow,
    double outerShadow,
    double cornerRadius,
    double captureScale,
    int fps,
    int mode,
    int nativeDragEnabled
) {
    TrueLiquidNativeStyle style = MakeStyle(
        glassAlpha,
        tintAlpha,
        refraction,
        curve,
        dispersion,
        frost,
        blur,
        saturation,
        contrast,
        luminanceClamp,
        edge,
        depth,
        innerShadow,
        outerShadow,
        cornerRadius,
        captureScale,
        fps,
        mode
    );
    dispatch_async(dispatch_get_main_queue(), ^{
        InstallOnMain(nativePointer, style, nativeDragEnabled != 0);
    });
}

extern "C" void TrueLiquid_installWindowNamed(
    const char *title,
    double glassAlpha,
    double tintAlpha,
    double refraction,
    double curve,
    double dispersion,
    double frost,
    double blur,
    double saturation,
    double contrast,
    double luminanceClamp,
    double edge,
    double depth,
    double innerShadow,
    double outerShadow,
    double cornerRadius,
    double captureScale,
    int fps,
    int mode,
    int nativeDragEnabled
) {
    TrueLiquidNativeStyle style = MakeStyle(
        glassAlpha,
        tintAlpha,
        refraction,
        curve,
        dispersion,
        frost,
        blur,
        saturation,
        contrast,
        luminanceClamp,
        edge,
        depth,
        innerShadow,
        outerShadow,
        cornerRadius,
        captureScale,
        fps,
        mode
    );
    dispatch_async(dispatch_get_main_queue(), ^{
        InstallWindowOnMain(ApplicationWindowNamed(title), style, nativeDragEnabled != 0);
    });
}

extern "C" void TrueLiquid_installActiveWindow(
    double glassAlpha,
    double tintAlpha,
    double refraction,
    double curve,
    double dispersion,
    double frost,
    double blur,
    double saturation,
    double contrast,
    double luminanceClamp,
    double edge,
    double depth,
    double innerShadow,
    double outerShadow,
    double cornerRadius,
    double captureScale,
    int fps,
    int mode,
    int nativeDragEnabled
) {
    TrueLiquidNativeStyle style = MakeStyle(
        glassAlpha,
        tintAlpha,
        refraction,
        curve,
        dispersion,
        frost,
        blur,
        saturation,
        contrast,
        luminanceClamp,
        edge,
        depth,
        innerShadow,
        outerShadow,
        cornerRadius,
        captureScale,
        fps,
        mode
    );
    dispatch_async(dispatch_get_main_queue(), ^{
        InstallWindowOnMain(BestApplicationWindow(), style, nativeDragEnabled != 0);
    });
}
