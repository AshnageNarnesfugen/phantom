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

# Phantom native bridges — referenced from AndroidManifest.xml (services,
# receiver, activity) and from MainActivity's MethodChannel handlers via
# Companion.startIntent / stopIntent calls. R8 keeps the class skeletons
# because the manifest references them by name, but it can still strip
# member functions, companion objects, and overridden lifecycle methods
# when their callers are obfuscated. Keep everything in these classes
# verbatim so the foreground services actually start in release mode.
-keep class com.phantom.phantom_messenger.MainActivity { *; }
-keep class com.phantom.phantom_messenger.IpfsForegroundService { *; }
-keep class com.phantom.phantom_messenger.IpfsForegroundService$Companion { *; }
-keep class com.phantom.phantom_messenger.IpfsBootReceiver { *; }
-keep class com.phantom.phantom_messenger.I2pdForegroundService { *; }
-keep class com.phantom.phantom_messenger.I2pdForegroundService$Companion { *; }
-keep class com.phantom.phantom_messenger.I2pdBootReceiver { *; }
-keep class com.phantom.phantom_messenger.YggdrasilVpnService { *; }
-keep class com.phantom.phantom_messenger.YggdrasilVpnService$Companion { *; }
-keep class com.phantom.phantom_messenger.PhantomMessagingService { *; }
-keep class com.phantom.phantom_messenger.PhantomMessagingService$Companion { *; }
-keep class com.phantom.phantom_messenger.PhantomGattServer { *; }

# Yggdrasil mobile bind — we load mobile.Yggdrasil reflectively from
# YggdrasilVpnService when the .aar is present in the APK. R8 must not
# rename or strip it; missing entirely is fine (class load just fails).
-keep class mobile.** { *; }
-dontwarn mobile.**

# Flutter secure storage — algorithm migration runs at startup; the
# library uses internal ciphers reflected via class name lookup.
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-dontwarn com.it_nomads.fluttersecurestorage.**

# Hive (real package id is io.isar.hive in v2 / hive_flutter)
-keep class com.tekartik.** { *; }
-keep class io.isar.** { *; }
