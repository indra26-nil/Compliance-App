allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// onnxruntime 1.4.1 pins compileSdk 33 but its transitive androidx libs
// now require >= 34. The plugin is unmaintained, so force it up here
// (survives `flutter pub get`, unlike patching ~/.pub-cache).
// NOTE: must use afterProject (not subprojects+afterEvaluate) because
// evaluationDependsOn(":app") above means subprojects may already be
// evaluated when this script runs.
gradle.afterProject {
    if (name == "onnxruntime") {
        extensions
            .findByType<com.android.build.gradle.LibraryExtension>()
            ?.let { it.compileSdk = 36 }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
