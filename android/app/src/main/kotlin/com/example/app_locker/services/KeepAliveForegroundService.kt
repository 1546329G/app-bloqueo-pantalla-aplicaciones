package com.example.app_locker.services

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.ServiceCompat
import com.example.app_locker.MainActivity
import com.example.app_locker.R
import com.example.app_locker.bridge.AppLockerBridge
import com.example.app_locker.receivers.BootReceiver
import com.example.app_locker.utils.LockOverlayManager
import com.example.app_locker.utils.LockPrefs

/**
 * Servicio en primer plano: la "inmortalidad" del bloqueador.
 *
 * Estrategia de supervivencia (Android 10+):
 *  1. startForeground con notificación silenciosa (IMPORTANCE_LOW): el proceso
 *     pasa a la prioridad más alta y el sistema evita matarlo.
 *  2. START_STICKY: si el sistema lo mata por memoria, lo recrea.
 *  3. stopWithTask=false + onTaskRemoved → alarma de rearme inmediata.
 *  4. Watchdog cada 15 min (AlarmManager, doze-friendly) que rearma el
 *     servicio si algo lo detuvo.
 *  5. Solicitud de exclusión de batería desde la UI (REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).
 *
 * Además, al arrancar precarga el motor Flutter de bloqueo y detecta la
 * desinstalación de apps protegidas para limpiar su configuración.
 */
class KeepAliveForegroundService : Service() {

    companion object {
        const val NOTIFICATION_CHANNEL_ID = "app_locker_keepalive"
        const val NOTIFICATION_ID = 8410

        private const val REQUEST_CODE_RESTART = 8411
        private const val REQUEST_CODE_WATCHDOG = 8412
        private const val RESTART_DELAY_MS = 1500L
        private const val WATCHDOG_INTERVAL_MS = 15 * 60 * 1000L
        private const val LOCK_ENGINE_WARMUP_DELAY_MS = 2500L

        @Volatile
        var isRunning = false
            private set

        /**
         * Arranca (o rearma) el servicio. Devuelve false si el sistema lo
         * bloqueó (background start restrictions); en ese caso programa un
         * reintento por alarma.
         */
        fun start(context: Context): Boolean {
            val app = context.applicationContext
            val intent = Intent(app, KeepAliveForegroundService::class.java)
            return try {
                app.startForegroundService(intent)
                true
            } catch (t: Throwable) {
                scheduleRestart(app, RESTART_DELAY_MS)
                false
            }
        }

        /** Red de seguridad a corto plazo (p. ej. tras onTaskRemoved). */
        fun scheduleRestart(context: Context, delayMs: Long = RESTART_DELAY_MS) {
            val app = context.applicationContext
            val alarmManager = app.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
            val intent = Intent(app, BootReceiver::class.java)
                .setAction(BootReceiver.ACTION_RESTART_SERVICE)
            val pendingIntent = PendingIntent.getBroadcast(
                app,
                REQUEST_CODE_RESTART,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            try {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    SystemClock.elapsedRealtime() + delayMs,
                    pendingIntent
                )
            } catch (t: Throwable) {
                // Sin cupo de alarmas o sistema caprichoso: START_STICKY decide.
            }
        }

        /** Watchdog periódico (se rearma a sí mismo en cada disparo). */
        fun scheduleWatchdog(context: Context) {
            val app = context.applicationContext
            val alarmManager = app.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
            val intent = Intent(app, BootReceiver::class.java)
                .setAction(BootReceiver.ACTION_WATCHDOG)
            val pendingIntent = PendingIntent.getBroadcast(
                app,
                REQUEST_CODE_WATCHDOG,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            try {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    SystemClock.elapsedRealtime() + WATCHDOG_INTERVAL_MS,
                    pendingIntent
                )
            } catch (t: Throwable) {
                // Ignorado: el watchdog es mejor esfuerzo.
            }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var packageReceiverRegistered = false
    private var screenReceiverRegistered = false

    /** Limpieza de configuraciones huérfanas al desinstalar una app. */
    private val packageReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent?) {
            if (intent?.action != Intent.ACTION_PACKAGE_REMOVED) return
            val pkg = intent.data?.schemeSpecificPart ?: return
            if (LockPrefs.isBlocked(pkg)) {
                LockPrefs.remove(pkg)
                AppLockerBridge.emitEvent(
                    mapOf(
                        "type" to "locksChanged",
                        "removedPackage" to pkg,
                        "blockedCount" to LockPrefs.blockedCount()
                    )
                )
            }
        }
    }

