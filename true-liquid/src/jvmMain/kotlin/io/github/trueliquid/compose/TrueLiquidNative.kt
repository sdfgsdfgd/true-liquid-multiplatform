package io.github.trueliquid.compose

import androidx.compose.ui.awt.ComposeWindow
import androidx.compose.ui.geometry.Rect
import com.sun.jna.Library
import com.sun.jna.Native
import com.sun.jna.Pointer
import java.awt.Color
import java.awt.Component
import java.awt.EventQueue
import java.awt.Window
import java.lang.reflect.Field
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import javax.swing.JComponent

internal object TrueLiquidNative {
    private val isMac = System.getProperty("os.name").contains("Mac", ignoreCase = true)
    private var pointerDebugLogged = false
    val nativePositionDragEnabled: Boolean
        get() {
            if (!isMac) return false
            System.getProperty("trueLiquid.nativePositionDrag")?.takeIf { it.isNotBlank() }?.let {
                return it == "1" || it.equals("true", ignoreCase = true)
            }
            System.getenv("TRUE_LIQUID_NATIVE_POSITION_DRAG")?.takeIf { it.isNotBlank() }?.let {
                return it == "1" || it.equals("true", ignoreCase = true)
            }
            return true
        }

    private val lib: NativeApi? by lazy {
        if (!isMac) return@lazy null
        val path = System.getProperty("trueLiquid.native.lib")
            ?.takeIf { it.isNotBlank() }
            ?: bundledNativePath()
            ?: error("Missing -DtrueLiquid.native.lib and bundled macOS native library")
        Native.load(path, NativeApi::class.java).also { api ->
            val enabled = System.getProperty("trueLiquid.instrument") == "true"
            val logPath = System.getProperty("trueLiquid.instrument.path")
                ?.takeIf { it.isNotBlank() }
                ?: "/tmp/true-liquid-compose-${ProcessHandle.current().pid()}.jsonl"
            api.TrueLiquid_configureInstrumentation(enabled.nativeFlag, logPath)
            api.TrueLiquid_configureWindowCaptureVisibility(
                (System.getProperty("trueLiquid.instrument.captureWindow") == "true").nativeFlag
            )
            api.TrueLiquid_configureNativePositionDrag(nativePositionDragEnabled.nativeFlag)
        }
    }

    private fun bundledNativePath(): String? {
        val resource = "true-liquid/native/macos/libTrueLiquidNative.dylib"
        val loader = TrueLiquidNative::class.java.classLoader
        return loader.getResourceAsStream(resource)?.use { input ->
            val temp = Files.createTempFile("true-liquid-native-", ".dylib")
            Files.copy(input, temp, StandardCopyOption.REPLACE_EXISTING)
            temp.toFile().deleteOnExit()
            temp.toAbsolutePath().toString()
        }
    }

    fun install(
        window: ComposeWindow,
        style: TrueLiquidStyle,
        nativeDragEnabled: Boolean = nativePositionDragEnabled,
    ) =
        update(window, style, nativeDragEnabled)

    fun pulse(window: ComposeWindow) {
        if (!isMac) return
        EventQueue.invokeLater {
            val api = lib ?: return@invokeLater
            val pointer = nativePointer(window)
            if (pointer != null) {
                api.TrueLiquid_pulse(pointer)
            } else {
                val title = window.title?.takeIf { it.isNotBlank() }
                if (title != null) {
                    instrumentLog("kotlin-pulse-title", "\"title\":\"${json(title)}\"")
                    api.TrueLiquid_pulseWindowNamed(title)
                } else {
                    instrumentLog("kotlin-pulse-active", "")
                    api.TrueLiquid_pulseActiveWindow()
                }
            }
        }
    }

    fun beginWindowMove(window: ComposeWindow) =
        setWindowMove(window, active = true)

    fun endWindowMove(window: ComposeWindow) =
        setWindowMove(window, active = false)

    internal fun setNativeDragRegions(window: ComposeWindow, regions: Collection<Rect>) {
        if (!isMac) return
        val validRegions = regions.filter { it.width > 0.5f && it.height > 0.5f }
        val rects = DoubleArray(validRegions.size * 4)
        validRegions.forEachIndexed { index, rect ->
            val offset = index * 4
            rects[offset] = rect.left.toDouble()
            rects[offset + 1] = rect.top.toDouble()
            rects[offset + 2] = rect.width.toDouble()
            rects[offset + 3] = rect.height.toDouble()
        }
        EventQueue.invokeLater {
            val api = lib ?: return@invokeLater
            api.TrueLiquid_setNativePositionDragRegions(
                nativePointer(window),
                window.title?.takeIf { it.isNotBlank() },
                rects,
                rects.size / 4,
            )
        }
    }

