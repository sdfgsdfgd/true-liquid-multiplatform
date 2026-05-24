package io.github.trueliquid.compose

import androidx.compose.runtime.Immutable

@Immutable
data class TrueLiquidStyle(
    val glassAlpha: Float,
    val tintAlpha: Float,
    val refraction: Float,
    val curve: Float,
    val dispersion: Float,
    val frost: Float,
    val blur: Float,
    val saturation: Float,
    val contrast: Float,
    val luminanceClamp: Float,
    val edge: Float,
    val depth: Float,
    val innerShadow: Float,
    val outerShadow: Float,
    val cornerRadius: Float,
    val captureScale: Float,
    val fps: Int,
    val mode: TrueLiquidMode,
)

enum class TrueLiquidMode(val nativeCode: Int, val label: String) {
    Auto(0, "Auto"),
    NativeGlass(1, "Native Glass"),
    CaptureShader(2, "Capture Shader"),
    VisualEffect(3, "Visual Effect"),
}
