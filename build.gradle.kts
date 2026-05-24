plugins {
    kotlin("jvm") version "2.1.21" apply false
    kotlin("multiplatform") version "2.1.21" apply false
    id("com.android.library") version "8.8.2" apply false
    id("org.jetbrains.compose") version "1.9.0-beta01" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.21" apply false
    id("org.jetbrains.compose.hot-reload") version "1.0.0-beta04" apply false
    id("com.vanniktech.maven.publish") version "0.34.0" apply false
}

allprojects {
    group = "io.github.sdfgsdfgd"
    version = "0.1.0-alpha02"
}

tasks.register("classes") {
    dependsOn(":true-liquid:jvmMainClasses", ":demo:classes")
}

tasks.register("buildMacTrueLiquidNative") {
    dependsOn(":true-liquid:buildMacTrueLiquidNative")
}

tasks.register("run") {
    dependsOn(":demo:run")
}

tasks.register<Exec>("verifyZenith10") {
    group = "verification"
    description = "Runs the hard video drag regression used to guard the zenith-10 macOS smoothness path."
    commandLine(
        "python3",
        "tools/true_liquid_score_run.py",
        "--launch-app",
        "--default-expanded",
        "--hide-app-from-capture",
        "--capture-backend",
        "video",
        "--frames",
        "260",
        "--fps",
        "60",
        "--steps",
        "180",
        "--step-ms",
        "8",
        "--deltas",
        "620,0:-620,0",
        "--pad",
        "220,80",
        "--probe-ms",
        "300,700,1100,1500,1900",
        "--probe-count",
        "5",
        "--outlier-probes",
        "3",
        "--drag-anomalies",
        "--run-root",
        "/tmp/true-liquid-zenith10-regression",
    )
}
