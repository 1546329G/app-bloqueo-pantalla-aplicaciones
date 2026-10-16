# App Locker — Bloqueo de aplicaciones 100% local (Android)

App nativa **Android** escrita en **Flutter/Dart + Kotlin** (API 29+) que bloquea
cualquier aplicación instalada mediante **PIN numérico, Patrón 3×3 o Biometría**.
La detección de la app en primer plano se hace en tiempo real con un
`AccessibilityService` y la pantalla de bloqueo es una `FlutterFragmentActivity`
nativa que se monta sobre la app víctima con latencia de milisegundos.

> **Privacidad total:** sin internet, sin servidores, sin telemetría. Las
> credenciales se cifran en reposo con **Keystore RSA-OAEP + AES-GCM** vía
> `flutter_secure_storage`. La app **no** inspecciona el contenido de las
> ventanas (`canRetrieveWindowContent="false"`); solo lee el `packageName` que
> el sistema entrega en cada `TYPE_WINDOW_STATE_CHANGED`.

---

## ✨ Características

- **Tres tipos de bloqueo por app:** PIN numérico (teclado propio con shake en error), Patrón 3×3 (9 puntos, reusando `PatternPad` con feedback verde/rojo) o Biometría (`local_auth` con fallback a PIN del dispositivo).
- **Detección en tiempo real:** `AccessibilityService` escucha `TYPE_WINDOW_STATE_CHANGED` (push del sistema, **sin polling**, consumo de batería ≈ 0 en reposo).
- **Pantalla de bloqueo en milisegundos:** `LockScreenActivity` es una `FlutterFragmentActivity` con `launchMode="singleInstance"`, `FLAG_ACTIVITY_CLEAR_TASK` (trae la tarea al frente sobre la app bloqueada), `FLAG_SECURE` (sin screenshots/recording), y `excludeFromRecents`.
- **Anti-flash:** ruta inicial `/lock/standby` (fondo opaco) antes de navegar a `/lock/pin|pattern|biometric`, de modo que la app bloqueada nunca se ve aunque sea un frame.
- **5 intentos → bloqueo 30 s** con cuenta regresiva (PIN y patrón), con `UnlockAttemptGuard` estático para que el contador sobreviva a la recreación de la pantalla.
- **"Salir al Inicio"** en la pantalla de bloqueo: `LockOverlayManager.goToHome()` lanza el launcher y limpia la sesión, de modo que al volver a abrir la app se pide la clave de nuevo.
- **Re-bloqueo automático** al cambiar de app y al apagar la pantalla (`onScreenOff`).
- **Sesión de bloqueo con `sessionId`** incremental: garantiza que cada bloqueo arranca con estado limpio aunque la app y el método coincidan con el anterior (routes con `ValueKey('lock-<type>-<session>')`).
- **Persistencia extrema:** `KeepAliveForegroundService` con `START_STICKY` + `foregroundServiceType="specialUse"` (exento del límite de 10 s en API 34+), boot receiver (`BOOT_COMPLETED` + `QUICKBOOT_POWERON` + `MY_PACKAGE_REPLACED`) y watchdog cada 15 min.
- **Ventana segura:** `FLAG_SECURE`, `excludeFromRecents`, `PopScope(canPop:false)`, `onBackPressed` vacío.
- **Haptics** diferenciados: impacto ligero en acierto, pesado en error.
- **0 errores en `flutter analyze`** (verificado).

---

## 🏗️ Arquitectura

```
┌────────────────────────────────────────────────────────────────┐
│  KOTLIN (Android)                                              │
│                                                                │
│  AppLockAccessibilityService ── onAccessibilityEvent           │
│      │                              (TYPE_WINDOW_STATE_CHANGED) │
│      ▼                                                         │
│  LockOverlayManager.onForegroundPackageChanged()               │
│      │   • LockPrefs.isBlocked(pkg)  ← O(1) Set en memoria     │
│      │   • si bloqueada → showLock():                            │
│      │       startActivity(LockScreenActivity)                  │
│      │       flags: NEW_TASK | CLEAR_TASK | EXCLUDE_FROM_RECENTS│
│      ▼                                                         │
│  LockScreenActivity (FlutterFragmentActivity)                   │
│      │   • getInitialRoute() = "/lock/standby"                  │
│      │   • pushLockStateToDart() (MethodChannel → Dart)         │
│      │   • FLAG_SECURE + setFinishOnTouchOutside(false)         │
│      ▼                                                         │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ FLUTTER (Dart)                                          │   │
│  │                                                         │   │
│  │ main() → detecta isLockEngine → ruta inicial             │   │
│  │   "/lock/standby" → NativeBridge → /lock/pin|pattern|…  │   │
│  │                                                         │   │
│  │ LockScreenShell: PopScope(canPop:false), fondo oscuro, │   │
│  │   "Salir al Inicio", UnlockAttemptGuard compartido.    │   │
│  │                                                         │   │
│  │ PinLockScreen / PatternLockScreen / BiometricLockScreen │   │
│  │   verifican contra flutter_secure_storage (RSA-OAEP).  │   │
│  │   Éxito → NativeBridge.unlockCurrentApp(pkg)            │   │
│  │          → LockOverlayManager.submitUnlock()             │   │
│  └────────────────────────────────────────────────────────┘    │
│                                                                │
│  AppLockerBridge (MethodChannel + EventChannel)                │
│      ↕ estado nativo ↔ Dart                                    │
│                                                                │
│  KeepAliveForegroundService (FGS specialUse, START_STICKY)     │
│  BootReceiver (BOOT_COMPLETED, QUICKBOOT_POWERON, …)            │
└────────────────────────────────────────────────────────────────┘
```

