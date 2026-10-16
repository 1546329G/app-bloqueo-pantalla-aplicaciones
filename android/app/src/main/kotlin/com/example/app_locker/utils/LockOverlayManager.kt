package com.example.app_locker.utils

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.example.app_locker.LockScreenActivity
import com.example.app_locker.bridge.AppLockerBridge
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicLong

/**
 * Cerebro del bloqueo en tiempo real. Máquina de estados + lanzamiento de la
 * pantalla de bloqueo sobre la app detectada por el AccessibilityService.
 *
 * Estados:
 *  - activeLockPackage: app bloqueada cuya pantalla de bloqueo está visible.
 *  - unlockedPackage:   app que el usuario desbloqueó en esta sesión (sigue
 *                       desbloqueada mientras permanezca en primer plano).
 *
 * Motor Flutter dedicado y precargado ("lock engine"): la FlutterActivity de
 * bloqueo se monta sobre un engine ya inicializado, lo que reduce la latencia
 * de apertura a decenas de milisegundos en lugar de cientos.
 */
object LockOverlayManager {

    private const val TAG = "AppLocker"

    const val LOCK_ENGINE_ID = "app_locker_lock_engine"

    private const val EVT_LOCK_SHOWN = "lockShown"
    private const val EVT_LOCK_DISMISSED = "lockDismissed"
    private const val EVT_UNLOCKED = "unlocked"
    private const val EVT_UNLOCK_FAILED = "unlockFailed"

    /** Paquetes de sistema que generan eventos de ventana pero no son "apps". */
    private val IGNORED_PACKAGES = setOf("com.android.systemui", "android")

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var activeLockPackage: String? = null

    @Volatile
    private var unlockedPackage: String? = null

    @Volatile
    private var lastResolvedLabel: String = ""

    /**
     * Identificador de la sesión de bloqueo actual: se incrementa en cada
     * bloqueo nuevo. Dart lo usa como parte del estado de las pantallas de
     * bloqueo para que el motor reutilizado arranque siempre limpio (aunque
     * la app y el método coincidan con el bloqueo anterior).
     */
    private val sessionCounter = AtomicLong(0L)

    @Volatile
    private var lockSessionId: Long = 0L

    /** Contexto de aplicación para abrir el Launcher desde "Salir al Inicio". */
    @Volatile
    private var appContext: Context? = null

    private var engine: FlutterEngine? = null

    private var lockActivityRef: WeakReference<LockScreenActivity>? = null

    private var eventDispatcher: ((Map<String, Any?>) -> Unit)? = null

    // ------------------------------------------------------------------
    // Ciclo de vida / preparación
    // ------------------------------------------------------------------

    /**
     * Precarga prefs + motor Flutter. Se invoca al conectar el
     * AccessibilityService y al arrancar el KeepAliveForegroundService, de
     * modo que el primer bloqueo real sea instantáneo.
     */
    fun warmUp(context: Context) {
        val app = context.applicationContext
        appContext = app
        LockPrefs.init(app)
        runOnMain { ensureEngine(app) }
    }

    fun lockEngine(): FlutterEngine? = engine

    fun isLockVisible(): Boolean = activeLockPackage != null

    fun activePackage(): String? = activeLockPackage

    private fun ensureEngine(context: Context): FlutterEngine {
        engine?.let { return it }
        FlutterEngineCache.getInstance().get(LOCK_ENGINE_ID)?.let { cached ->
            engine = cached
            return cached
        }
        // El constructor público de FlutterEngine registra plugins automáticamente
        // (GeneratedPluginRegistrant) y ejecuta el entrypoint main() de Dart.
        val created = FlutterEngine(context.applicationContext)
        AppLockerBridge.registerLockBridge(created, context.applicationContext)
        FlutterEngineCache.getInstance().put(LOCK_ENGINE_ID, created)
        engine = created
        return created
    }

    // ------------------------------------------------------------------
    // Hot-path: llamado por AppLockAccessibilityService en cada
    // TYPE_WINDOW_STATE_CHANGED.
    // ------------------------------------------------------------------

