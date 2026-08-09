pluginManagement {
    repositories {
        mavenCentral()
        google()
        maven { url = uri("https://repo.maven.apache.org/maven2") }
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }

    val flutterSdkPath = run {
        val props = java.util.Properties()
        file("local.properties").inputStream().use { props.load(it) }
        val path = props.getProperty("flutter.sdk")
        require(path != null) { "flutter.sdk not set in local.properties" }
        path
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_PROJECT)

    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://repo.maven.apache.org/maven2") }
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("dev.flutter.flutter-gradle-plugin") version "1.0.0" apply false

    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.10" apply false

    // Firebase: processes android/app/google-services.json at build time.
    id("com.google.gms.google-services") version "4.4.2" apply false
}


include(":app")
enableFeaturePreview("TYPESAFE_PROJECT_ACCESSORS")
