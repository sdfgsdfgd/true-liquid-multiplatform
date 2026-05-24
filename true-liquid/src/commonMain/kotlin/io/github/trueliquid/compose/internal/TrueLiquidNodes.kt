// Portions adapted from FletchMcKee/liquid, Apache-2.0.
package io.github.trueliquid.compose.internal

import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.node.CompositionLocalConsumerModifierNode
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.node.GlobalPositionAwareModifierNode
import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.node.TraversableNode
import androidx.compose.ui.node.currentValueOf
import androidx.compose.ui.node.findNearestAncestor
import androidx.compose.ui.node.invalidateDraw
import androidx.compose.ui.platform.InspectorInfo
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalGraphicsContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.toSize
import androidx.compose.ui.unit.toIntSize
import androidx.compose.ui.util.fastCoerceAtMost
import androidx.compose.ui.util.fastForEach
import androidx.compose.ui.geometry.isUnspecified
import io.github.trueliquid.compose.TrueLiquidState
import io.github.trueliquid.compose.TrueLiquidStyle
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.sqrt

internal class TrueLiquidSource {
    var layer: GraphicsLayer? = null
    var boundsOnScreen: Rect = Rect.Zero
}

internal class TrueLiquidSourceElement(
    private val state: TrueLiquidState,
) : ModifierNodeElement<TrueLiquidSourceNode>() {
    override fun create(): TrueLiquidSourceNode =
        TrueLiquidSourceNode(state)

    override fun update(node: TrueLiquidSourceNode) {
        node.state = state
    }

    override fun InspectorInfo.inspectableProperties() {
        name = "trueLiquidSource"
    }

    override fun equals(other: Any?): Boolean =
        other is TrueLiquidSourceElement && state === other.state

    override fun hashCode(): Int =
        state.hashCode()
}

internal class TrueLiquidSourceNode(
    var state: TrueLiquidState,
) : Modifier.Node(),
    CompositionLocalConsumerModifierNode,
    DrawModifierNode,
    GlobalPositionAwareModifierNode,
    TraversableNode {
    companion object Key

    override val traverseKey: Any = Key
    val source = TrueLiquidSource()

    override val shouldAutoInvalidate: Boolean = false

    override fun onAttach() {
        state.sources += source
    }

    override fun onDetach() = Snapshot.withMutableSnapshot {
        state.sources -= source
        source.layer?.let { currentValueOf(LocalGraphicsContext).releaseGraphicsLayer(it) }
        source.layer = null
        source.boundsOnScreen = Rect.Zero
    }

    override fun onGloballyPositioned(coordinates: LayoutCoordinates) {
        source.boundsOnScreen = Rect(
            offset = coordinates.trueLiquidPositionOnScreen(),
            size = coordinates.size.toSize(),
        )
    }

    override fun ContentDrawScope.draw() {
        if (size.minDimension < 1f) {
            drawContent()
            return
        }
        val layer = Snapshot.withoutReadObservation { obtainLayer() }
        layer.record(size.toIntSize()) {
            this@draw.drawContent()
        }
        drawLayer(layer)
    }

    private fun obtainLayer(): GraphicsLayer =
        source.layer?.takeUnless { it.isReleased }
            ?: currentValueOf(LocalGraphicsContext).createGraphicsLayer().also { source.layer = it }
}

internal fun trueLiquidSurfaceElement(
    state: TrueLiquidState,
    style: TrueLiquidStyle,
    shape: Shape,
): ModifierNodeElement<TrueLiquidSurfaceNode> =
    TrueLiquidSurfaceElement(state, style, shape)

private class TrueLiquidSurfaceElement(
    private val state: TrueLiquidState,
    private val style: TrueLiquidStyle,
    private val shape: Shape,
) : ModifierNodeElement<TrueLiquidSurfaceNode>() {
    override fun create(): TrueLiquidSurfaceNode =
        TrueLiquidSurfaceNode(state, style, shape)

    override fun update(node: TrueLiquidSurfaceNode) {
        node.state = state
        node.style = style
        node.shape = shape
        node.invalidateLiquid()
    }

    override fun InspectorInfo.inspectableProperties() {
        name = "trueLiquidSurface"
        properties["style"] = style
        properties["shape"] = shape
    }

    override fun equals(other: Any?): Boolean =
        other is TrueLiquidSurfaceElement &&
            state === other.state &&
            style == other.style &&
            shape == other.shape

    override fun hashCode(): Int {
        var result = state.hashCode()
        result = 31 * result + style.hashCode()
        result = 31 * result + shape.hashCode()
        return result
    }
}

