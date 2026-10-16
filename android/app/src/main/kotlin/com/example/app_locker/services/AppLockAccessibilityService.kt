package com.example.app_locker.services

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import com.example.app_locker.utils.LockOverlayManager
import com.example.app_locker.utils.LockPrefs

/**
 * Detección en tiempo real de la app en primer plano.
 *
 * El sistema entrega TYPE_WINDOW_STATE_CHANGED (push, sin polling → sin
 * consumo de batería en reposo) cada vez que cambia la ventana activa. El
 * coste por evento es mínimo: una comprobación de Set en memoria (LockPrefs)
 * y, solo si el paquete está bloqueado, el lanzamiento del overlay.
 */
class AppLockAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "AppLocker"

        @Volatile
        var instance: AppLockAccessibilityService? = null
            private set

        fun isRunning(): Boolean = instance != null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        val context = applicationContext
        Log.d(TAG, "a11y service CONNECTED, init prefs + warmUp")
        // Caches de preferencias listas + motor Flutter de bloqueo precargado:
        // el primer bloqueo real no paga el coste de arranque del engine.
        LockPrefs.init(context)
        LockOverlayManager.warmUp(context)
        Log.d(TAG, "a11y service READY, blockedCount=${LockPrefs.blockedCount()}")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val e = event ?: return
        if (e.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            Log.d(TAG, "event type=${e.eventType} pkg=${e.packageName} (no WSC, ignorado)")
            return
        }
        val packageName = e.packageName?.toString() ?: return
        if (packageName.isEmpty()) return
        Log.d(TAG, "WSC event: pkg=$packageName")
        LockOverlayManager.onForegroundPackageChanged(applicationContext, packageName)
    }

    override fun onInterrupt() {
        // No hay nada que interrumpir: el servicio es pasivo.
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }
}
