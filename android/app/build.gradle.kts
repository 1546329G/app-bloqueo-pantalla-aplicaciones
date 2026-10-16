plugins {
    id("com.android.application")
    id("kotlin-android")
    // El plugin de Flutter debe aplicarse DESPUÉS de Android y Kotlin.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.app_locker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.app_locker"
        // Requisito del proyecto: Android 10 (API 29) en adelante.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Firma debug para poder instalar builds release en local.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// DSL moderna de Kotlin (KGP 2.4.0): reemplaza al antiguo `kotlinOptions`.
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // ServiceCompat.startForeground tipado, ContextCompat, ActivityCompat…
    implementation("androidx.core:core-ktx:1.13.1")
}
