# Flutter audio_service and just_audio packages
# Keep all audio service classes to prevent R8 from stripping them in release builds
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }

# Keep the AudioHandler implementation
-keep class * extends com.ryanheise.audioservice.AudioServicePlugin { *; }

# Prevent obfuscation of classes used via reflection
-keepnames class com.ryanheise.audioservice.AudioService
-keepnames class com.ryanheise.audioservice.MediaButtonReceiver
