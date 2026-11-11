plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.io.File
import java.io.FileInputStream
import java.util.Properties

// ── Versioning (manual control) ──
val appVersionCode = 6
val appVersionName = "1.0.0"

// ── Release keystore signing ──
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.airdocsviewer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.airdocsviewer"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26  // Android 8.0 (API 26) through latest — POI / log4j floor
        targetSdk = flutter.targetSdkVersion
        // Same document features (PDF / DOCX / PPTX / Excel) on all supported APIs.
        versionCode = appVersionCode
        versionName = appVersionName
        multiDexEnabled = true
        // Default APK (Android Studio + flutter build): 32-bit + 64-bit ARM.
        // Flutter 3.35+ also injects x86_64 unless we clear first — skip emulators.
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
            abiFilters.add("armeabi-v7a")
        }
        // Launcher icon label only (home screen). Package id stays com.airdocsviewer.
        manifestPlaceholders["appName"] = "AirDoc Viewer"
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                // storeFile in key.properties is relative to the android/ folder.
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Local testing without key.properties — use debug keystore.
                signingConfigs.getByName("debug")
            }
            // R8 minification enabled with selective keep rules for POI/XMLBeans/logging
            // Critical classes (POI, XMLBeans, logging, JNI) are kept unobfuscated
            // Everything else (Flutter, app code, unused deps) is aggressively minified
            isMinifyEnabled = true
            isShrinkResources = true
            // Use only our custom ProGuard rules (not the default Android ones)
            proguardFiles("proguard-rules.pro")
        }
    }

    // Exclude duplicate META-INF files from transitive dependencies
    packaging {
        resources {
            merges += listOf("META-INF/LICENSE.md", "META-INF/NOTICE.md", "META-INF/LICENSE-notice.md")
            excludes += listOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/INDEX.LIST",
                "META-INF/*.md",
                "META-INF/LICENSE-notice.md",
                "org/bouncycastle/pqc/**"
            )
        }
    }

    aaptOptions {
        noCompress += listOf(
            "rdb", "rc", "xcu", "xcs", "xcl", "xcsa", "xcul", "xcd",
            "xslt", "xml", "py", "ttf", "otf", "ttc",
            "dat", "res", "zip", "jar", "class", "txt",
            "conf", "cfg", "svg", "css", "ui", "dtd",
            "sor", "sample", "lm", "mod", ""
        )
    }

    // Avoid Android Studio file locks on lint cache / old release output folders.
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

// Default APK names for Android Studio / Gradle builds:
//   AirDocsViewer-release.apk
//   AirDocsViewer-debug.apk
base {
    archivesName.set("AirDocsViewer")
}

android.applicationVariants.configureEach {
    val buildTypeName = buildType.name
    outputs.configureEach {
        (this as com.android.build.gradle.internal.api.BaseVariantOutputImpl)
            .outputFileName = "AirDocsViewer-$buildTypeName.apk"
    }
}

// Mirror release APK + metadata into android/app/release for Android Studio
// "Locate" / Generate Signed APK. Primary output stays at build/app/outputs/apk/release.
// Flutter Studio builds often only refresh flutter-apk/app-release.apk — sync that too.
afterEvaluate {
    val syncNamedReleaseApk = tasks.register("syncNamedReleaseApk") {
        dependsOn("packageRelease")
        doLast {
            val apkReleaseDir = layout.buildDirectory.dir("outputs/apk/release").get().asFile
            val flutterApkDir = layout.buildDirectory.dir("outputs/flutter-apk").get().asFile
            val ideReleaseDir = layout.projectDirectory.dir("release").asFile
            ideReleaseDir.mkdirs()
            apkReleaseDir.mkdirs()

            val namedInApk = File(apkReleaseDir, "AirDocsViewer-release.apk")
            val flutterAppRelease = File(flutterApkDir, "app-release.apk")
            val namedInIde = File(ideReleaseDir, "AirDocsViewer-release.apk")

            // Prefer newest existing release APK (Flutter path or Gradle named path).
            val candidates = listOf(namedInApk, flutterAppRelease).filter { it.exists() }
            val newest = candidates.maxByOrNull { it.lastModified() }
                ?: return@doLast

            if (newest != namedInApk) {
                newest.copyTo(namedInApk, overwrite = true)
            }
            newest.copyTo(namedInIde, overwrite = true)

            File(apkReleaseDir, "output-metadata.json").takeIf { it.exists() }
                ?.copyTo(File(ideReleaseDir, "output-metadata.json"), overwrite = true)
        }
    }

    val copyReleaseApkToIdeFolder = tasks.register<Copy>("copyReleaseApkToIdeFolder") {
        dependsOn(syncNamedReleaseApk)
        from(layout.buildDirectory.dir("outputs/apk/release")) {
            include("AirDocsViewer-release.apk")
            include("output-metadata.json")
            include("baselineProfiles/**")
        }
        into(layout.projectDirectory.dir("release"))
        doFirst {
            layout.projectDirectory.dir("release").asFile.mkdirs()
        }
    }

    // AGP reads android/app/release/output-metadata.json; ensure copy runs first.
    tasks.matching { it.name == "createReleaseApkListingFileRedirect" }.configureEach {
        dependsOn(copyReleaseApkToIdeFolder)
    }

    tasks.matching { it.name == "assembleRelease" }.configureEach {
        finalizedBy(syncNamedReleaseApk)
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    // Apache POI for native document parsing (XLSX, XLS, CSV, DOC)
    implementation("org.apache.poi:poi:5.2.3")
    implementation("org.apache.poi:poi-ooxml:5.2.3") {
        exclude(group = "org.apache.poi", module = "poi-ooxml-lite")
    }
    implementation("org.apache.poi:poi-ooxml-full:5.2.3")
    implementation("org.apache.poi:poi-scratchpad:5.2.3")

    // PDFBox for PDF text extraction
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")

    // Required transitive dependencies
    implementation("org.apache.xmlbeans:xmlbeans:5.1.1")
    implementation("commons-io:commons-io:2.11.0")
    implementation("commons-codec:commons-codec:1.15")
    implementation("commons-logging:commons-logging:1.2")
}

flutter {
    source = "../.."
}
