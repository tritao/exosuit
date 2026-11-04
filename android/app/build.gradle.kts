plugins {
    id("com.android.application")
}

// Written by scripts/build.ps1: ui.hl, ui.hli, ui.entries, fonts, and one jniLibs/<abi> per built ABI.
val stage = rootProject.file("build/stage")

android {
    namespace = "com.exosuit.mobile"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.exosuit.mobile"
        minSdk = 34
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += listOf("x86_64", "arm64-v8a") }
    }
    // A phone keeps an installed app only while later builds carry the same signature. Every machine has its own
    // debug key, so EXOSUIT_ANDROID_KEYSTORE can name one shared debug keystore (the standard debug passwords).
    System.getenv("EXOSUIT_ANDROID_KEYSTORE")?.takeIf { it.isNotEmpty() }?.let { path ->
        signingConfigs.getByName("debug") {
            storeFile = file(path)
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets.getByName("main") {
        assets.directories.add(stage.resolve("assets").absolutePath)
        jniLibs.directories.add(stage.resolve("jniLibs").absolutePath)
    }
}

dependencies {
    implementation(project(":nativekit"))
    implementation("androidx.core:core:1.16.0")
}
