package com.example.app_locker

import com.example.app_locker.bridge.AppLockerBridge
import com.example.app_locker.utils.LockOverlayManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Activity principal: UI de configuración en Flutter (rutas /, /permissions,
 * /home, /config-app). Es una FlutterFragmentActivity porque local_auth
 * necesita un FragmentActivity para mostrar BiometricPrompt.
 */
class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AppLockerBridge.registerMainBridge(this, flutterEngine)
        // Precalienta el motor de bloqueo para que el primer overlay sea inmediato.
        LockOverlayManager.warmUp(applicationContext)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        AppLockerBridge.unregisterMainBridge()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
