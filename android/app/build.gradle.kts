import java.util.Properties
import java.io.FileInputStream

// Release signing: android/key.properties (never committed) points at the
// upload keystore. Every update MUST be signed with this same key, or
// Android refuses to install it over the old app. Without the file, release
// builds fall back to the debug key (only installs over other debug-key
// builds made on THIS computer).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase (Cloud Messaging). Requires android/app/google-services.json —
    // downloaded from the Firebase console (see the setup guide). The Android
    // build will fail with "File google-services.json is missing" until it's in
    // place, so add that file before building for Android.
    id("com.google.gms.google-services")
}

android {
    namespace = "com.ozilane.aluta"

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
        applicationId = "com.ozilane.aluta"
        minSdk = 24

        // ✅ Required by most of your plugins
        targetSdk = 36

        // From pubspec.yaml "version: 1.0.3+4" → name 1.0.3, code 4. The
        // in-app updater compares this code with the published build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    // Kotlin jvmTarget 17 is set centrally in android/build.gradle.kts (AGP 8.11 / Kotlin 2.2 compilerOptions)

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
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
