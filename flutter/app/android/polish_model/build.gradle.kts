// The polish model (0.5B on phones), as a second install-time Play Asset
// Delivery pack, for the same reasons as :speech_model: no INTERNET permission
// and no Play library. The content is not in the repository:
//   Tools/fetch-polish-model.sh phone
//   Tools/stage-polish-model.sh phone flutter/app/android/polish_model/src/main/assets/models
plugins {
    id("com.android.asset-pack")
}

assetPack {
    packName.set("polish_model")
    dynamicDelivery {
        deliveryType.set("install-time")
    }
}
