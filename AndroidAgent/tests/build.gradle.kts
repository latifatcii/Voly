import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Runs the agent's Compose reading against a real Compose, on the JVM
// (Robolectric): no emulator. The version of Compose is a parameter, because
// the agent reads Compose through names that have changed between releases:
//
//   ../../SampleAppAndroid/gradlew -p . test -Pcompose=1.7.8
plugins {
    id("com.android.library") version "8.13.2"
    id("org.jetbrains.kotlin.android") version "2.2.21"
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21"
}

val compose = (findProperty("compose") as String?) ?: "1.8.3"

android {
    namespace = "dev.voly.agent.tests"
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    defaultConfig {
        minSdk = 26
    }

    // The agent itself: plain Java against the platform, as build.sh compiles it.
    sourceSets["main"].java.srcDir("../src/main/java")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.systemProperty("voly.compose", compose)
                it.testLogging {
                    events("failed")
                    showStandardStreams = project.hasProperty("verbose")
                    exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

// Newer Compose asks for a newer compileSdk and Gradle plugin than this
// project has. That matters to an app that ships it; here Compose only has
// to run, and the tests are how one finds out whether the agent reads it.
tasks.matching { it.name.startsWith("check") && it.name.endsWith("AarMetadata") }.configureEach { enabled = false }

dependencies {
    testImplementation("androidx.compose.ui:ui:$compose")
    testImplementation("androidx.compose.foundation:foundation:$compose")
    testImplementation("androidx.activity:activity:1.9.3")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
}
