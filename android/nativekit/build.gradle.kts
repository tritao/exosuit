plugins { id("com.android.library") }

// NativeKit's Android host classes, copied from the haxeon checkout into src/main by scripts/build.ps1 (namespace io.nativekit).
// Its native code is not built here: native/CMakeLists.txt builds libnativekit.so together with the rest.
android {
    namespace = "io.nativekit"
    compileSdk = 36
    defaultConfig { minSdk = 34 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.core:core:1.16.0")
    implementation("androidx.webkit:webkit:1.14.0")
}
