plugins {
    id("com.android.application")
}

android {
    namespace = "com.gowin.musiccontroller"
    compileSdk = 37


    defaultConfig {
        applicationId = "com.gowin.musiccontroller.spp"
        minSdk = 26
        targetSdk = 35
        versionCode = 14
        versionName = "0.10.2-spp"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20251224")
}
