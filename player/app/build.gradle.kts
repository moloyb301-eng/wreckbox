import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "local.wreckbox.player"
    compileSdk = 37

    defaultConfig {
        applicationId = "local.wreckbox.player"
        minSdk = 26
        targetSdk = 36
        versionCode = 4
        versionName = "0.2.2"
        // USB test commands (MainActivity.test), WebView debugging and player.log: only in test builds
        // (./gradlew assembleRelease -PwbTest), never in the builds friends download.
        buildConfigField("boolean", "TEST_COMMANDS", if (project.hasProperty("wbTest")) "true" else "false")
    }

    // Signed with the WreckBox release key (the main app's: app/android/key.properties, kept out of the repo) so
    // updates install over each other on friends' phones; without it (someone else's checkout), the debug key.
    val keyProps = Properties().apply {
        val f = rootProject.file("../app/android/key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    signingConfigs {
        if (keyProps.getProperty("storeFile") != null) create("release") {
            storeFile = file(keyProps.getProperty("storeFile"))
            storePassword = keyProps.getProperty("storePassword")
            keyAlias = keyProps.getProperty("keyAlias")
            keyPassword = keyProps.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-session:1.11.1")
    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.webkit:webkit:1.17.1")
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended:1.7.8")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("dev.chrisbanes.haze:haze:1.7.3") // frosted glass (blur of what scrolls behind the bars)
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}