    fun onForegroundPackageChanged(context: Context, foregroundPackage: String) {
        val app = context.applicationContext
        runOnMain { handleForegroundPackage(app, foregroundPackage) }
    }

    private fun handleForegroundPackage(context: Context, pkg: String) {
        LockPrefs.init(context)

        // Nuestra propia UI (config o lock screen) y el SystemUI no cuentan
        // como "app abierta" para la máquina de estados.
        if (pkg == context.packageName || pkg in IGNORED_PACKAGES) {
            Log.d(TAG, "fg=$pkg (ignorada: propia o systemui)")
            return
        }

        val active = activeLockPackage
        // Eventos internos de la app que ya está bloqueada bajo el overlay.
        if (active == pkg) {
            Log.d(TAG, "fg=$pkg (misma que activeLock, ignorada)")
            return
        }

        // Cambio de app: la sesión de desbloqueo caduca al salir de esa app.
        if (unlockedPackage != null && pkg != unlockedPackage) unlockedPackage = null

        val isBlocked = LockPrefs.isBlocked(pkg)
        val mustLock = pkg != unlockedPackage && isBlocked
        Log.d(TAG, "fg=$pkg active=$active unlocked=$unlockedPackage blocked=$isBlocked mustLock=$mustLock")
        when {
            // Bloquear la nueva app reutilizando la Activity si sigue viva
            // (singleInstance → onNewIntent) o creándola si no.
            mustLock -> showLock(context, pkg)
            // La app bloqueada anterior salió de pantalla y la nueva no está
            // bloqueada: se retira el overlay.
            active != null -> {
                activeLockPackage = null
                dispatchEvent(
                    mapOf("type" to EVT_LOCK_DISMISSED, "packageName" to active, "reason" to "appClosed")
                )
                dismissActivity("appClosed")
            }
        }
    }

    // ------------------------------------------------------------------
    // Mostrar / retirar la pantalla de bloqueo
    // ------------------------------------------------------------------

    private fun showLock(context: Context, pkg: String) {
        activeLockPackage = pkg
        lastResolvedLabel = resolveAppLabel(context, pkg)
        lockSessionId = sessionCounter.incrementAndGet()
        val lockType = LockPrefs.lockTypeOf(pkg) ?: LockPrefs.LOCK_TYPE_PIN
        Log.d(TAG, "showLock: pkg=$pkg type=$lockType session=$lockSessionId")

        ensureEngine(context)

        val intent = Intent(context, LockScreenActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TASK or
                    Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS
            )
            putExtra(LockScreenActivity.EXTRA_PACKAGE_NAME, pkg)
            putExtra(LockScreenActivity.EXTRA_APP_LABEL, lastResolvedLabel)
            putExtra(LockScreenActivity.EXTRA_LOCK_TYPE, lockType)
        }

        try {
            Log.d(TAG, "showLock: llamando startActivity...")
            context.startActivity(intent)
            Log.d(TAG, "showLock: startActivity OK")
        } catch (t: Throwable) {
            Log.e(TAG, "showLock FAILED: ${t.javaClass.simpleName}: ${t.message}", t)
            // Sin permiso de superposición o bloqueo de background start:
            // se aborta el estado para no dejar la máquina de estados colgada.
            activeLockPackage = null
            return
        }

