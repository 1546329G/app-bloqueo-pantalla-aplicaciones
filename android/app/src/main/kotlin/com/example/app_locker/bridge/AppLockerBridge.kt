package com.example.app_locker.bridge

import android.Manifest
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.text.TextUtils
import android.util.LruCache
import android.view.WindowManager
import android.view.accessibility.AccessibilityManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.example.app_locker.services.AppLockAccessibilityService
import com.example.app_locker.services.KeepAliveForegroundService
import com.example.app_locker.utils.LockOverlayManager
import com.example.app_locker.utils.LockPrefs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.lang.ref.WeakReference

/**
 * Puente Dart <-> Kotlin.
 *
 * Canales:
 *  - com.example.app_locker/main   : Dart(NO principal) -> Kotlin. Permisos,
 *    listado/iconos de apps, sync del mapa de bloqueo, FLAG_SECURE, etc.
 *  - com.example.app_locker/events : Kotlin -> Dart (EventChannel). Estado del
 *    servicio y eventos de bloqueo para refrescar la UI.
 *  - com.example.app_locker/lock   : canal del motor Flutter de bloqueo
 *    (LockScreenActivity). Pull de estado + resultado del desbloqueo.
 */
object AppLockerBridge {

    const val MAIN_CHANNEL = "com.example.app_locker/main"
    const val EVENTS_CHANNEL = "com.example.app_locker/events"
    const val LOCK_CHANNEL = "com.example.app_locker/lock"

    private const val REQ_CODE_NOTIFICATIONS = 7201
    private const val ICON_SIZE_PX = 144
    private const val ICON_CACHE_ENTRIES = 128

    private val mainHandler = Handler(Looper.getMainLooper())
    private val iconCache = LruCache<String, ByteArray>(ICON_CACHE_ENTRIES)

    private var mainActivityRef = WeakReference<Activity>(null)
    private var eventsSink: EventChannel.EventSink? = null
    private var lockChannel: MethodChannel? = null

    // ------------------------------------------------------------------
    // Registro (lo llaman MainActivity y LockOverlayManager)
    // ------------------------------------------------------------------

