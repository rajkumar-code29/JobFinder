import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. CI passes the upload key through environment variables; for a local release build put
// storeFile/storePassword/keyAlias/keyPassword in android/key.properties (git-ignored). Without either, release
// builds fall back to the debug key, which is fine for testing but can't update an installed release build.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) FileInputStream(file).use { load(it) }
}
fun signing(env: String, property: String): String? = System.getenv(env) ?: keyProperties.getProperty(property)
val releaseStoreFile = signing("ANDROID_KEYSTORE_PATH", "storeFile")

android {
    namespace = "com.rajkumargk.jobfinder"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Same id as the iOS bundle. Changing it later means users have to reinstall.
        applicationId = "com.rajkumargk.jobfinder"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storePassword = signing("ANDROID_KEYSTORE_PASSWORD", "storePassword")
                keyAlias = signing("ANDROID_KEY_ALIAS", "keyAlias") ?: "upload"
                keyPassword = signing("ANDROID_KEY_PASSWORD", "keyPassword") ?: storePassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseStoreFile != null) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