        dispatchEvent(
            mapOf(
                "type" to EVT_LOCK_SHOWN,
                "packageName" to pkg,
                "appLabel" to lastResolvedLabel,
                "lockType" to lockType,
                "sessionId" to lockSessionId
            )
        )
        pushLockStateToDart()
    }

    /** Cierre "administrativo" (la app bloqueada desapareció del foreground). */
    private fun finishLock(reason: String) {
        val pkg = activeLockPackage ?: return
        activeLockPackage = null
        dispatchEvent(mapOf("type" to EVT_LOCK_DISMISSED, "packageName" to pkg, "reason" to reason))
        dismissActivity(reason)
    }

    fun forceDismiss(reason: String = "manual") = finishLock(reason)

    private fun dismissActivity(reason: String) {
        AppLockerBridge.invokeOnLockChannel("onLockDismissed", mapOf("reason" to reason))
        runOnMain {
            lockActivityRef?.get()?.let { activity ->
                lockActivityRef = null
                if (!activity.isFinishing) activity.finish()
            }
        }
    }

    // ------------------------------------------------------------------
    // Desbloqueo (invocado desde Dart a través de AppLockerBridge)
    // ------------------------------------------------------------------

    /**
     * Dart ya verificó PIN/patrón/biometría. Si coincide con el paquete
     * bloqueado actual, se marca la sesión como desbloqueada y se retira el
     * overlay. La app volverá a bloquearse la próxima vez que pase a primer
     * plano desde otra aplicación.
     */
    fun submitUnlock(packageName: String, success: Boolean): Boolean {
        if (!success) {
            dispatchEvent(mapOf("type" to EVT_UNLOCK_FAILED, "packageName" to packageName))
            return false
        }
        if (activeLockPackage != packageName) return false
        activeLockPackage = null
        unlockedPackage = packageName
        dispatchEvent(mapOf("type" to EVT_UNLOCKED, "packageName" to packageName))
        dismissActivity("unlocked")
        return true
    }

    /**
     * La sesión de desbloqueo caduca también al apagarse la pantalla
     * (requisito: desbloqueo "temporal" hasta apagar pantalla o cambiar de
     * app). Si el usuario vuelve a abrir la app protegida, se le pedirá la
     * clave de nuevo.
     */
    fun onScreenOff() {
        runOnMain {
            unlockedPackage = null
        }
    }

    /**
     * "Salir al Inicio": el usuario decide no desbloquear la app. Se abre el
     * Launcher del teléfono y se retira el overlay (el estado queda limpio,
     * de modo que al volver a abrir la app protegida se pedirá la clave otra
     * vez). Si el Launcher no responde, se retira el overlay igualmente.
     */
    fun goToHome() {
        val context = lockActivityRef?.get()?.applicationContext ?: appContext
        if (context != null) {
            val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            try {
                context.startActivity(homeIntent)
            } catch (_: Throwable) {
                // Sin Launcher disponible: solo se retira el bloqueo.
            }
        }
        runOnMain { finishLock("home") }
    }

    // ------------------------------------------------------------------
    // Puente con el isolate Flutter de bloqueo
    // ------------------------------------------------------------------

    /** Estado que Dart consulta al arrancar (pull) para no perderse ningún evento. */
    fun getActiveLockState(): Map<String, Any?>? {
        val pkg = activeLockPackage ?: return null
        return mapOf(
            "packageName" to pkg,
            "appLabel" to lastResolvedLabel,
            "lockType" to (LockPrefs.lockTypeOf(pkg) ?: LockPrefs.LOCK_TYPE_PIN),
            "sessionId" to lockSessionId
        )
    }

    /** Empuja el estado actual al isolate de bloqueo (push), idempotente. */
    fun pushLockStateToDart() {
        val state = getActiveLockState() ?: return
        AppLockerBridge.invokeOnLockChannel("onShowLockScreen", state)
    }

    fun attachLockActivity(activity: LockScreenActivity) {
        lockActivityRef = WeakReference(activity)
    }

    fun detachLockActivity(activity: LockScreenActivity) {
        if (lockActivityRef?.get() === activity) lockActivityRef = null
    }

    // ------------------------------------------------------------------
    // Eventos hacia el isolate principal (EventChannel)
    // ------------------------------------------------------------------

    fun setEventDispatcher(dispatcher: ((Map<String, Any?>) -> Unit)?) {
        eventDispatcher = dispatcher
    }

    private fun dispatchEvent(event: Map<String, Any?>) {
        eventDispatcher?.invoke(event)
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private fun resolveAppLabel(context: Context, pkg: String): String = try {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (t: Throwable) {
        pkg
    }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post(block)
        }
    }
}
