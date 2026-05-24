package io.github.trueliquid.compose

enum class TrueLiquidScreenCapturePermission {
    Granted,
    NotGranted,
    Unsupported,
}

enum class TrueLiquidBackend {
    CaptureShader,
    NativeGlass,
    VisualEffect,
    Noop,
}

data class TrueLiquidBackendState(
    val backend: TrueLiquidBackend,
    val screenCapturePermission: TrueLiquidScreenCapturePermission,
    val label: String,
)

object TrueLiquidPermissions {
    fun screenCaptureStatus(): TrueLiquidScreenCapturePermission =
        TrueLiquidNative.screenCapturePermissionStatus()

    fun openScreenRecordingSettings(): Boolean =
        TrueLiquidNative.openScreenRecordingSettings()
}
