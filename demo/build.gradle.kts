import org.jetbrains.compose.desktop.application.dsl.TargetFormat
import org.jetbrains.compose.reload.gradle.ComposeHotRun

plugins {
    kotlin("jvm")
    id("org.jetbrains.compose")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.compose.hot-reload")
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    implementation(project(":true-liquid"))
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
}

val trueLiquidNativeOut = project(":true-liquid").layout.buildDirectory.file("native/libTrueLiquidNative.dylib")

tasks.withType<JavaExec>().configureEach {
    dependsOn(":true-liquid:buildMacTrueLiquidNative")
    fun sys(name: String, default: String = "") = providers.systemProperty(name).getOrElse(default)
    systemProperty("trueLiquid.native.lib", trueLiquidNativeOut.get().asFile.absolutePath)
    systemProperty("trueLiquid.instrument", sys("trueLiquid.instrument", "false"))
    systemProperty("trueLiquid.instrument.path", sys("trueLiquid.instrument.path"))
    systemProperty("trueLiquid.instrument.captureWindow", sys("trueLiquid.instrument.captureWindow", "false"))
    systemProperty("trueLiquid.defaultExpanded", sys("trueLiquid.defaultExpanded", "false"))
    systemProperty("trueLiquid.preset", sys("trueLiquid.preset"))
    systemProperty("trueLiquid.title", sys("trueLiquid.title"))
    environment("TRUE_LIQUID_EDGE_DIAGNOSTIC", sys("trueLiquid.edgeDiagnostic"))
    jvmArgs(
        "-Dcompose.interop.blending=true",
        "-Dsun.awt.noerasebackground=true",
        "-Dsun.awt.erasebackgroundonresize=false",
        "-Dskiko.renderApi=METAL",
        "-DSKIKO_CLEAR_COLOR=0x00000000",
        "--add-opens=java.desktop/java.awt=ALL-UNNAMED",
        "--add-opens=java.desktop/sun.awt=ALL-UNNAMED",
        "--add-opens=java.desktop/sun.lwawt=ALL-UNNAMED",
        "--add-opens=java.desktop/sun.lwawt.macosx=ALL-UNNAMED",
    )
}

tasks.withType<ComposeHotRun>().configureEach {
    dependsOn(":true-liquid:buildMacTrueLiquidNative")
}

compose.desktop {
    application {
        mainClass = "MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Dmg)
            packageName = "TrueLiquidCompose"
            packageVersion = "1.0.0"
            macOS {
                bundleID = "local.trueliquid.compose"
            }
        }
    }
}
