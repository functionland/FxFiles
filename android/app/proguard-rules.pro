# Flutter audio_service and just_audio packages
# Keep all audio service classes to prevent R8 from stripping them in release builds
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }

# Keep the AudioHandler implementation
-keep class * extends com.ryanheise.audioservice.AudioServicePlugin { *; }

# Prevent obfuscation of classes used via reflection
-keepnames class com.ryanheise.audioservice.AudioService
-keepnames class com.ryanheise.audioservice.MediaButtonReceiver

# ============================================
# Reown AppKit / WalletConnect SDK
# Required for wallet signature requests in release builds
# ============================================

# Keep ALL classes from Reown packages (native Android SDK)
-keep class com.reown.** { *; }
-keep interface com.reown.** { *; }
-keep class com.walletconnect.** { *; }
-keep interface com.walletconnect.** { *; }

# Keep Flutter plugin classes - critical for method channel communication
# But don't fail on missing Play Core classes (optional dependency)
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.android.** { *; }
-keep class io.flutter.embedding.engine.** { *; }
-dontwarn io.flutter.embedding.engine.deferredcomponents.**

# Google Play Core (optional, used for deferred components)
-dontwarn com.google.android.play.core.**

# Keep flutter_secure_storage classes (seen obfuscated as l2.e in logs)
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class com.it_nomads.fluttersecurestorage.ciphers.** { *; }

# OkHttp (used by WalletConnect for websocket connections)
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**

# Scarlet WebSocket library (used by WalletConnect)
-keep class com.tinder.scarlet.** { *; }
-keep interface com.tinder.scarlet.** { *; }
-dontwarn com.tinder.scarlet.**

# Moshi JSON library (used by WalletConnect)
-keep class com.squareup.moshi.** { *; }
-keep interface com.squareup.moshi.** { *; }
-keepclassmembers class * {
    @com.squareup.moshi.Json <fields>;
}
-dontwarn com.squareup.moshi.**

# Kotlin serialization (used by Reown SDK)
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.reown.**$$serializer { *; }
-keepclassmembers class com.reown.** {
    *** Companion;
}
-keepclasseswithmembers class com.reown.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Keep Kotlin Coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}

# Web3j (if used)
-keep class org.web3j.** { *; }
-dontwarn org.web3j.**

# Bouncy Castle crypto (used for signing)
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# Keep reflection used by Flutter plugins
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

# Don't obfuscate model classes used in JSON serialization
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep all Kotlin metadata (required for reflection)
-keep class kotlin.Metadata { *; }
-keepclassmembers class kotlin.Metadata {
    public <methods>;
}

# Keep Gson type tokens and generic signatures
-keep class com.google.gson.** { *; }
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# Retrofit (if used by WalletConnect)
-keepattributes RuntimeVisibleAnnotations, RuntimeVisibleParameterAnnotations
-keepclassmembers,allowshrinking,allowobfuscation interface * {
    @retrofit2.http.* <methods>;
}
-dontwarn retrofit2.**

# Keep all model classes that might be serialized
-keepclassmembers class * {
    @kotlinx.serialization.SerialName <fields>;
}

# Prevent stripping of classes used in method channels
-keep class * implements io.flutter.plugin.common.MethodChannel$MethodCallHandler { *; }
-keep class * implements io.flutter.plugin.common.EventChannel$StreamHandler { *; }

# ============================================
# Google Sign-In / Credential Manager
# Required for Android 16+ authentication
# ============================================
-keep class com.google.android.gms.auth.** { *; }
-keep class com.google.android.gms.auth.api.** { *; }
-keep class com.google.android.gms.common.** { *; }
-keep class com.google.android.gms.common.api.** { *; }

# Android Credential Manager (Android 14+)
-keep class android.credentials.** { *; }
-keep class androidx.credentials.** { *; }
-dontwarn android.credentials.**
-dontwarn androidx.credentials.**

# Google Identity Services
-keep class com.google.android.gms.auth.api.identity.** { *; }
-keep class com.google.android.gms.auth.api.signin.** { *; }
