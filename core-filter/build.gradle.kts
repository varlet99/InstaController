plugins {
    kotlin("jvm")
}

dependencies {
    // Pure JSON manipulation matching Android's built-in org.json for zero-dependency Smali injection
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

kotlin {
    jvmToolchain(21)
}