    /**
     * La sesión de desbloqueo caduca al apagarse la pantalla (ACTION_SCREEN_OFF
     * solo puede escucharse con receiver dinámico en Android 8+).
     */
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) {
                LockOverlayManager.onScreenOff()
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        val context = applicationContext
        LockPrefs.init(context)
        createNotificationChannel()
        registerPackageReceiver()
        registerScreenReceiver()
        // Precarga del motor de bloqueo fuera de la ventana crítica de arranque.
        mainHandler.postDelayed(
            { LockOverlayManager.warmUp(context) },
            LOCK_ENGINE_WARMUP_DELAY_MS
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        scheduleWatchdog(applicationContext)
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // El usuario deslizó la app fuera de "recientes": el FGS sigue vivo,
        // pero se rearma por si el sistema decide lo contrario.
        scheduleRestart(applicationContext, RESTART_DELAY_MS)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        isRunning = false
        scheduleRestart(applicationContext, RESTART_DELAY_MS)
        if (packageReceiverRegistered) {
            try {
                unregisterReceiver(packageReceiver)
            } catch (t: Throwable) {
                // Ya desregistrado.
            }
            packageReceiverRegistered = false
        }
        if (screenReceiverRegistered) {
            try {
                unregisterReceiver(screenReceiver)
            } catch (t: Throwable) {
                // Ya desregistrado.
            }
            screenReceiverRegistered = false
        }
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // Notificación / FGS
    // ------------------------------------------------------------------

    private fun startForegroundCompat() {
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceCompat.startForeground(
                    this,
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, 0)
            }
        } catch (t: Throwable) {
            // Degradación elegante (p. ej. notificaciones deshabilitadas):
            // el servicio sigue, aunque con menor prioridad.
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (ignored: Throwable) {
                // Sin FGS no queda otra: START_STICKY es la única red.
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                // Best effort: solicita que la notificación aparezca al
                // instante (sin el retraso de ~10 s que aplica el sistema).
                // Por reflexión: el símbolo no está disponible en todos los
                // SDK con los que se compila (java.lang.reflect).
                val behaviorField = try {
                    ServiceInfo::class.java.getField("FOREGROUND_SERVICE_IMMEDIATE")
                } catch (ignored: Throwable) {
                    Service::class.java.getField("FOREGROUND_SERVICE_IMMEDIATE")
                }
                val behavior = behaviorField.getInt(null)
                Service::class.java
                    .getMethod("setForegroundServiceBehavior", Integer.TYPE)
                    .invoke(this, behavior)
            } catch (t: Throwable) {
                // Best effort: si no existe, se mantiene el comportamiento normal.
            }
        }
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            getString(R.string.keepalive_channel_name),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.keepalive_channel_description)
            setShowBadge(false)
            enableLights(false)
            enableVibration(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_app_lock)
            .setContentTitle(getString(R.string.keepalive_notification_title))
            .setContentText(getString(R.string.keepalive_notification_text))
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(Notification.PRIORITY_LOW)
            .build()
    }

    private fun registerPackageReceiver() {
        if (packageReceiverRegistered) return
        val filter = IntentFilter(Intent.ACTION_PACKAGE_REMOVED).apply {
            addDataScheme("package")
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(packageReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(packageReceiver, filter)
            }
            packageReceiverRegistered = true
        } catch (t: Throwable) {
            packageReceiverRegistered = false
        }
    }

    private fun registerScreenReceiver() {
        if (screenReceiverRegistered) return
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(screenReceiver, filter)
            }
            screenReceiverRegistered = true
        } catch (t: Throwable) {
            screenReceiverRegistered = false
        }
    }
}