internal class TrueLiquidSurfaceNode(
    var state: TrueLiquidState,
    var style: TrueLiquidStyle,
    var shape: Shape,
) : Modifier.Node(),
    CompositionLocalConsumerModifierNode,
    DrawModifierNode,
    GlobalPositionAwareModifierNode {
    private val matrix = Matrix()
    private var layer: GraphicsLayer? = null
    private var positionOnScreen = Offset.Unspecified
    private var boundsInRoot = Rect.Zero
    private var inverseScaleX = 1f
    private var inverseScaleY = 1f
    private var inverseRotationZ = 0f
    private var renderConfig: TrueLiquidRenderConfig? = null

    override val shouldAutoInvalidate: Boolean = false

    override fun onDetach() {
        layer?.let { currentValueOf(LocalGraphicsContext).releaseGraphicsLayer(it) }
        layer = null
        renderConfig = null
    }

    override fun onGloballyPositioned(coordinates: LayoutCoordinates) {
        if (!isAttached) return

        matrix.reset()
        coordinates.transformToScreen(matrix)
        val scaleX = matrix.values[Matrix.ScaleX]
        val scaleY = matrix.values[Matrix.ScaleY]
        val skewX = matrix.values[Matrix.SkewX]
        val skewY = matrix.values[Matrix.SkewY]
        val scaleXMagnitude = sqrt(scaleX * scaleX + skewY * skewY)
        val scaleYMagnitude = sqrt(skewX * skewX + scaleY * scaleY)

        positionOnScreen = coordinates.trueLiquidPositionOnScreen()
        boundsInRoot = coordinates.boundsInRoot()
        inverseScaleX = if (scaleXMagnitude > 0f) 1f / scaleXMagnitude else 0f
        inverseScaleY = if (scaleYMagnitude > 0f) 1f / scaleYMagnitude else 0f
        inverseRotationZ = -RadiansToDegrees * atan2(skewY, scaleX)
        invalidateLiquid()
    }

    fun invalidateLiquid() {
        if (isAttached) invalidateDraw()
    }

    override fun ContentDrawScope.draw() {
        if (size.minDimension < 1f || positionOnScreen.isUnspecified) {
            drawContent()
            return
        }

        val targetLayer = obtainLayer()
        val sources = Snapshot.withoutReadObservation {
            val ancestor = findNearestAncestor(TrueLiquidSourceNode.Key)
                ?.let { it as? TrueLiquidSourceNode }
                ?.source
            state.sources.filter { it !== ancestor }
        }

        if (sources.isNotEmpty()) {
            targetLayer.record(size.toIntSize().nonEmpty()) {
                sources.fastForEach { source ->
                    source.layer
                        ?.takeUnless { it.isReleased }
                        ?.let { sourceLayer ->
                            val offset = source.boundsOnScreen.topLeft - positionOnScreen
                            withTransform({
                                rotate(degrees = inverseRotationZ, pivot = Offset.Zero)
                                scale(scaleX = inverseScaleX, scaleY = inverseScaleY, pivot = Offset.Zero)
                                translate(left = offset.x, top = offset.y)
                            }) {
                                drawLayer(sourceLayer)
                            }
                        }
                }
            }
            val config = renderConfig()
            if (config != renderConfig) {
                renderConfig = config
                targetLayer.renderEffect = createTrueLiquidRenderEffect(config)
            }
            drawLayer(targetLayer)
        }

        drawContent()
    }

    private fun obtainLayer(): GraphicsLayer =
        layer?.takeUnless { it.isReleased }
            ?: currentValueOf(LocalGraphicsContext).createGraphicsLayer().also { layer = it }

    private fun ContentDrawScope.renderConfig(): TrueLiquidRenderConfig {
        val density = currentValueOf(LocalDensity)
        return TrueLiquidRenderConfig(
            size = size,
            cornerRadii = shape.normalizedCornerRadii(size, density, currentValueOf(LocalLayoutDirection)),
            glassAlpha = style.glassAlpha.coerceIn(0f, 1f),
            tintAlpha = style.tintAlpha.coerceIn(0f, 1f),
            refraction = style.refraction.coerceIn(0f, 1f),
            curve = style.curve.coerceIn(0f, 1f),
            dispersion = style.dispersion.coerceIn(0f, 1f),
            frostPx = style.frost.coerceIn(0f, 1f) * 24f,
            blurPx = style.blur.coerceIn(0f, 1f) * 24f,
            saturation = style.saturation.coerceIn(0f, 2f),
            contrast = 1f + style.contrast.coerceIn(-1f, 1f),
            luminanceClamp = style.luminanceClamp.coerceIn(0f, 1f),
            edge = style.edge.coerceIn(0f, 1f),
            depth = style.depth.coerceIn(0f, 1f),
        )
    }
}

private fun Shape.normalizedCornerRadii(
    size: Size,
    density: Density,
    layoutDirection: LayoutDirection,
): FloatArray = when (this) {
    CircleShape -> {
        val radius = size.minDimension * 0.5f
        floatArrayOf(radius, radius, radius, radius)
    }

    is RoundedCornerShape -> {
        if (size.minDimension <= 0f) {
            Float4Zero
        } else {
            val maxRadius = size.minDimension * 0.5f
            val topStart = topStart.toPx(size, density).fastCoerceAtMost(maxRadius)
            val topEnd = topEnd.toPx(size, density).fastCoerceAtMost(maxRadius)
            val bottomEnd = bottomEnd.toPx(size, density).fastCoerceAtMost(maxRadius)
            val bottomStart = bottomStart.toPx(size, density).fastCoerceAtMost(maxRadius)
            if (layoutDirection == LayoutDirection.Ltr) {
                floatArrayOf(topStart, topEnd, bottomEnd, bottomStart)
            } else {
                floatArrayOf(topEnd, topStart, bottomStart, bottomEnd)
            }
        }
    }

    else -> Float4Zero
}

private fun IntSize.nonEmpty(): IntSize =
    IntSize(width.coerceAtLeast(1), height.coerceAtLeast(1))

private val Float4Zero = floatArrayOf(0f, 0f, 0f, 0f)
private const val RadiansToDegrees = (180.0 / PI).toFloat()