### Canales Dart ↔ Kotlin

| Canal | Dirección | Métodos principales |
|---|---|---|
| `com.example.app_locker/methods` | Dart → Kotlin | `getStatus`, `requestAccessibilityPermission`, `requestBatteryExclusion`, `syncLockedApps`, `unlockCurrentApp`, `goToHome`, … |
| `com.example.app_locker/lock_events` | Kotlin → Dart | `onShowLockScreen`, `onLockDismissed` |
| `com.example.app_locker/events` | Kotlin → Dart | `bridgeError`, `lockShown`, `unlocked`, … |

---

## 📁 Estructura del proyecto

```
lib/
├── main.dart                              ← entrypoint dual (main + lock engine)
├── core/
│   ├── bridges/native_bridge.dart         ← MethodChannel/EventChannel
│   ├── models/locked_app_model.dart
│   ├── routes/app_routes.dart             ← GoRouter + rutas de bloqueo
│   ├── security/unlock_attempt_guard.dart ← contador compartido (estático)
│   └── storage/local_storage_service.dart ← SharedPreferences + flutter_secure_storage
└── ui/
    ├── screens/
    │   ├── permissions_screen.dart        ← pide accesibilidad, batería, notificaciones
    │   ├── home_screen.dart               ← lista de apps instaladas
    │   ├── app_config_screen.dart         ← configura PIN/patrón/huella por app
    │   └── locks/
    │       ├── pin_lock_screen.dart
    │       ├── pattern_lock_screen.dart
    │       └── biometric_lock_screen.dart
    └── widgets/
        ├── app_list_tile.dart
        ├── lock_screen_shell.dart         ← PopScope + fondo oscuro + "Salir al Inicio"
        └── pattern_pad.dart               ← pad 3×3 reutilizable con holdLastStroke

android/app/src/main/
├── AndroidManifest.xml                    ← servicios, permisos, tema, v2 embedding
├── kotlin/com/example/app_locker/
│   ├── MainActivity.kt
│   ├── LockScreenActivity.kt              ← FlutterFragmentActivity + FLAG_SECURE
│   ├── bridge/AppLockerBridge.kt          ← MethodChannel + EventChannel
│   ├── receivers/BootReceiver.kt
│   ├── services/
│   │   ├── AppLockAccessibilityService.kt
│   │   └── KeepAliveForegroundService.kt
│   └── utils/
│       ├── LockOverlayManager.kt          ← máquina de estados de bloqueo
│       └── LockPrefs.kt                   ← cache O(1) de apps bloqueadas
└── res/
    ├── values/styles.xml                  ← LockScreenTheme opaco
    ├── values/colors.xml
    ├── xml/accessibility_service_config.xml
    └── …
```

---

## 🛠️ Stack técnico

| Capa | Tecnología | Versión |
|---|---|---|
| Lenguaje | Dart | ^3.12.0 |
| Lenguaje | Kotlin | 2.4.0 |
| Framework | Flutter | 3.47.x stable |
| Build | Android Gradle Plugin | 9.1.0 |
| Build | Gradle | 9.3.1 |
| Build | JDK | 17+ (probado con JBR 21) |
| Mín. Android | API 29 (Android 10) | — |
| Target Android | API 36 | — |
| Navegación | go_router | ^18.1.0 |
| Persistencia | shared_preferences | ^2.5.6 |
| Credenciales cifradas | flutter_secure_storage | ^11.2.0 |
| Biometría | local_auth | ^3.0.2 |
| Hashing | crypto (SHA-256) | ^3.0.7 |

---

## 🚀 Compilar e instalar

### Requisitos

- Flutter **3.47.x** stable (`~/flutter` o el de tu sistema)
- **JDK 17+** (probado con el JBR que trae Android Studio en `/opt/android-studio/jbr`)
- **Android SDK** con platforms `android-36` y `build-tools 36.x`
- **Dispositivo Android 10+ (API 29)** con depuración USB activada

### Build

```bash
# Variables de entorno necesarias
export JAVA_HOME=/opt/android-studio/jbr   # o tu JDK 17+
export PATH=$JAVA_HOME/bin:$PATH

# Build APK debug
flutter build apk --debug
# → build/app/outputs/flutter-apk/app-debug.apk
```

