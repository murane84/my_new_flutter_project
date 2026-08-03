val flutterVersionCode = 1
val flutterVersionName = "1.0"

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.new_flutter_project_fixed"

    // 🔕 Do NOT fail build on lint issues from Flutter plugins
    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }

    // Build against the stable SDK 36 (installed). permission_handler is
    //    pinned in pubspec.yaml to a version that compiles against 36, so we
    //    don't need the preview android-37 platform.
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "com.example.new_flutter_project_fixed"
        minSdk = 24

        // ✅ Required by most of your plugins
        targetSdk = 36

        versionCode = flutterVersionCode
        versionName = flutterVersionName
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.17.0")

    // ✅ Required for Java 8+ APIs
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