    private fun setWindowMove(window: ComposeWindow, active: Boolean) {
        if (!isMac) return
        EventQueue.invokeLater {
            val api = lib ?: return@invokeLater
            val pointer = nativePointer(window)
            val title = window.title?.takeIf { it.isNotBlank() }
            if (active) {
                api.TrueLiquid_beginNativeWindowMove(pointer, title)
            } else {
                api.TrueLiquid_endNativeWindowMove(pointer, title)
            }
        }
    }

    fun update(
        window: ComposeWindow,
        style: TrueLiquidStyle,
        nativeDragEnabled: Boolean = nativePositionDragEnabled,
    ) {
        if (!isMac) return
        EventQueue.invokeLater {
            forceTransparentHost(window)
            val api = lib ?: return@invokeLater
            val pointer = nativePointer(window)
            if (pointer == null) {
                instrumentLog(
                    "kotlin-pointer-miss",
                    "\"displayable\":${window.isDisplayable},\"showing\":${window.isShowing},\"focused\":${window.isFocused}"
                )
                instrumentPointerDebug(window)
                val title = window.title?.takeIf { it.isNotBlank() }
                if (title != null) {
                    instrumentLog("kotlin-install-title", "\"title\":\"${json(title)}\"")
                } else {
                    instrumentLog("kotlin-install-active", "")
                }
                api.install(style, title = title, nativeDragEnabled = nativeDragEnabled)
                return@invokeLater
            }
            instrumentLog("kotlin-install-call", "\"ptr\":${Pointer.nativeValue(pointer)}")
            api.install(style, pointer, nativeDragEnabled = nativeDragEnabled)
        }
    }

    private fun NativeApi.install(
        style: TrueLiquidStyle,
        pointer: Pointer? = null,
        title: String? = null,
        nativeDragEnabled: Boolean = nativePositionDragEnabled,
    ) {
        val glassAlpha = style.glassAlpha.coerceIn(0f, 1f).toDouble()
        val tintAlpha = style.tintAlpha.coerceIn(0f, 1f).toDouble()
        val refraction = style.refraction.coerceIn(0f, 1f).toDouble()
        val curve = style.curve.coerceIn(0f, 1f).toDouble()
        val dispersion = style.dispersion.coerceIn(0f, 1f).toDouble()
        val frost = style.frost.coerceIn(0f, 1f).toDouble()
        val blur = style.blur.coerceIn(0f, 1f).toDouble()
        val saturation = style.saturation.coerceIn(0f, 2f).toDouble()
        val contrast = style.contrast.coerceIn(-1f, 1f).toDouble()
        val luminanceClamp = style.luminanceClamp.coerceIn(0f, 1f).toDouble()
        val edge = style.edge.coerceIn(0f, 1f).toDouble()
        val depth = style.depth.coerceIn(0f, 1f).toDouble()
        val innerShadow = style.innerShadow.coerceIn(0f, 1f).toDouble()
        val outerShadow = style.outerShadow.coerceIn(0f, 1f).toDouble()
        val cornerRadius = style.cornerRadius.coerceAtLeast(0f).toDouble()
        val captureScale = style.captureScale.coerceIn(0.25f, 1f).toDouble()
        val fps = style.fps.coerceIn(15, 120)
        val mode = style.mode.nativeCode
        val nativeDrag = nativeDragEnabled.nativeFlag
        if (pointer != null) {
            TrueLiquid_install(
                pointer,
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
                mode,
                nativeDrag,
            )
        } else if (!title.isNullOrBlank()) {
            TrueLiquid_installWindowNamed(
                title,
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
                mode,
                nativeDrag,
            )
        } else {
            TrueLiquid_installActiveWindow(
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
                mode,
                nativeDrag,
            )
        }
    }

    private fun instrumentLog(event: String, fields: String = "") {
        if (System.getProperty("trueLiquid.instrument") != "true") return
        val path = System.getProperty("trueLiquid.instrument.path")
            ?.takeIf { it.isNotBlank() }
            ?: return
        val suffix = if (fields.isBlank()) "" else ",$fields"
        val line = "{\"t\":${System.nanoTime() / 1_000_000.0},\"event\":\"$event\"$suffix}\n"
        runCatching {
            Files.writeString(
                Path.of(path),
                line,
                StandardOpenOption.CREATE,
                StandardOpenOption.APPEND,
            )
        }
    }

