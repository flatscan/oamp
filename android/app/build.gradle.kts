plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.oamp.oamp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.oamp.oamp"
        // Android 7.0. flutter_secure_storage needs 23; 24 keeps the media
        // session and foreground service code on one code path.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Test builds (pull requests, main) are signed with a key kept in the
        // repo on purpose. It is public, so it is not a secret: it only keeps
        // the signature the same from one CI build to the next, so a new APK
        // installs over the old one and keeps the login and settings. Nothing
        // published may be signed with it.
        //
        // Release builds set OAMP_KEYSTORE* to a private key held in GitHub
        // secrets (see docs/signing.md). OAMP_REQUIRE_RELEASE_KEY=true makes
        // a missing private key a build error instead of a silent fallback.
        create("oamp") {
            val keystore = System.getenv("OAMP_KEYSTORE")
            if (keystore != null) {
                storeFile = file(keystore)
                storePassword = System.getenv("OAMP_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("OAMP_KEY_ALIAS")
                keyPassword = System.getenv("OAMP_KEY_PASSWORD")
            } else {
                if (System.getenv("OAMP_REQUIRE_RELEASE_KEY") == "true") {
                    throw GradleException(
                        "OAMP_REQUIRE_RELEASE_KEY is set but OAMP_KEYSTORE is not: " +
                            "refusing to sign a release with the public side-load key."
                    )
                }
                storeFile = file("sideload.keystore")
                storePassword = "oamp-sideload"
                keyAlias = "oamp-sideload"
                keyPassword = "oamp-sideload"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("oamp")
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
