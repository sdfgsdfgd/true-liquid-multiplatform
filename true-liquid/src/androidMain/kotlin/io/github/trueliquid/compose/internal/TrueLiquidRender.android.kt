// Portions adapted from FletchMcKee/liquid and Kyant0/AndroidLiquidGlass, Apache-2.0.
package io.github.trueliquid.compose.internal

import android.graphics.RenderEffect
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.os.Build
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.positionOnScreen

internal actual fun createTrueLiquidRenderEffect(
    config: TrueLiquidRenderConfig,
): androidx.compose.ui.graphics.RenderEffect? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null

    val shader = RuntimeShader(TrueLiquidShader).apply {
        setFloatUniform("size", config.size.width, config.size.height)
        setFloatUniform("cornerRadii", config.cornerRadii)
        setFloatUniform("glassAlpha", config.glassAlpha)
        setFloatUniform("tintAlpha", config.tintAlpha)
        setFloatUniform("refraction", config.refraction)
        setFloatUniform("curve", config.curve)
        setFloatUniform("dispersion", config.dispersion)
        setFloatUniform("saturation", config.saturation)
        setFloatUniform("contrast", config.contrast)
        setFloatUniform("luminanceClamp", config.luminanceClamp)
        setFloatUniform("edge", config.edge)
        setFloatUniform("depth", config.depth)
    }

    val liquid = RenderEffect.createRuntimeShaderEffect(shader, "content")
    val blurRadius = config.frostPx + config.blurPx
    return if (blurRadius >= 1f) {
        RenderEffect
            .createChainEffect(
                liquid,
                RenderEffect.createBlurEffect(blurRadius, blurRadius, Shader.TileMode.CLAMP),
            )
            .asComposeRenderEffect()
    } else {
        liquid.asComposeRenderEffect()
    }
}

internal actual fun LayoutCoordinates.trueLiquidPositionOnScreen(): Offset =
    positionOnScreen()
