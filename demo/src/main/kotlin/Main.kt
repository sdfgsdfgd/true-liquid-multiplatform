import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import io.github.trueliquid.compose.TrueLiquidDefaults
import io.github.trueliquid.compose.TrueLiquidMode
import io.github.trueliquid.compose.TrueLiquidRuntime
import io.github.trueliquid.compose.TrueLiquidStyle
import io.github.trueliquid.compose.TrueLiquidWindow
import io.github.trueliquid.compose.trueLiquidDragRegion
import kotlin.math.roundToInt

fun main(args: Array<String>) = application {
    TrueLiquidRuntime.configureProcess()

    val title = System.getProperty("trueLiquid.title")?.takeIf { it.isNotBlank() } ?: "True Liquid Compose"
    val initiallyExpanded = args.contains("--expanded") || System.getProperty("trueLiquid.defaultExpanded") == "true"
    val defaultStyle = initialStyle(args)
    val windowState = rememberWindowState(
        size = DpSize(
            TrueLiquidDefaults.windowWidth,
            if (initiallyExpanded) TrueLiquidDefaults.expandedHeight else TrueLiquidDefaults.collapsedHeight,
        ),
        position = WindowPosition.Aligned(Alignment.Center),
    )

    var expanded by remember { mutableStateOf(initiallyExpanded) }
    var mode by remember { mutableStateOf(defaultStyle.mode) }
    var glassAlpha by remember { mutableFloatStateOf(defaultStyle.glassAlpha) }
    var tintAlpha by remember { mutableFloatStateOf(defaultStyle.tintAlpha) }
    var refraction by remember { mutableFloatStateOf(defaultStyle.refraction) }
    var curve by remember { mutableFloatStateOf(defaultStyle.curve) }
    var dispersion by remember { mutableFloatStateOf(defaultStyle.dispersion) }
    var frost by remember { mutableFloatStateOf(defaultStyle.frost) }
    var blur by remember { mutableFloatStateOf(defaultStyle.blur) }
    var saturation by remember { mutableFloatStateOf(defaultStyle.saturation) }
    var contrast by remember { mutableFloatStateOf(defaultStyle.contrast) }
    var luminanceClamp by remember { mutableFloatStateOf(defaultStyle.luminanceClamp) }
    var edge by remember { mutableFloatStateOf(defaultStyle.edge) }
    var depth by remember { mutableFloatStateOf(defaultStyle.depth) }
    var innerShadow by remember { mutableFloatStateOf(defaultStyle.innerShadow) }
    var outerShadow by remember { mutableFloatStateOf(defaultStyle.outerShadow) }
    var cornerRadius by remember { mutableFloatStateOf(defaultStyle.cornerRadius) }
    var captureScale by remember { mutableFloatStateOf(defaultStyle.captureScale) }
    var fps by remember { mutableFloatStateOf(defaultStyle.fps.toFloat()) }

    val targetHeight = if (expanded) TrueLiquidDefaults.expandedHeight else TrueLiquidDefaults.collapsedHeight
    val height by animateDpAsState(targetHeight, label = "panelHeight")
    val style = TrueLiquidStyle(
        glassAlpha = glassAlpha,
        tintAlpha = tintAlpha,
        refraction = refraction,
        curve = curve,
        dispersion = dispersion,
        frost = frost,
        blur = blur,
        saturation = saturation,
        contrast = contrast,
        luminanceClamp = luminanceClamp,
        edge = edge,
        depth = depth,
        innerShadow = innerShadow,
        outerShadow = outerShadow,
        cornerRadius = cornerRadius,
        captureScale = captureScale,
        fps = fps.roundToInt(),
        mode = mode,
    )

    LaunchedEffect(height) {
        windowState.size = DpSize(TrueLiquidDefaults.windowWidth, height)
    }

    TrueLiquidWindow(
        title = title,
        state = windowState,
        onCloseRequest = ::exitApplication,
        style = style,
    ) {
        TrueLiquidSpotlightPanel(
            style = style,
            backend = backendState.label,
            expanded = expanded,
            onToggleExpanded = { expanded = !expanded },
            onGlassAlpha = { glassAlpha = it },
            onTintAlpha = { tintAlpha = it },
            onRefraction = { refraction = it },
            onCurve = { curve = it },
            onDispersion = { dispersion = it },
            onFrost = { frost = it },
            onBlur = { blur = it },
            onSaturation = { saturation = it },
            onContrast = { contrast = it },
            onLuminanceClamp = { luminanceClamp = it },
            onEdge = { edge = it },
            onDepth = { depth = it },
            onInnerShadow = { innerShadow = it },
            onOuterShadow = { outerShadow = it },
            onCornerRadius = { cornerRadius = it },
            onCaptureScale = { captureScale = it },
            onFps = { fps = it },
            onMode = {
                val modes = TrueLiquidMode.entries
                mode = modes[(modes.indexOf(mode) + 1) % modes.size]
            },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun TrueLiquidSpotlightPanel(
    style: TrueLiquidStyle,
    backend: String,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
    onGlassAlpha: (Float) -> Unit,
    onTintAlpha: (Float) -> Unit,
    onRefraction: (Float) -> Unit,
    onCurve: (Float) -> Unit,
    onDispersion: (Float) -> Unit,
    onFrost: (Float) -> Unit,
    onBlur: (Float) -> Unit,
    onSaturation: (Float) -> Unit,
    onContrast: (Float) -> Unit,
    onLuminanceClamp: (Float) -> Unit,
    onEdge: (Float) -> Unit,
    onDepth: (Float) -> Unit,
    onInnerShadow: (Float) -> Unit,
    onOuterShadow: (Float) -> Unit,
    onCornerRadius: (Float) -> Unit,
    onCaptureScale: (Float) -> Unit,
    onFps: (Float) -> Unit,
    onMode: () -> Unit,
) {
    var query by remember { mutableStateOf("true liquid command palette") }
    val shape = RoundedCornerShape(style.cornerRadius.dp)
    val expandedAlpha by animateFloatAsState(if (expanded) 1f else 0f, label = "expandedAlpha")

    Box(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(
                    listOf(
                        Color.White.copy(alpha = 0.34f),
                        Color(0xFFBFF9FF).copy(alpha = 0.18f + style.edge * 0.16f),
                        Color.Black.copy(alpha = 0.22f),
                    ),
                    start = Offset.Zero,
                    end = Offset(920f, 520f),
                ),
                shape = shape,
            )
            .padding(20.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Canvas(Modifier.size(44.dp).trueLiquidDragRegion()) {
                    drawCircle(
                        brush = Brush.radialGradient(
                            listOf(
                                Color.White.copy(alpha = 0.95f),
                                Color(0xFF82F7FF).copy(alpha = 0.18f),
                                Color.Transparent,
                            ),
                        ),
                    )
                    drawCircle(
                        color = Color.White.copy(alpha = 0.62f + style.edge * 0.20f),
                        style = Stroke(width = 1.4.dp.toPx()),
                    )
                }
                Spacer(Modifier.width(15.dp).height(44.dp).trueLiquidDragRegion())
                Column(Modifier.weight(1f)) {
                    BasicTextField(
                        value = query,
                        onValueChange = { query = it },
                        singleLine = true,
                        textStyle = TextStyle(
                            color = Color.White.copy(alpha = 0.95f),
                            fontSize = 24.sp,
                            fontWeight = FontWeight.Medium,
                            letterSpacing = 0.sp,
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "$backend  |  ${style.mode.label}  |  ${style.fps} fps @ ${(style.captureScale * 100).roundToInt()}%",
                        modifier = Modifier.trueLiquidDragRegion(),
                        color = Color.White.copy(alpha = 0.60f),
                        fontSize = 12.sp,
                        letterSpacing = 0.sp,
                    )
                }
                Text(
                    if (expanded) "collapse" else "expand",
                    color = Color.White.copy(alpha = 0.72f),
                    fontSize = 13.sp,
                    modifier = Modifier.clickable(onClick = onToggleExpanded),
                )
            }

            if (expandedAlpha > 0.01f) {
                Column(
                    Modifier.alpha(expandedAlpha),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    ResultRow("Native baseline", "NSGlassEffectView stays one click away")
                    ResultRow("Capture rectangle", "ScreenCaptureKit samples only this panel area")
                    ResultRow("Metal underlay", "IOSurface is shaded below Compose foreground")
                    ResultRow("No tint path", "readability comes from luminance, frost, refraction, edge")

                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        Control("glass", style.glassAlpha, onGlassAlpha, Modifier.weight(1f))
                        Control("tint", style.tintAlpha, onTintAlpha, Modifier.weight(1f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        Control("refraction", style.refraction, onRefraction, Modifier.weight(1f))
                        Control("curve", style.curve, onCurve, Modifier.weight(1f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        Control("dispersion", style.dispersion, onDispersion, Modifier.weight(1f))
                        Control("edge", style.edge, onEdge, Modifier.weight(1f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        Control("frost", style.frost, onFrost, Modifier.weight(1f))
                        Control("blur", style.blur, onBlur, Modifier.weight(1f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        RangeControl("saturation", style.saturation, 0f, 2f, onSaturation, Modifier.weight(1f))
                        RangeControl("contrast", style.contrast, -1f, 1f, onContrast, Modifier.weight(1f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        Control("luminance", style.luminanceClamp, onLuminanceClamp, Modifier.weight(1f))
                        Control("depth", style.depth, onDepth, Modifier.weight(1f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                        Control("inner shadow", style.innerShadow, onInnerShadow, Modifier.weight(1f))
                        Control("outer shadow", style.outerShadow, onOuterShadow, Modifier.weight(1f))
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        RangeControl("scale", style.captureScale, 0.25f, 1f, onCaptureScale, Modifier.weight(1f))
                        Spacer(Modifier.width(18.dp))
                        RangeControl("fps", style.fps.toFloat(), 15f, 120f, onFps, Modifier.weight(1f), decimals = 0)
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        RangeControl("radius", style.cornerRadius, 12f, 64f, onCornerRadius, Modifier.weight(1f), decimals = 0)
                        Spacer(Modifier.width(20.dp))
                        Text(
                            style.mode.label,
                            modifier = Modifier
                                .clip(RoundedCornerShape(999.dp))
                                .background(Color.White.copy(alpha = 0.12f))
                                .clickable(onClick = onMode)
                                .padding(horizontal = 16.dp, vertical = 9.dp),
                            color = Color.White.copy(alpha = 0.84f),
                            fontSize = 13.sp,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ResultRow(title: String, detail: String) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(Color.Black.copy(alpha = 0.16f))
            .padding(horizontal = 16.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(9.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(Color(0xFFB5F7FF).copy(alpha = 0.86f)),
        )
        Spacer(Modifier.width(13.dp))
        Column {
            Text(title, color = Color.White.copy(alpha = 0.88f), fontSize = 15.sp)
            Text(detail, color = Color.White.copy(alpha = 0.48f), fontSize = 12.sp)
        }
    }
}

@Composable
private fun Control(
    label: String,
    value: Float,
    onValue: (Float) -> Unit,
    modifier: Modifier = Modifier,
) = RangeControl(label, value, 0f, 1f, onValue, modifier)

@Composable
private fun RangeControl(
    label: String,
    value: Float,
    from: Float,
    to: Float,
    onValue: (Float) -> Unit,
    modifier: Modifier = Modifier,
    decimals: Int = 2,
) {
    Column(modifier) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(label, color = Color.White.copy(alpha = 0.58f), fontSize = 12.sp)
            Text(
                value.formatValue(decimals),
                color = Color.White.copy(alpha = 0.43f),
                fontSize = 12.sp,
            )
        }
        Slider(
            value = value.coerceIn(from, to),
            onValueChange = onValue,
            valueRange = from..to,
        )
    }
}

private fun Float.formatValue(decimals: Int): String =
    if (decimals == 0) roundToInt().toString() else "%.${decimals}f".format(this)

private fun initialStyle(args: Array<String>): TrueLiquidStyle {
    val preset = args.firstOrNull { it.startsWith("--preset=") }?.substringAfter("=")
        ?: System.getProperty("trueLiquid.preset")
    return when (preset?.trim()?.lowercase()) {
        "clear", "lens", "clearlens", "clear-lens" -> TrueLiquidDefaults.clearLensStyle()
        "prism", "strong", "optical" -> TrueLiquidDefaults.prismStyle()
        "native", "nativeglass", "native-glass" -> TrueLiquidDefaults.nativeGlassStyle()
        else -> TrueLiquidDefaults.spotlightStyle()
    }
}
