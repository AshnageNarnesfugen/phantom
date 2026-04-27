# Flutter engine
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.**

# Kotlin runtime
-keep class kotlin.** { *; }
-dontwarn kotlin.**

# Hive storage — box adapters must survive minification
-keep class com.hivedb.** { *; }
-keep class ** implements com.hivedb.hive.TypeAdapter { *; }

# BLE — flutter_blue_plus
-keep class com.lib.flutter_blue_plus.** { *; }

# Connectivity Plus
-keep class dev.fluttercommunity.plus.connectivity.** { *; }

# Permission handler
-keep class com.baseflow.permissionhandler.** { *; }

# JNI bridge (used by cryptography native)
-keep class com.github.dart_lang.jni.** { *; }

# Keep enums intact — Dart reflection may reference them by name
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Keep Parcelable implementations
-keep class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}
