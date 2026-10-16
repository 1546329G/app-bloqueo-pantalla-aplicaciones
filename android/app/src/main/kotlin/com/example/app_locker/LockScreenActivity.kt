package com.example.app_locker

import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import com.example.app_locker.utils.LockOverlayManager
import io.flutter.embedding.android.FlutterFragmentActivity

/**
 * Pantalla de bloqueo. Es una FlutterActivity transparente que se monta
 * SOBRE la app bloqueada:
 *
 *  - launchMode="singleInstance" + taskAffinity propia (en el manifest) para
 *    que viva aislada en su propia tarea y no interfiera con la app víctima.
 *  - Motor Flutter dedicado y precargado (LOCK_ENGINE_ID): la actividad se
 *    dibuja en pantalla en decenas de milisegundos.
 *  - FLAG_SECURE: sin capturas de pantalla ni grabación de pantalla mientras
 *    el bloqueo está visible.
 *  - excludeFromRecents (manifest) + onBackPressed() bloqueado: no se puede
 *    saltar con el botón atrás ni verla en "recientes".
 */
class LockScreenActivity : FlutterFragmentActivity() {

    companion object {
        const val EXTRA_PACKAGE_NAME = "extra_package_name"
        const val EXTRA_APP_LABEL = "extra_app_label"
        const val EXTRA_LOCK_TYPE = "extra_lock_type"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d("AppLocker", "LockScreenActivity onCreate pkg=${intent?.getStringExtra(EXTRA_PACKAGE_NAME)}")
        // Seguridad de ventana: bloquea screenshots, grabación y preview.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        setFinishOnTouchOutside(false)
    }

    /**
     * El motor de bloqueo SIEMPRE arranca en /lock/standby (pantalla opaca
     * anti-flash). NativeBridge detecta el bloqueo activo y navega a la
     * pantalla correspondiente. Forzamos esta ruta para que la detección en
     * Dart (basada en isLockEngine) no importe: aunque falle, el usuario ve
     * una pantalla oscura en vez del splash de configuración.
     */
    override fun getInitialRoute(): String = "/lock/standby"

    override fun onResume() {
        super.onResume()
        Log.d("AppLocker", "LockScreenActivity onResume")
        LockOverlayManager.attachLockActivity(this)
        LockOverlayManager.pushLockStateToDart()
        // Segundo empujón tras el primer frame: si el motor arrancó en frío,
        // el isolate puede no tener todavía el handler del canal registrado.
        // Dart además consulta el estado con getActiveLock al inicializarse.
        window.decorView.postDelayed(
            { if (!isFinishing) LockOverlayManager.pushLockStateToDart() },
            300L
        )
    }

    override fun onPause() {
        Log.d("AppLocker", "LockScreenActivity onPause isFinishing=$isFinishing")
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        Log.d("AppLocker", "LockScreenActivity onNewIntent pkg=${intent.getStringExtra(EXTRA_PACKAGE_NAME)}")
        LockOverlayManager.pushLockStateToDart()
    }

    override fun onDestroy() {
        Log.d("AppLocker", "LockScreenActivity onDestroy isFinishing=$isFinishing")
        LockOverlayManager.detachLockActivity(this)
        super.onDestroy()
    }

    /**
     * El botón atrás NUNCA debe cerrar la pantalla de bloqueo: revelaría la
     * app protegida. La única salida es desbloquear o pasar a otra app
     * (home); en ese caso LockOverlayManager retira el overlay.
     */
    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        Log.d("AppLocker", "LockScreenActivity onBackPressed (bloqueado)")
        // Intencionadamente vacío.
    }
}
