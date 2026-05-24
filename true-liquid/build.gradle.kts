import org.gradle.api.tasks.Copy
import org.gradle.api.publish.maven.MavenPublication
import org.jetbrains.kotlin.gradle.ExperimentalWasmDsl

plugins {
    kotlin("multiplatform")
    id("com.android.library")
    id("org.jetbrains.compose")
    id("org.jetbrains.kotlin.plugin.compose")
    `maven-publish`
}

base {
    archivesName.set("true-liquid")
}

kotlin {
    applyDefaultHierarchyTemplate()
    jvmToolchain(21)

    jvm()

    androidTarget {
        publishLibraryVariants("release")
    }

    iosArm64()
    iosSimulatorArm64()
    macosArm64()

    @OptIn(ExperimentalWasmDsl::class)
    wasmJs {
        browser()
    }

    js(IR) {
        browser()
    }

    sourceSets {
        commonMain.dependencies {
            api(compose.runtime)
            api(compose.ui)
            implementation(compose.foundation)
        }

        val skikoMain by creating {
            dependsOn(commonMain.get())
        }

        jvmMain {
            dependsOn(skikoMain)
            dependencies {
                api(compose.desktop.currentOs)
                implementation("net.java.dev.jna:jna:5.18.0")
            }
        }

        iosMain {
            dependsOn(skikoMain)
        }

        macosMain {
            dependsOn(skikoMain)
        }

        wasmJsMain {
            dependsOn(skikoMain)
        }

        jsMain {
            dependsOn(skikoMain)
        }
    }
}

android {
    namespace = "io.github.trueliquid.compose"
    compileSdk = 36

    defaultConfig {
        minSdk = 23
    }
}

val nativeOut = layout.buildDirectory.file("native/libTrueLiquidNative.dylib")

val buildMacTrueLiquidNative by tasks.registering(Exec::class) {
    val source = layout.projectDirectory.file("src/main/objectiveCpp/TrueLiquidNative.mm")
    inputs.file(source)
    outputs.file(nativeOut)
    commandLine(
        "xcrun", "clang++",
        "-x", "objective-c++",
        "-std=c++17",
        "-fobjc-arc",
        "-mmacosx-version-min=14.0",
        "-dynamiclib",
        "-framework", "Cocoa",
        "-framework", "QuartzCore",
        "-framework", "Metal",
        "-framework", "ScreenCaptureKit",
        "-framework", "CoreGraphics",
        "-framework", "CoreVideo",
        "-framework", "CoreMedia",
        "-framework", "IOSurface",
        source.asFile.absolutePath,
        "-o", nativeOut.get().asFile.absolutePath,
    )
}

tasks.named<Copy>("jvmProcessResources") {
    dependsOn(buildMacTrueLiquidNative)
    from(rootProject.layout.projectDirectory.file("LICENSE"))
    from(rootProject.layout.projectDirectory.file("NOTICE"))
    from(nativeOut) {
        into("true-liquid/native/macos")
    }
}

publishing {
    publications.withType<MavenPublication>().configureEach {
        pom {
            name.set("True Liquid Compose")
            description.set("Compose Multiplatform liquid glass with a native macOS desktop-capture backend.")
            url.set("https://github.com/sdfgsdfgd/true-liquid-multiplatform")
            licenses {
                license {
                    name.set("The Apache License, Version 2.0")
                    url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                    distribution.set("repo")
                }
            }
            developers {
                developer {
                    id.set("sdfgsdfgd")
                    name.set("sdfgsdfgd")
                    url.set("https://github.com/sdfgsdfgd")
                }
            }
            scm {
                url.set("https://github.com/sdfgsdfgd/true-liquid-multiplatform")
                connection.set("scm:git:https://github.com/sdfgsdfgd/true-liquid-multiplatform.git")
                developerConnection.set("scm:git:ssh://git@github.com/sdfgsdfgd/true-liquid-multiplatform.git")
            }
        }
    }
}
