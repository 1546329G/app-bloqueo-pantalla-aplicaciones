package com.example.app_locker.utils

import android.content.Context
import android.content.SharedPreferences

/**
 * Lectura ultrarrápida (O(1)) del mapa de apps bloqueadas, en memoria.
 *
 * Contrato de claves dentro del archivo SharedPreferences "app_locker_native"
 * (mismo shape que el JSON de Dart: {"com.whatsapp": {"isLocked": true, "lockType": "PIN"}}):
 *
 *   blocked::<packageName>    -> Boolean  (true si la app está bloqueada)
 *   lock_type::<packageName>  -> String   ("PIN" | "PATTERN" | "BIOMETRIC")
 *
 * El AccessibilityService recibe un evento de ventana por cada cambio de app:
 * leer un Boolean de un mapa en memoria (y no parsear JSON) es lo que mantiene
 * la detección en el rango de microsegundos. Dart sincroniza este archivo vía
 * MethodChannel (AppLockerBridge) y Kotlin solo lo lee.
 */
object LockPrefs {

    const val PREFS_NAME = "app_locker_native"

    const val LOCK_TYPE_PIN = "PIN"
    const val LOCK_TYPE_PATTERN = "PATTERN"
    const val LOCK_TYPE_BIOMETRIC = "BIOMETRIC"

    private const val KEY_PREFIX_BLOCKED = "blocked::"
    private const val KEY_PREFIX_LOCK_TYPE = "lock_type::"

    @Volatile
    private var prefs: SharedPreferences? = null

    // Caches en memoria: fuente de verdad para el hot-path del servicio.
    @Volatile
    private var blockedCache: Set<String> = emptySet()

    @Volatile
    private var lockTypeCache: Map<String, String> = emptyMap()

    private val initLock = Any()

    /** Idempotente y thread-safe. Debe llamarse antes que cualquier otra función. */
    fun init(context: Context) {
        if (prefs != null) return
        synchronized(initLock) {
            if (prefs == null) {
                prefs = context.applicationContext
                    .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                reload()
            }
        }
    }

    /** Hot-path del AccessibilityService: una comprobación de set en memoria. */
    fun isBlocked(packageName: String): Boolean = packageName in blockedCache

    fun lockTypeOf(packageName: String): String? = lockTypeCache[packageName]

    fun blockedCount(): Int = blockedCache.size

    /** Vista completa de lo bloqueado (para depuración o resincronización). */
    fun snapshot(): List<Map<String, Any>> =
        lockTypeCache.map { (pkg, type) ->
            mapOf("packageName" to pkg, "lockType" to type)
        }

    /** Alta/baja individual desde la pantalla de configuración de una app. */
    fun setAppLock(packageName: String, blocked: Boolean, lockType: String?) {
        val p = requirePrefs()
        val editor = p.edit()
        if (blocked && packageName.isNotBlank()) {
            editor.putBoolean(KEY_PREFIX_BLOCKED + packageName, true)
            editor.putString(KEY_PREFIX_LOCK_TYPE + packageName, normalizeLockType(lockType))
        } else {
            editor.remove(KEY_PREFIX_BLOCKED + packageName)
            editor.remove(KEY_PREFIX_LOCK_TYPE + packageName)
        }
        editor.commit()
        reload()
    }

    /**
     * Sincronización completa desde Dart. Reemplaza atómicamente todo el mapa:
     * se borran las entradas obsoletas y se escriben las nuevas en una sola
     * transacción, de modo que el servicio nunca vea un estado intermedio.
     */
    fun syncFromDart(entries: List<Map<String, Any?>>) {
        val p = requirePrefs()
        val editor = p.edit()
        p.all.keys.forEach { key ->
            if (key.startsWith(KEY_PREFIX_BLOCKED) || key.startsWith(KEY_PREFIX_LOCK_TYPE)) {
                editor.remove(key)
            }
        }
        entries.forEach { entry ->
            val pkg = entry["packageName"] as? String
            val blocked = entry["isLocked"] as? Boolean ?: false
            if (blocked && !pkg.isNullOrBlank()) {
                editor.putBoolean(KEY_PREFIX_BLOCKED + pkg, true)
                editor.putString(KEY_PREFIX_LOCK_TYPE + pkg, normalizeLockType(entry["lockType"] as? String))
            }
        }
        editor.commit()
        reload()
    }

    /** Limpieza cuando una app protegida se desinstala. */
    fun remove(packageName: String) = setAppLock(packageName, blocked = false, lockType = null)

    /** Reconstruye las caches en memoria desde el archivo de preferencias. */
    @Synchronized
    fun reload() {
        val p = prefs ?: return
        val blocked = HashSet<String>()
        val types = HashMap<String, String>()
        p.all.forEach { (key, value) ->
            when {
                key.startsWith(KEY_PREFIX_BLOCKED) && value == true ->
                    blocked.add(key.removePrefix(KEY_PREFIX_BLOCKED))
                key.startsWith(KEY_PREFIX_LOCK_TYPE) && value is String ->
                    types[key.removePrefix(KEY_PREFIX_LOCK_TYPE)] = value
            }
        }
        // Solo es válida una entrada que tenga bloqueo Y tipo de bloqueo.
        val valid = blocked.intersect(types.keys)
        lockTypeCache = HashMap(types.filterKeys { it in valid })
        blockedCache = HashSet(valid)
    }

    private fun normalizeLockType(raw: String?): String = when (raw?.uppercase()) {
        LOCK_TYPE_PATTERN -> LOCK_TYPE_PATTERN
        LOCK_TYPE_BIOMETRIC -> LOCK_TYPE_BIOMETRIC
        else -> LOCK_TYPE_PIN
    }

    private fun requirePrefs(): SharedPreferences =
        prefs ?: throw IllegalStateException("LockPrefs.init(context) no ha sido llamado")
}
