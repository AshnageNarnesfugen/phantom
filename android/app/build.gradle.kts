plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Flutter expects APK output at {project_root}/build/app/. Without this, flutter build apk
// fails after flutter clean because the build/app → android/app/build symlink is gone.
layout.buildDirectory.set(rootProject.rootDir.parentFile.resolve("build/app"))

// Load signing properties from key.properties (local dev) or environment variables (CI)
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = java.util.Properties()
if (keyPropertiesFile.exists()) {
    keyPropertiesFile.inputStream().use { keyProperties.load(it) }
}

fun signingProp(propName: String, envName: String): String? =
    keyProperties.getProperty(propName) ?: System.getenv(envName)

android {
    namespace = "com.phantom.phantom_messenger"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlinOptions {
        jvmTarget = "21"
    }

    signingConfigs {
        val storeFilePath = signingProp("storeFile", "SIGNING_STORE_FILE")
        val storePass    = signingProp("storePassword", "SIGNING_STORE_PASSWORD")
        val keyAlias     = signingProp("keyAlias", "SIGNING_KEY_ALIAS")
        val keyPass      = signingProp("keyPassword", "SIGNING_KEY_PASSWORD")

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
