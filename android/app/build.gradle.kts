import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing, read from android/key.properties, which is NOT in git and
// must never be. Neither is the keystore it points at. See README.md.
//
// If the file is absent, the release build below fails rather than quietly
// falling back to the debug key. That is deliberate, and in this app the
// reason is sharper than usual: an APK signed with the debug key cannot be
// upgraded by a properly signed one. Android refuses the install, and the
// only way out is to uninstall first, which deletes the app's data directory
// AND the default backup folder inside Android/data. So a debug-signed
// release reaching the restaurant's phone can cost them their bills.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.deeptaai.restaurant_pos"

    // Pinned to 37 rather than flutter.compileSdkVersion (36), because
    // permission_handler_android compiles against 37 and Gradle refuses to
    // build an app against a lower SDK than one of its plugins.
    //
    // compileSdk only decides which APIs can be COMPILED against; it is
    // backward compatible and does not raise the Android version the app runs
    // on. minSdk and targetSdk below are untouched, so the range of devices
    // this installs on is unchanged.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.deeptaai.restaurant_pos"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")
                    ?.let { rootProject.file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Null when there is no key. Nothing is thrown here: this block is
            // CONFIGURATION, which Gradle evaluates on every build, so a throw
            // in it broke `flutter build apk --debug` as well. The guard that
            // actually stops an unsigned release is registered below, against
            // the release tasks themselves.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }
    }
}

// Runs only if a release task really runs, and only then.
if (!keystorePropertiesFile.exists()) {
    tasks.matching {
        it.name.startsWith("assembleRelease") ||
            it.name.startsWith("bundleRelease") ||
            it.name.startsWith("packageRelease")
    }.configureEach {
        doFirst {
            throw GradleException(
                "Cannot build a release: android/key.properties is " +
                    "missing.\n\n" +
                    "Create it with storeFile, storePassword, keyAlias and " +
                    "keyPassword, pointing at your keystore. README.md has " +
                    "the keytool command.\n\n" +
                    "It is NOT signed with the debug key instead, on " +
                    "purpose: a debug-signed APK on the restaurant's phone " +
                    "cannot be upgraded by a real one, and the uninstall " +
                    "that would be needed takes the default backup folder " +
                    "with it."
            )
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
