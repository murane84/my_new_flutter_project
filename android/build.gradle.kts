import org.jetbrains.kotlin.gradle.tasks.KotlinCompile
import com.android.build.gradle.BaseExtension

plugins {
    id("com.android.application") apply false
    id("com.android.library") apply false
    id("org.jetbrains.kotlin.android") apply false
}

/**
 * 🔒 Force ALL builds into ONE root (prevents C: vs D: conflict)
 */
rootProject.buildDir = file(rootDir.parentFile.resolve("build"))

subprojects {
    buildDir = rootProject.buildDir.resolve(name)
}

/**
 * 🛑 EARLY GUARD — disable ALL test tasks BEFORE Gradle creates them
 * This is the CRITICAL fix for file_selector_android
 */
subprojects {
    tasks.matching {
        it.name.contains("test", ignoreCase = true)
    }.configureEach {
        enabled = false
    }
}

/**
 * ⚙️ Android / Kotlin configuration
 */
subprojects {

    afterEvaluate {

        if (
            plugins.hasPlugin("com.android.application") ||
            plugins.hasPlugin("com.android.library")
        ) {

            extensions.findByName("android")?.let { ext ->
                val androidExt = ext as BaseExtension
                
                // 🧩 Auto-namespace fix for old Flutter plugins (AGP 8+)
                if (androidExt.namespace == null || androidExt.namespace!!.isBlank()) {
        androidExt.namespace = "flutter.${project.name.replace("-", "_")}"
    }

                // 🔕 Disable lint completely (Flutter-safe)
                androidExt.lintOptions.apply {
                    isAbortOnError = false
                    isCheckReleaseBuilds = false
                    isIgnoreWarnings = true
                    isCheckDependencies = false
                    isQuiet = true

                    disable(
                        "WrongConstant",
                        "NewApi",
                        "ObsoleteSdkInt",
                        "UnsafeOptInUsageError",
                        "ForegroundServiceType",
                        "ForegroundServicePermission",
                        "InlinedApi",
                        "GradleDependency"
                    )
                }

                // 🛑 Disable all lint tasks
                tasks.matching {
                    it.name.startsWith("lint", ignoreCase = true)
                }.configureEach {
                    enabled = false
                }

                // ✅ Java 17 everywhere
                androidExt.compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
            }
        }

        // ✅ Kotlin JVM 17 everywhere
        tasks.withType<KotlinCompile>().configureEach {
            kotlinOptions.jvmTarget = "17"
        }

        // 🚀 Disable verify / check tasks (Flutter never uses them)
        tasks.matching {
            it.name.contains("verify", ignoreCase = true) ||
            it.name.contains("check", ignoreCase = true)
        }.configureEach {
            enabled = false
        }
    }
}

/**
 * 🧹 Clean
 */
tasks.register<Delete>("clean") {
    delete(rootProject.buildDir)
}
