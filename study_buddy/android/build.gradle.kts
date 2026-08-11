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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// 全局压制 javac 的「source/target 8 已过时」警告。
// 我们项目自身已是 Java 11（见 app/build.gradle.kts），警告来自三方插件/AAR
// 含 Java 8 源码（如旧版 flutter_embedding、第三方 Android 库）。JDK 17+ 编译时会
// 刷屏两条 [options] 警告，对构建无影响。加 -Xlint:-options 仅关掉该条警告。
subprojects {
    tasks.withType(JavaCompile::class.java).configureEach {
        options.compilerArgs.add("-Xlint:-options")
    }
}