### Instalar en el celular

```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

> **Importante en MIUI/HyperOS (Xiaomi):** la primera instalación por `adb`
> puede fallar con `INSTALL_FAILED_USER_RESTRICTED`. Soluciones:
> 1. Instalar manualmente desde **Archivos → Descargas → AppLocker-debug.apk**
>    (autorizar "instalar apps desconocidas" para Archivos).
> 2. O activar **"Instalar vía USB"** en Opciones de desarrollador (requiere
>    cuenta Xiaomi + SIM + internet en algunas versiones de HyperOS).

### Configuración en el celular (una sola vez)

1. Abre **App Locker**.
2. Activa los permisos (la app te guía):
   - **Accesibilidad** → App Locker → Activar
   - **Notificaciones** → Permitir
   - **Batería** → Sin restricciones
3. Si Android 13+ te bloquea con "Ajustes restringidos":
   **Ajustes → Aplicaciones → App Locker → ⋮ → Permitir ajustes restringidos**.
4. En la pantalla principal, toca una app → elige **PIN, Patrón o Huella** → **Guardar**.
5. Sal de App Locker (HOME) → abre la app bloqueada → debería aparecer la pantalla de bloqueo.

---

## 🧪 Cómo probar el bloqueo

1. **Bloqueo inmediato:** abre una app que hayas configurado → la pantalla de bloqueo aparece al instante.
2. **5 intentos fallidos:** ingresa mal el PIN/patrón 5 veces → **bloqueo 30 s** con cuenta regresiva y haptics pesados.
3. **"Salir al Inicio":** toca el botón → te lleva al launcher; al volver a abrir la app se pide la clave de nuevo.
4. **Cambio de app:** estando en una app bloqueada, presiona HOME y abre otra app distinta → la siguiente app bloqueada también pide clave (no se "hereda" el desbloqueo).
5. **Apagar pantalla:** estando en una app desbloqueada, apaga la pantalla y vuelve a abrirla → pide clave de nuevo (`onScreenOff` invalida la sesión).
6. **Biometría:** si elegiste huella, al abrir la app se muestra la pantalla de biometría del sistema; al autenticarte correctamente, se desbloquea.

---

## 🔒 Privacidad y permisos

| Permiso | Para qué se usa |
|---|---|
| `BIND_ACCESSIBILITY_SERVICE` | Recibir `TYPE_WINDOW_STATE_CHANGED` para detectar la app en primer plano. **No** inspecciona el contenido de las ventanas (`canRetrieveWindowContent="false"`). |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SPECIAL_USE` | Mantener el servicio vivo para que el `AccessibilityService` no sea matado por el sistema. |
| `SYSTEM_ALERT_WINDOW` | Declarado por compatibilidad (la app no usa overlays en esta versión). |
| `RECEIVE_BOOT_COMPLETED` | Re-arrancar el servicio tras un reinicio. |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Solicitar al usuario que excluya la app de Doze. |
| `POST_NOTIFICATIONS` | Notificación del foreground service (API 33+). |
| `USE_BIOMETRIC` | Autenticación biométrica. |
| `QUERY_ALL_PACKAGES` | Listar todas las apps instaladas. Si publicas en Play Store, reemplázalo por un `<queries>` que solo incluya apps con `LAUNCHER` intent. |

---

## 🧰 Solución de problemas

### "La pantalla de bloqueo no aparece"

1. Verifica que **Accesibilidad → App Locker** esté activado (el toggle puede quedar "encendido" pero el binder muerto tras un `install -r`; desactívalo y vuelve a activarlo).
2. Verifica que la app esté en la lista de apps bloqueadas dentro de **App Locker**.
3. Revisa `adb logcat -s AppLocker` mientras abres la app bloqueada — deberías ver:
   ```
   WSC event: pkg=<paquete>
   fg=<paquete> ... blocked=true mustLock=true
   showLock: ... startActivity OK
   LockScreenActivity onCreate ...
   LockScreenActivity onResume
   ```

### "El bloqueo aparece pero la pantalla está en negro"

Esto pasaba en una versión anterior con el tema `Theme.Translucent`. El tema actual (`@style/LockScreenTheme`) es **opaco** con `@color/lock_screen_background` (#0B1020). Si lo modificas, asegúrate de mantener el fondo opaco para evitar que se vea la app bloqueada "a través" del lock.

### "El bloqueo no se trae al frente (queda en background)"

El manifest usa `launchMode="singleInstance"` **sin** `taskAffinity` personalizado
(la afinidad por defecto es el nombre del paquete) y Kotlin lanza la actividad
con `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TASK`. Esto garantiza que la
tarea de la pantalla de bloqueo se coloque **encima** de la app bloqueada.

---

## 📜 Licencia

Proyecto privado. Todos los derechos reservados.