    private fun instrumentPointerDebug(window: Window) {
        if (pointerDebugLogged) return
        pointerDebugLogged = true
        val peer = runCatching { findField(Component::class.java, "peer")?.get(window) }.getOrNull()
        val platform = peer?.let { value ->
            runCatching { findField(value.javaClass, "platformWindow")?.get(value) }.getOrNull()
        }
        val methods = platform
            ?.javaClass
            ?.methods
            ?.asSequence()
            ?.map { it.name }
            ?.filter {
                it.contains("window", ignoreCase = true) ||
                    it.contains("ptr", ignoreCase = true) ||
                    it.contains("ns", ignoreCase = true)
            }
            ?.distinct()
            ?.take(24)
            ?.joinToString("|")
            .orEmpty()
        val fields = platform
            ?.javaClass
            ?.declaredFields
            ?.asSequence()
            ?.map { it.name }
            ?.filter {
                it.contains("window", ignoreCase = true) ||
                    it.contains("ptr", ignoreCase = true) ||
                    it.contains("ns", ignoreCase = true)
            }
            ?.distinct()
            ?.take(24)
            ?.joinToString("|")
            .orEmpty()
        instrumentLog(
            "kotlin-pointer-debug",
            "\"windowClass\":\"${json(window.javaClass.name)}\"," +
                "\"peerClass\":\"${json(peer?.javaClass?.name.orEmpty())}\"," +
                "\"platformClass\":\"${json(platform?.javaClass?.name.orEmpty())}\"," +
                "\"platformMethods\":\"${json(methods)}\"," +
                "\"platformFields\":\"${json(fields)}\""
        )
    }

    private fun json(value: String): String =
        value.replace("\\", "\\\\").replace("\"", "\\\"")

    private val Boolean.nativeFlag: Int
        get() = if (this) 1 else 0

    private fun forceTransparentHost(window: ComposeWindow) {
        val clear = Color(0, 0, 0, 0)
        window.background = clear
        window.rootPane.background = clear
        window.rootPane.isOpaque = false
        (window.contentPane as? JComponent)?.isOpaque = false
        window.contentPane.background = clear
    }

    fun screenCapturePermissionStatus(): TrueLiquidScreenCapturePermission {
        if (!isMac) return TrueLiquidScreenCapturePermission.Unsupported
        val api = lib ?: return TrueLiquidScreenCapturePermission.Unsupported
        if (api.TrueLiquid_supportsScreenCaptureKit() != 1) {
            return TrueLiquidScreenCapturePermission.Unsupported
        }
        return if (api.TrueLiquid_hasScreenCapturePermission() == 1) {
            TrueLiquidScreenCapturePermission.Granted
        } else {
            TrueLiquidScreenCapturePermission.NotGranted
        }
    }

    fun openScreenRecordingSettings(): Boolean {
        if (!isMac) return false
        return runCatching {
            ProcessBuilder(
                "open",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            ).start()
            true
        }.getOrDefault(false)
    }

    fun backendState(mode: TrueLiquidMode): TrueLiquidBackendState {
        if (!isMac) {
            return TrueLiquidBackendState(
                backend = TrueLiquidBackend.Noop,
                screenCapturePermission = TrueLiquidScreenCapturePermission.Unsupported,
                label = "Non-macOS noop",
            )
        }
        val api = lib
        val hasGlass = api?.TrueLiquid_supportsGlassEffect() == 1
        val hasCapture = api?.TrueLiquid_supportsScreenCaptureKit() == 1
        val permission = screenCapturePermissionStatus()
        return when (mode) {
            TrueLiquidMode.Auto -> when {
                hasCapture -> TrueLiquidBackendState(
                    backend = TrueLiquidBackend.CaptureShader,
                    screenCapturePermission = permission,
                    label = "CaptureShaderLayer${if (permission == TrueLiquidScreenCapturePermission.Granted) "" else " | permission pending"}",
                )
                hasGlass -> TrueLiquidBackendState(
                    backend = TrueLiquidBackend.NativeGlass,
                    screenCapturePermission = permission,
                    label = "NSGlassEffectView",
                )
                else -> TrueLiquidBackendState(
                    backend = TrueLiquidBackend.VisualEffect,
                    screenCapturePermission = permission,
                    label = "NSVisualEffectView",
                )
            }
            TrueLiquidMode.CaptureShader -> TrueLiquidBackendState(
                backend = if (hasCapture) TrueLiquidBackend.CaptureShader else TrueLiquidBackend.Noop,
                screenCapturePermission = permission,
                label = if (hasCapture) {
                    "CaptureShaderLayer${if (permission == TrueLiquidScreenCapturePermission.Granted) "" else " | permission pending"}"
                } else {
                    "Capture unavailable"
                },
            )
            TrueLiquidMode.NativeGlass -> TrueLiquidBackendState(
                backend = if (hasGlass) TrueLiquidBackend.NativeGlass else TrueLiquidBackend.VisualEffect,
                screenCapturePermission = permission,
                label = if (hasGlass) "NSGlassEffectView" else "NSVisualEffectView fallback",
            )
            TrueLiquidMode.VisualEffect -> TrueLiquidBackendState(
                backend = TrueLiquidBackend.VisualEffect,
                screenCapturePermission = permission,
                label = "NSVisualEffectView",
            )
        }
    }

