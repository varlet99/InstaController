plugins {
    kotlin("jvm")
}

dependencies {
    implementation(project(":core-filter"))
    implementation("org.json:json:20240303")

    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
    testImplementation("org.assertj:assertj-core:3.27.3")
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "skipped", "failed", "standardOut", "standardError")
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

val d8Executable = "/Users/charlesrivest/Library/Android/sdk/build-tools/34.0.0/d8"

tasks.register<Exec>("dex") {
    dependsOn("jar", ":core-filter:jar")
    val outputDir = layout.buildDirectory.dir("libs").get().asFile
    val extensionJar = layout.buildDirectory.file("libs/revanced-extension-1.0.0-SNAPSHOT.jar").get().asFile
    val coreFilterJar = project(":core-filter").layout.buildDirectory.file("libs/core-filter-1.0.0-SNAPSHOT.jar").get().asFile

    inputs.files(extensionJar, coreFilterJar)
    outputs.file(File(outputDir, "classes.dex"))

    commandLine(
        d8Executable,
        "--output", outputDir.absolutePath,
        "--min-api", "26",
        extensionJar.absolutePath,
        coreFilterJar.absolutePath
    )
}

tasks.named("assemble") {
    dependsOn("dex")
}
