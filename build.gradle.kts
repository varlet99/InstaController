plugins {
    kotlin("jvm") version "2.1.10" apply false
}

allprojects {
    group = "com.instacontroller"
    version = "1.0.0-SNAPSHOT"

    repositories {
        mavenCentral()
        google()
    }
}