    fun runtimeBackend(mode: TrueLiquidMode): String {
        return backendState(mode).label
    }

    private fun nativePointer(window: ComposeWindow): Pointer? {
        val direct = runCatching { Native.getComponentPointer(window) }.getOrNull()
            ?: runCatching { Native.getWindowPointer(window) }.getOrNull()
        if (direct != null && Pointer.nativeValue(direct) != 0L) return direct

        return reflectedNSWindowPtr(window)?.takeIf { it != 0L }?.let(::Pointer)
    }

    private fun reflectedNSWindowPtr(window: Window): Long? {
        val peer = findField(Component::class.java, "peer")
            ?.get(window)
            ?: return null

        val platformWindow = findField(peer.javaClass, "platformWindow")
            ?.get(peer)
            ?: return null

        val methods = platformWindow.javaClass.methods + platformWindow.javaClass.declaredMethods
        methods.firstOrNull { it.name == "getNSWindowPtr" && it.parameterCount == 0 }?.let { method ->
            method.isAccessible = true
            return (method.invoke(platformWindow) as? Number)?.toLong()
        }

        return listOf("ptr", "nsWindowPtr", "windowPtr")
            .firstNotNullOfOrNull { name ->
                findField(platformWindow.javaClass, name)
                    ?.get(platformWindow)
                    ?.let { it as? Number }
                    ?.toLong()
            }
    }

    private fun findField(type: Class<*>, name: String): Field? =
        generateSequence(type) { it.superclass }
            .firstNotNullOfOrNull { cls ->
                runCatching {
                    cls.getDeclaredField(name).apply { isAccessible = true }
                }.getOrNull()
            }

    private interface NativeApi : Library {
        fun TrueLiquid_supportsGlassEffect(): Int
        fun TrueLiquid_configureInstrumentation(enabled: Int, path: String)
        fun TrueLiquid_configureWindowCaptureVisibility(visible: Int)
        fun TrueLiquid_configureNativePositionDrag(enabled: Int)
        fun TrueLiquid_supportsScreenCaptureKit(): Int
        fun TrueLiquid_hasScreenCapturePermission(): Int
        fun TrueLiquid_pulse(nativePointer: Pointer)
        fun TrueLiquid_pulseActiveWindow()
        fun TrueLiquid_pulseWindowNamed(title: String)
        fun TrueLiquid_setNativePositionDragRegions(
            nativePointer: Pointer?,
            title: String?,
            rects: DoubleArray,
            count: Int,
        )
        fun TrueLiquid_beginNativeWindowMove(nativePointer: Pointer?, title: String?)
        fun TrueLiquid_endNativeWindowMove(nativePointer: Pointer?, title: String?)
        fun TrueLiquid_install(
            nativePointer: Pointer,
            glassAlpha: Double,
            tintAlpha: Double,
            refraction: Double,
            curve: Double,
            dispersion: Double,
            frost: Double,
            blur: Double,
            saturation: Double,
            contrast: Double,
            luminanceClamp: Double,
            edge: Double,
            depth: Double,
            innerShadow: Double,
            outerShadow: Double,
            cornerRadius: Double,
            captureScale: Double,
            fps: Int,
            mode: Int,
            nativeDragEnabled: Int,
        )
        fun TrueLiquid_installWindowNamed(
            title: String,
            glassAlpha: Double,
            tintAlpha: Double,
            refraction: Double,
            curve: Double,
            dispersion: Double,
            frost: Double,
            blur: Double,
            saturation: Double,
            contrast: Double,
            luminanceClamp: Double,
            edge: Double,
            depth: Double,
            innerShadow: Double,
            outerShadow: Double,
            cornerRadius: Double,
            captureScale: Double,
            fps: Int,
            mode: Int,
            nativeDragEnabled: Int,
        )
        fun TrueLiquid_installActiveWindow(
            glassAlpha: Double,
            tintAlpha: Double,
            refraction: Double,
            curve: Double,
            dispersion: Double,
            frost: Double,
            blur: Double,
            saturation: Double,
            contrast: Double,
            luminanceClamp: Double,
            edge: Double,
            depth: Double,
            innerShadow: Double,
            outerShadow: Double,
            cornerRadius: Double,
            captureScale: Double,
            fps: Int,
            mode: Int,
            nativeDragEnabled: Int,
        )
    }
}
