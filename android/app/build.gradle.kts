import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Signing helpers ──────────────────────────────────────────────────────────
// Priority order: environment variable (CI) → android/key.properties (local dev)
// If neither is present the release build falls back to debug keys automatically.
val keyPropsFile = rootProject.file("key.properties")
val keyProps = Properties().also { props ->
    if (keyPropsFile.exists()) props.load(keyPropsFile.inputStream())
}
fun signingValue(envKey: String, propKey: String): String? =
    System.getenv(envKey)?.takeIf { it.isNotBlank() }
        ?: keyProps.getProperty(propKey)?.takeIf { it.isNotBlank() }

android {
    namespace = "com.hamma.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "25.1.8937393"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    signingConfigs {
        val storePath = signingValue("KEY_STORE_PATH",     "storeFile")
        val storePass = signingValue("KEY_STORE_PASSWORD", "storePassword")
        val alias     = signingValue("KEY_ALIAS",          "keyAlias")
        val keyPass   = signingValue("KEY_PASSWORD",       "keyPassword")
        if (storePath != null && storePass != null && alias != null && keyPass != null) {
            create("release") {
                storeFile     = file(storePath)
                storePassword = storePass
                keyAlias      = alias
                keyPassword   = keyPass
            }
        }
    }

    defaultConfig {
        applicationId = "com.hamma.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                cppFlags("-std=c++17")
                arguments("-DGGML_OPENBLAS=OFF", "-DGGML_CUDA=OFF")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1+"
        }
    }

    buildTypes {
        release {
            // Uses release key when signing secrets are present; falls back to
            // debug keys otherwise so unsigned local/CI builds still succeed.
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.3")
}
