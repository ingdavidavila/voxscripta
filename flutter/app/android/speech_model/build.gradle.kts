// The speech model, as a Play Asset Delivery pack.
//
// install-time means Google Play installs it with the app, so the app needs no
// INTERNET permission to get it and no Play library to ask for it: its files are
// read through Android's asset reader, which is what ModelStore.kt does on first
// launch. The pack's content is not in the repository. Tools/stage-android-model.sh
// puts the model in src/main/assets/models/ before a bundle is built, and the
// app module refuses to build a bundle if it is missing (see app/build.gradle.kts).
plugins {
    id("com.android.asset-pack")
}

assetPack {
    packName.set("speech_model")
    dynamicDelivery {
        deliveryType.set("install-time")
    }
}
