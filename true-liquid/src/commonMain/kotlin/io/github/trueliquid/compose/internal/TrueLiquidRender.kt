// Portions adapted from FletchMcKee/liquid and Kyant0/AndroidLiquidGlass, Apache-2.0.
package io.github.trueliquid.compose.internal

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.RenderEffect
import androidx.compose.ui.layout.LayoutCoordinates

internal data class TrueLiquidRenderConfig(
    val size: Size,
    val cornerRadii: FloatArray,
    val glassAlpha: Float,
    val tintAlpha: Float,
    val refraction: Float,
    val curve: Float,
    val dispersion: Float,
    val frostPx: Float,
    val blurPx: Float,
    val saturation: Float,
    val contrast: Float,
    val luminanceClamp: Float,
    val edge: Float,
    val depth: Float,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TrueLiquidRenderConfig) return false
        return size == other.size &&
            cornerRadii.contentEquals(other.cornerRadii) &&
            glassAlpha == other.glassAlpha &&
            tintAlpha == other.tintAlpha &&
            refraction == other.refraction &&
            curve == other.curve &&
            dispersion == other.dispersion &&
            frostPx == other.frostPx &&
            blurPx == other.blurPx &&
            saturation == other.saturation &&
            contrast == other.contrast &&
            luminanceClamp == other.luminanceClamp &&
            edge == other.edge &&
            depth == other.depth
    }

    override fun hashCode(): Int {
        var result = size.hashCode()
        result = 31 * result + cornerRadii.contentHashCode()
        result = 31 * result + glassAlpha.hashCode()
        result = 31 * result + tintAlpha.hashCode()
        result = 31 * result + refraction.hashCode()
        result = 31 * result + curve.hashCode()
        result = 31 * result + dispersion.hashCode()
        result = 31 * result + frostPx.hashCode()
        result = 31 * result + blurPx.hashCode()
        result = 31 * result + saturation.hashCode()
        result = 31 * result + contrast.hashCode()
        result = 31 * result + luminanceClamp.hashCode()
        result = 31 * result + edge.hashCode()
        result = 31 * result + depth.hashCode()
        return result
    }
}

internal expect fun createTrueLiquidRenderEffect(config: TrueLiquidRenderConfig): RenderEffect?

internal expect fun LayoutCoordinates.trueLiquidPositionOnScreen(): Offset

internal const val TrueLiquidShader = """
  uniform shader content;
  uniform float2 size;
  uniform float4 cornerRadii;
  uniform float glassAlpha;
  uniform float tintAlpha;
  uniform float refraction;
  uniform float curve;
  uniform float dispersion;
  uniform float saturation;
  uniform float contrast;
  uniform float luminanceClamp;
  uniform float edge;
  uniform float depth;

  const float AA_WIDTH_PX = 1.5;

  float radiusAt(float2 coord, float4 radii) {
    if (coord.x >= 0.0) {
      if (coord.y <= 0.0) return radii.y;
      return radii.z;
    }
    if (coord.y <= 0.0) return radii.x;
    return radii.w;
  }

  float sdRoundedRect(float2 coord, float2 halfSize, float radius) {
    float2 q = abs(coord) - (halfSize - float2(radius));
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
  }

  float2 gradRoundedRect(float2 coord, float2 halfSize, float radius) {
    float2 q = abs(coord) - (halfSize - float2(radius));
    if (q.x >= 0.0 || q.y >= 0.0) {
      return sign(coord) * normalize(max(q, 0.0001));
    }
    float gx = step(q.y, q.x);
    return sign(coord) * float2(gx, 1.0 - gx);
  }

  float circleMap(float x) {
    return 1.0 - sqrt(max(0.0, 1.0 - x * x));
  }

  half3 adjustColor(half3 color) {
    float lum = dot(color, half3(0.2126, 0.7152, 0.0722));
    color = saturate(mix(half3(lum), color, saturation));
    color = saturate((color - 0.5) * contrast + 0.5);
    float lifted = max(max(color.r, color.g), color.b);
    color = max(color, half3(min(lifted, luminanceClamp)));
    return color;
  }

  half4 main(float2 coord) {
    float2 halfSize = size * 0.5;
    float2 centered = coord - halfSize;
    float radius = radiusAt(centered, cornerRadii);
    float sd = sdRoundedRect(centered, halfSize, radius);
    float aaWidth = AA_WIDTH_PX;
    if (sd > aaWidth) {
      return half4(0.0);
    }

    float2 grad = gradRoundedRect(centered, halfSize, min(radius * 1.5, min(halfSize.x, halfSize.y)));
    float2 depthGrad = normalize(centered + 0.0001);
    float2 normal = normalize(grad + depth * depthGrad);
    float2 sampleCoord = coord;

    if (refraction > 0.0 && curve > 0.0) {
      float h = max(1.0, refraction * min(size.x, size.y));
      float d = circleMap(1.0 - clamp(-sd / h, 0.0, 1.0)) * curve * min(size.x, size.y);
      sampleCoord = coord + d * normal;
    }

    half4 color;
    if (dispersion > 0.0) {
      float2 aberration = normal * dispersion * max(1.0, -sd);
      half4 r = content.eval(sampleCoord + aberration);
      half4 g = content.eval(sampleCoord);
      half4 b = content.eval(sampleCoord - aberration);
      color = half4(r.r, g.g, b.b, g.a);
    } else {
      color = content.eval(sampleCoord);
    }

    if (color.a <= 0.0) {
      color = content.eval(coord);
    }

    color.rgb = adjustColor(color.rgb);
    color.rgb = mix(color.rgb, half3(1.0), tintAlpha);

    float edgeBand = smoothstep(-max(0.001, edge * min(size.x, size.y)), 0.0, sd);
    float light = edgeBand * abs(dot(normal, normalize(float2(-0.35, -0.45))));
    color.rgb += half3(light * edge);

    float alpha = (1.0 - smoothstep(-aaWidth * 0.5, aaWidth * 0.5, sd)) * glassAlpha;
    return half4(color.rgb, color.a * alpha);
  }
"""
