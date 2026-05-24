package io.github.trueliquid.compose

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Shape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp
import io.github.trueliquid.compose.internal.TrueLiquidSource
import io.github.trueliquid.compose.internal.TrueLiquidSourceElement
import io.github.trueliquid.compose.internal.trueLiquidSurfaceElement

@Stable
class TrueLiquidState {
    internal val sources = mutableStateListOf<TrueLiquidSource>()
}

@Composable
fun rememberTrueLiquidState(): TrueLiquidState =
    remember { TrueLiquidState() }

fun Modifier.trueLiquidSource(state: TrueLiquidState): Modifier =
    this then TrueLiquidSourceElement(state)

fun Modifier.trueLiquidSurface(
    state: TrueLiquidState,
    style: TrueLiquidStyle = TrueLiquidDefaults.spotlightStyle(),
    shape: Shape = RoundedCornerShape(style.cornerRadius.dp),
): Modifier =
    this then trueLiquidSurfaceElement(state, style, shape)
