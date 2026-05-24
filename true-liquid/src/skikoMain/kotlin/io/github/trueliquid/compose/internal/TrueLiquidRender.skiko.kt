// Portions adapted from FletchMcKee/liquid, Apache-2.0.
package io.github.trueliquid.compose.internal

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.RenderEffect
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.positionInWindow
import org.jetbrains.skia.FilterTileMode
import org.jetbrains.skia.ImageFilter
import org.jetbrains.skia.RuntimeEffect
import org.jetbrains.skia.RuntimeShaderBuilder

internal actual fun createTrueLiquidRenderEffect(config: TrueLiquidRenderConfig): RenderEffect? {
    val shader = RuntimeShaderBuilder(RuntimeEffect.makeForShader(TrueLiquidShader)).apply {
        uniform("size", config.size.width, config.size.height)
        uniform("cornerRadii", config.cornerRadii)
        uniform("glassAlpha", config.glassAlpha)
        uniform("tintAlpha", config.tintAlpha)
        uniform("refraction", config.refraction)
        uniform("curve", config.curve)
        uniform("dispersion", config.dispersion)
        uniform("saturation", config.saturation)
        uniform("contrast", config.contrast)
        uniform("luminanceClamp", config.luminanceClamp)
        uniform("edge", config.edge)
        uniform("depth", config.depth)
    }
    val blurRadius = config.frostPx + config.blurPx
    val blur = if (blurRadius >= 1f) {
        ImageFilter.makeBlur(
            sigmaX = blurRadius,
            sigmaY = blurRadius,
            mode = FilterTileMode.CLAMP,
        )
    } else {
        null
    }
    return ImageFilter
        .makeRuntimeShader(
            runtimeShaderBuilder = shader,
            shaderNames = arrayOf("content"),
            inputs = arrayOf(blur),
        )
        .asComposeRenderEffect()
}

internal actual fun LayoutCoordinates.trueLiquidPositionOnScreen(): Offset =
    positionInWindow()
