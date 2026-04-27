import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Flutter expects APK output at {project_root}/build/app/. Without this, flutter build apk
// fails after flutter clean because the build/app → android/app/build symlink is gone.
layout.buildDirectory.set(rootProject.rootDir.parentFile.resolve("build/app"))

// Load signing properties from key.properties (local dev only).
// In CI, apksigner re-signs the APK after the build, so AGP uses debug signing.
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
if (keyPropertiesFile.exists()) {
    keyPropertiesFile.inputStream().use { keyProperties.load(it) }
}

android {
    namespace = "com.phantom.phantom_messenger"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_21.toString()
    }

    signingConfigs {
        val storeFilePath = keyProperties.getProperty("storeFile")
        val storePass    = keyProperties.getProperty("storePassword")
        val keyAlias     = keyProperties.getProperty("keyAlias")
        val keyPass      = keyProperties.getProperty("keyPassword")

        if (storeFilePath != null && storePass != null && keyAlias != null && keyPass != null) {
            create("release") {
                storeFile = file(storeFilePath)
                storePassword = storePass
                this.keyAlias = keyAlias
                keyPassword = keyPass
            }
        }
    }

    defaultConfig {
        applicationId = "com.phantom.phantom_messenger"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Local dev uses key.properties; CI re-signs with apksigner after build.
            val releaseSigning = signingConfigs.findByName("release")
            signingConfig = releaseSigning ?: signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

}

flutter {
    source = "../.."
}
