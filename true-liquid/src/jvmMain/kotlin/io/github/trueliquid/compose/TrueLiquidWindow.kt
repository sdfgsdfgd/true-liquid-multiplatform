package io.github.trueliquid.compose

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.window.WindowDraggableArea
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.composed
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.awt.ComposeWindow
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowState
import kotlinx.coroutines.delay

object TrueLiquidRuntime {
    fun configureProcess() {
        System.setProperty("compose.interop.blending", "true")
        System.setProperty("sun.awt.noerasebackground", "true")
        System.setProperty("sun.awt.erasebackgroundonresize", "false")
        System.setProperty("skiko.renderApi", "METAL")
        System.setProperty("SKIKO_CLEAR_COLOR", "0x00000000")
    }
}

private val LocalTrueLiquidDragRegions = staticCompositionLocalOf<TrueLiquidDragRegions?> { null }

fun Modifier.trueLiquidDragRegion(enabled: Boolean = true): Modifier = composed {
    val registry = LocalTrueLiquidDragRegions.current
    val id = remember(registry) { registry?.nextId() }
    val density = LocalDensity.current.density
    DisposableEffect(registry, id, enabled) {
        if (!enabled && id != null) registry?.remove(id)
        onDispose { if (id != null) registry?.remove(id) }
    }
    if (enabled && registry != null && id != null) {
        onGloballyPositioned {
            val bounds = it.boundsInWindow()
            registry.set(
                id,
                Rect(
                    bounds.left / density,
                    bounds.top / density,
                    bounds.right / density,
                    bounds.bottom / density,
                )
            )
        }
    } else {
        this
    }
}

class TrueLiquidWindowScope internal constructor(
    private val boxScope: BoxScope,
    val window: ComposeWindow,
    val backendState: TrueLiquidBackendState,
) : BoxScope by boxScope {
    fun beginWindowMove() = TrueLiquidNative.beginWindowMove(window)
    fun endWindowMove() = TrueLiquidNative.endWindowMove(window)
}

private class TrueLiquidDragRegions(private val window: ComposeWindow) {
    private var nextId = 0
    private val regions = linkedMapOf<Int, Rect>()

    fun nextId() = nextId++

    fun set(id: Int, rect: Rect) {
        if (regions[id] == rect) return
        regions[id] = rect
        sync()
    }

    fun remove(id: Int) {
        if (regions.remove(id) != null) sync()
    }

    fun clear() {
        if (regions.isEmpty()) return
        regions.clear()
        sync()
    }

    fun sync() {
        TrueLiquidNative.setNativeDragRegions(window, regions.values)
    }
}

@Composable
fun TrueLiquidWindow(
    title: String,
    state: WindowState,
    style: TrueLiquidStyle,
    onCloseRequest: () -> Unit,
    modifier: Modifier = Modifier,
    contentAlignment: Alignment = Alignment.TopCenter,
    alwaysOnTop: Boolean = true,
    resizable: Boolean = true,
    draggable: Boolean = true,
    content: @Composable TrueLiquidWindowScope.() -> Unit,
) {
    Window(
        title = title,
        state = state,
        undecorated = true,
        transparent = true,
        alwaysOnTop = alwaysOnTop,
        resizable = resizable,
        onCloseRequest = onCloseRequest,
    ) {
        val dragRegions = remember(window) { TrueLiquidDragRegions(window) }
        DisposableEffect(dragRegions) {
            onDispose { dragRegions.clear() }
        }
        val nativeDrag = draggable && TrueLiquidNative.nativePositionDragEnabled
        LaunchedEffect(style, nativeDrag) {
            repeat(InstallPasses) {
                TrueLiquidNative.install(window, style, nativeDrag)
                dragRegions.sync()
                delay(InstallDelayMs)
            }
        }

        CompositionLocalProvider(LocalTrueLiquidDragRegions provides dragRegions) {
            val panel: @Composable () -> Unit = {
                Box(modifier.fillMaxSize(), contentAlignment = contentAlignment) {
                    TrueLiquidWindowScope(this, window, TrueLiquidNative.backendState(style.mode)).content()
                }
            }
            if (draggable && !nativeDrag) {
                WindowDraggableArea(content = panel)
            } else {
                panel()
            }
        }
    }
}

private const val InstallPasses = 12
private const val InstallDelayMs = 80L
