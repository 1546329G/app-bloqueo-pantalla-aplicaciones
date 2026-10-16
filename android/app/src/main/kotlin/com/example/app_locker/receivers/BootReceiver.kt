package com.example.app_locker.receivers

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.example.app_locker.services.KeepAliveForegroundService
import com.example.app_locker.utils.LockPrefs

/**
 * Supervivencia al reinicio del dispositivo y red de seguridad del servicio.
 *
 * Acciones atendidas:
 *  - BOOT_COMPLETED            : arranque normal del sistema (con el usuario).
 *  - QUICKBOOT_POWERON (x2)    : variantes de fabricantes (HTC/MTK, etc.).
 *  - MY_PACKAGE_REPLACED       : la app se actualizó → hay que relanzar el FGS.
 *  - RESTART_SERVICE / WATCHDOG: alarmas propias (AlarmManager) que rearman el
 *    servicio si el sistema lo mató (START_STICKY no es infalible).
 *
 * Nota: el receiver es exported=false. Los broadcasts de sistema (uid 1000)
 * se entregan igualmente; las alarmas son PendingIntent de la propia app.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_RESTART_SERVICE = "com.example.app_locker.action.RESTART_SERVICE"
        const val ACTION_WATCHDOG = "com.example.app_locker.action.WATCHDOG"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
            Intent.ACTION_MY_PACKAGE_REPLACED,
            ACTION_RESTART_SERVICE,
            ACTION_WATCHDOG -> {
                val app = context.applicationContext
                LockPrefs.init(app)
                KeepAliveForegroundService.start(app)
            }
        }
    }
}