    fun registerMainBridge(activity: Activity, engine: FlutterEngine) {
        mainActivityRef = WeakReference(activity)
        LockPrefs.init(activity.applicationContext)

        MethodChannel(engine.dartExecutor.binaryMessenger, MAIN_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    handleMainCall(call, result)
                } catch (t: Throwable) {
                    result.error("app_locker_error", t.message ?: t.toString(), null)
                }
            }

        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventsSink = sink
                    LockOverlayManager.setEventDispatcher { event -> emitEvent(event) }
                    emitEvent(
                        mapOf(
                            "type" to "connected",
                            "blockedCount" to LockPrefs.blockedCount(),
                            "keepAliveRunning" to KeepAliveForegroundService.isRunning
                        )
                    )
                }

                override fun onCancel(arguments: Any?) {
                    eventsSink = null
                    LockOverlayManager.setEventDispatcher(null)
                }
            })
    }

    fun unregisterMainBridge() {
        eventsSink = null
        mainActivityRef = WeakReference(null)
        LockOverlayManager.setEventDispatcher(null)
    }

    fun registerLockBridge(engine: FlutterEngine, context: Context) {
        LockPrefs.init(context.applicationContext)
        lockChannel = MethodChannel(engine.dartExecutor.binaryMessenger, LOCK_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                try {
                    handleLockCall(call, result)
                } catch (t: Throwable) {
                    result.error("app_locker_error", t.message ?: t.toString(), null)
                }
            }
        }
    }

    /** Kotlin -> Dart (isolate de bloqueo). Siempre en el hilo principal. */
    fun invokeOnLockChannel(method: String, arguments: Any?) {
        mainHandler.post { lockChannel?.invokeMethod(method, arguments) }
    }

    /** Kotlin -> Dart (isolate principal) por el EventChannel. */
    fun emitEvent(event: Map<String, Any?>) {
        mainHandler.post { eventsSink?.success(event) }
    }

    // ------------------------------------------------------------------
    // Canal principal
    // ------------------------------------------------------------------

    private fun handleMainCall(call: MethodCall, result: MethodChannel.Result) {
        val context: Context = mainActivityRef.get()?.applicationContext
            ?: return result.error("no_context", "La Activity principal no está activa", null)
        LockPrefs.init(context)

        when (call.method) {
            "getStatus" -> result.success(buildStatus(context))

            "openAccessibilitySettings" ->
                result.success(openSettings(context, Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)))

            "openOverlaySettings" -> {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:${context.packageName}")
                )
                result.success(openSettings(context, intent))
            }

            "openBatteryOptimizationSettings" ->
                result.success(openSettings(context, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)))

            "requestIgnoreBatteryOptimizations" -> {
                val intent = Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${context.packageName}")
                )
                result.success(openSettings(context, intent))
            }

            "requestNotificationPermission" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    !notificationsGranted(context)
                ) {
                    val activity = mainActivityRef.get()
                        ?: return result.error("no_activity", "Activity no disponible", null)
                    ActivityCompat.requestPermissions(
                        activity,
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        REQ_CODE_NOTIFICATIONS
                    )
                }
                result.success(true)
            }

            "startKeepAliveService" -> {
                val started = KeepAliveForegroundService.start(context)
                LockOverlayManager.warmUp(context)
                emitEvent(mapOf("type" to "keepAliveState", "running" to started))
                result.success(started)
            }

            "getInstalledApps" -> result.success(getInstalledApps(context))

            "getAppIcon" -> {
                val packageName = call.argument<String>("packageName")
                result.success(packageName?.let { getAppIcon(context, it) })
            }

            "setAppLock" -> {
                val packageName = call.argument<String>("packageName")
                val blocked = call.argument<Boolean>("isLocked") ?: false
                val lockType = call.argument<String>("lockType")
                    ?: LockPrefs.LOCK_TYPE_PIN
                if (packageName.isNullOrBlank()) {
                    result.error("bad_args", "packageName requerido", null)
                } else {
                    LockPrefs.setAppLock(packageName, blocked, lockType)
                    emitEvent(
                        mapOf(
                            "type" to "locksChanged",
                            "blockedCount" to LockPrefs.blockedCount()
                        )
                    )
                    result.success(true)
                }
            }

            "syncLockedApps" -> {
                val raw = (call.arguments as? Map<*, *>)?.get("apps")
                LockPrefs.syncFromDart(readEntries(raw))
                emitEvent(
                    mapOf(
                        "type" to "locksChanged",
                        "blockedCount" to LockPrefs.blockedCount()
                    )
                )
                result.success(LockPrefs.blockedCount())
            }

            "getLockedApps" -> result.success(LockPrefs.snapshot())

            "setSecureScreen" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                val activity = mainActivityRef.get()
                mainHandler.post {
                    activity?.window?.let { window ->
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                }
                result.success(true)
            }

            "openInstalledApp" -> {
                val packageName = call.argument<String>("packageName")
                result.success(packageName?.let { launchApp(context, it) } ?: false)
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------
    // Canal de bloqueo (LockScreenActivity)
    // ------------------------------------------------------------------

    private fun handleLockCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getActiveLock" -> result.success(LockOverlayManager.getActiveLockState())

            "submitUnlock" -> {
                val packageName = call.argument<String>("packageName")
                val success = call.argument<Boolean>("success") ?: false
                if (packageName.isNullOrBlank()) {
                    result.error("bad_args", "packageName requerido", null)
                } else {
                    result.success(LockOverlayManager.submitUnlock(packageName, success))
                }
            }

            // "Salir al Inicio": abre el Launcher y retira el bloqueo.
            "goToHome" -> {
                LockOverlayManager.goToHome()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------
    // Estado de permisos y servicios
    // ------------------------------------------------------------------

    private fun buildStatus(context: Context): Map<String, Any?> = mapOf(
        "accessibilityEnabled" to isAccessibilityServiceEnabled(context),
        "overlayGranted" to Settings.canDrawOverlays(context),
        "batteryOptimizationIgnored" to isBatteryOptimizationIgnored(context),
        "notificationsGranted" to notificationsGranted(context),
        "keepAliveRunning" to KeepAliveForegroundService.isRunning,
        "lockEngineReady" to (LockOverlayManager.lockEngine() != null),
        "blockedCount" to LockPrefs.blockedCount()
    )

    /**
     * Doble verificación (Settings.Secure + AccessibilityManager) porque en
     * algunas ROMs el string de Settings.Secure usa el nombre corto del
     * componente o va vacío aunque el servicio esté conectado.
     */
    private fun isAccessibilityServiceEnabled(context: Context): Boolean {
        val expectedFull = "${context.packageName}/${AppLockAccessibilityService::class.java.name}"
        val expectedShort = "${context.packageName}/.services.AppLockAccessibilityService"
        val enabledServices = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        )
        if (!enabledServices.isNullOrEmpty()) {
            val splitter = TextUtils.SimpleStringSplitter(':')
            splitter.setString(enabledServices)
            for (service in splitter) {
                if (service.equals(expectedFull, ignoreCase = true) ||
                    service.equals(expectedShort, ignoreCase = true)
                ) {
                    return true
                }
            }
        }
        val manager = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
            ?: return false
        return manager
            .getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
            .any { it.resolveInfo?.serviceInfo?.packageName == context.packageName }
    }

    private fun isBatteryOptimizationIgnored(context: Context): Boolean {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            ?: return false
        return powerManager.isIgnoringBatteryOptimizations(context.packageName)
    }

    private fun notificationsGranted(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

    // ------------------------------------------------------------------
    // Apps instaladas e iconos
    // ------------------------------------------------------------------

    @Suppress("DEPRECATION")
    private fun getInstalledApps(context: Context): List<Map<String, Any>> {
        val pm = context.packageManager
        val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.queryIntentActivities(launcherIntent, PackageManager.ResolveInfoFlags.of(0L))
        } else {
            pm.queryIntentActivities(launcherIntent, 0)
        }
        val seen = HashSet<String>()
        val apps = ArrayList<Map<String, Any>>(resolved.size)
        for (info in resolved) {
            val appInfo = info.activityInfo?.applicationInfo ?: continue
            val pkg = appInfo.packageName
            if (pkg == context.packageName || !seen.add(pkg)) continue
            apps.add(
                mapOf(
                    "packageName" to pkg,
                    "appName" to appInfo.loadLabel(pm).toString(),
                    "isSystem" to ((appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0)
                )
            )
        }
        apps.sortBy { (it["appName"] as String).lowercase() }
        return apps
    }

    private fun getAppIcon(context: Context, packageName: String): ByteArray? {
        iconCache.get(packageName)?.let { return it }
        return try {
            val drawable = context.packageManager.getApplicationIcon(packageName)
            val bitmap = drawableToBitmap(drawable, ICON_SIZE_PX)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            val bytes = stream.toByteArray()
            iconCache.put(packageName, bytes)
            if (drawable !is BitmapDrawable) bitmap.recycle()
            bytes
        } catch (t: Throwable) {
            null
        }
    }

    private fun drawableToBitmap(drawable: Drawable, sizePx: Int): Bitmap {
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            val source = drawable.bitmap
            return if (source.width <= sizePx && source.height <= sizePx) {
                source
            } else {
                Bitmap.createScaledBitmap(source, sizePx, sizePx, true)
            }
        }
        val bitmap = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, sizePx, sizePx)
        drawable.draw(canvas)
        return bitmap
    }

    private fun launchApp(context: Context, packageName: String): Boolean {
        val intent = context.packageManager.getLaunchIntentForPackage(packageName)
            ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (t: Throwable) {
            false
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /** Convierte List<dynamic> de Dart en algo tipado, sin ClassCastException. */
    private fun readEntries(raw: Any?): List<Map<String, Any?>> {
        val list = raw as? List<*> ?: return emptyList()
        return list.mapNotNull { item ->
            val map = item as? Map<*, *> ?: return@mapNotNull null
            map.entries.associate { (key, value) -> key.toString() to value }
        }
    }

    private fun openSettings(context: Context, intent: Intent): Boolean {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (t: Throwable) {
            false
        }
    }
}
