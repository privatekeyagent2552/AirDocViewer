allprojects {
    repositories {
        google()
        mavenCentral()
        maven(url = "https://jitpack.io")
    }
}

// file_picker 11 skips the Kotlin plugin on AGP 9 and expects AGP built-in
// Kotlin. This app sets android.builtInKotlin=false, so those .kt sources never
// compile and GeneratedPluginRegistrant cannot see FilePickerPlugin.
// The plugin buildscript also pins Kotlin 1.8.22, which AGP 9 will not compile.
// Apply kotlin-android from android/settings.gradle.kts (2.4.0) instead.
// flutter pub get restores the plugin file; patch it before that project is evaluated.
fun Project.patchFilePickerKotlin(buildFile: File) {
    if (!buildFile.isFile) {
        return
    }
    val marker = "// AIRDOCS_FILE_PICKER_KOTLIN"
    var text = buildFile.readText().replace("\r\n", "\n")
    if (
        text.contains(marker) &&
        text.contains("id \"com.android.library\"") &&
        text.contains("id \"kotlin-android\"") &&
        !text.contains("kotlin-gradle-plugin") &&
        !text.contains("apply plugin:")
    ) {
        return
    }

    // Restore the published script if an earlier patch applied KGP 1.8.22.
    val legacyPatch =
        "apply plugin: 'com.android.library'\n$marker\napply plugin: 'org.jetbrains.kotlin.android'\nkotlin {\n    compilerOptions {\n        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)\n    }\n}\n"
    val upstreamApply =
        "apply plugin: 'com.android.library'\nif (!isAgp9OrAbove) {\n    apply plugin: 'org.jetbrains.kotlin.android'\n}\n"
    if (text.contains(legacyPatch)) {
        text = text.replace(legacyPatch, upstreamApply)
    }

    // plugins {} must be the first statement. Apply both plugins from
    // settings.gradle.kts so Kotlin is 2.4.0, not the buildscript's 1.8.22.
    val upstreamHeader =
        "group 'com.mr.flutter.plugin.filepicker'\n" +
            "version '1.0-SNAPSHOT'\n" +
            "\n" +
            "buildscript {\n" +
            "    ext {\n" +
            "        kotlin_version = '1.8.22'\n" +
            "    }\n" +
            "    repositories {\n" +
            "        google()\n" +
            "        mavenCentral()\n" +
            "    }\n" +
            "\n" +
            "    dependencies {\n" +
            "        classpath 'com.android.tools.build:gradle:8.5.1'\n" +
            "        classpath \"org.jetbrains.kotlin:kotlin-gradle-plugin:\$kotlin_version\"\n" +
            "    }\n" +
            "}\n"
    val patchedHeader =
        "plugins {\n" +
            "    id \"com.android.library\"\n" +
            "    id \"kotlin-android\"\n" +
            "}\n" +
            "\n" +
            "$marker\n" +
            "kotlin {\n" +
            "    compilerOptions {\n" +
            "        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)\n" +
            "    }\n" +
            "}\n" +
            "\n" +
            "group 'com.mr.flutter.plugin.filepicker'\n" +
            "version '1.0-SNAPSHOT'\n"
    if (!text.contains(upstreamHeader) || !text.contains(upstreamApply)) {
        logger.warn("file_picker android/build.gradle did not match the AGP 9 Kotlin skip: ${buildFile.absolutePath}")
        return
    }
    text = text.replace(upstreamHeader, patchedHeader).replace(upstreamApply, "")
    buildFile.writeText(text)
    logger.lifecycle("Patched file_picker to compile Kotlin with the app Kotlin plugin: ${buildFile.absolutePath}")
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

gradle.beforeProject {
    if (name == "file_picker") {
        patchFilePickerKotlin(file("build.gradle"))
    }
}

subprojects {
    if (name == "file_picker") {
        patchFilePickerKotlin(file("build.gradle"))
    }
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// pdfium_flutter android/CMakeLists.txt calls file(CREATE_LINK) for .lib/latest.
// On Windows that needs Developer Mode ("A required privilege is not held by the client").
// flutter pub get restores the upstream file, so re-insert a project-local include
// (android/pdfium_windows_link.cmake) before CMake configure. That include creates
// a directory junction, which does not need elevation.
val pdfiumLinkCmake = rootProject.file("pdfium_windows_link.cmake")

fun Project.patchPdfiumFlutterCmake(cmakeLists: File, linkCmake: File) {
    if (!cmakeLists.isFile || !linkCmake.isFile) {
        return
    }
    val includePath = linkCmake.absolutePath.replace('\\', '/')
    val includeLine = "include(\"$includePath\")"
    val replacement = """
# AIRDOCS_PDFIUM_LINK - re-applied by android/build.gradle.kts; flutter pub get restores upstream.
$includeLine
""".trimIndent()
    val normalized = cmakeLists.readText().replace("\r\n", "\n")
    val marker = "# AIRDOCS_PDFIUM_LINK"
    val upstream = "file(REMOVE \${PDFIUM_LATEST_DIR})\nfile(CREATE_LINK \${PDFIUM_LIBS_DIR} \${PDFIUM_LATEST_DIR} SYMBOLIC)"
    val updated = when {
        normalized.contains(marker) && normalized.contains(includeLine) -> return
        normalized.contains(marker) -> normalized.replace(
            Regex("""include\("[^"]*pdfium_windows_link\.cmake"\)"""),
            includeLine,
        )
        normalized.contains(upstream) -> normalized.replace(upstream, replacement)
        else -> {
            logger.warn(
                "pdfium_flutter CMakeLists.txt has no CREATE_LINK step to patch: ${cmakeLists.absolutePath}",
            )
            return
        }
    }
    if (updated != normalized) {
        cmakeLists.writeText(updated)
        logger.lifecycle("Patched pdfium_flutter CMake symlink step: ${cmakeLists.absolutePath}")
    }
}

subprojects {
    if (name != "pdfium_flutter") {
        return@subprojects
    }
    val cmakeLists = file("CMakeLists.txt")
    patchPdfiumFlutterCmake(cmakeLists, pdfiumLinkCmake)
    tasks.configureEach {
        if (name.startsWith("configureCMake")) {
            doFirst {
                project.patchPdfiumFlutterCmake(cmakeLists, pdfiumLinkCmake)
            }
        }
    }
}
