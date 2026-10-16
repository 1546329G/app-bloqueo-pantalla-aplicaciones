import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/bridges/native_bridge.dart';
import '../../core/models/locked_app_model.dart';
import '../../core/routes/app_routes.dart';
import '../../core/storage/local_storage_service.dart';
import '../widgets/app_list_tile.dart';

/// Color del indicador "servicio activo".
const Color _kOnline = Color(0xFF66BB6A);

/// Filtros rápidos de la lista.
enum _AppsFilter { all, locked }

/// `/home`
///
/// Pantalla principal: lista las aplicaciones instaladas (obtenidas de Kotlin
/// con `NativeBridge.getInstalledApps()`, que ya excluye esta app y solo
/// devuelve las que tienen actividad launcher). Cruza cada app con el mapa de
/// [LocalStorageService] para mostrar su estado y método de bloqueo.
///
/// Al volver de `/config-app` refresca el estado y empuja a Kotlin el mapa
/// actualizado (`syncLockedApps`) para que el AccessibilityService lo aplique
/// al instante.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  final Map<String, Uint8List> _icons = <String, Uint8List>{};

  List<InstalledAppInfo> _apps = const <InstalledAppInfo>[];
  Map<String, LockedAppModel> _locks = const <String, LockedAppModel>{};
  StreamSubscription<Map<String, dynamic>>? _eventsSubscription;

  _AppsFilter _filter = _AppsFilter.all;
  bool _showSystemApps = true;
  bool _loading = true;
  String _query = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onQueryChanged);
    _eventsSubscription = NativeBridge.instance.events.listen(_onNativeEvent);
    _loadApps();
  }

  @override
  void dispose() {
    _eventsSubscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Carga de datos
  // ------------------------------------------------------------------

  void _onQueryChanged() {
    final String query = _searchController.text.trim().toLowerCase();
    if (query == _query) return;
    setState(() => _query = query);
  }

  /// Kotlin avisa cuando el mapa cambió (p. ej. una app fue desinstalada).
  void _onNativeEvent(Map<String, dynamic> event) {
    final Object? type = event['type'];
    if (type == 'locksChanged' || type == 'onLockDismissed') {
      _refreshLockState();
    }
  }

  Future<void> _loadApps({bool showSpinner = true}) async {
    if (mounted && showSpinner && !_loading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final List<InstalledAppInfo> apps =
          await NativeBridge.instance.getInstalledApps();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _loading = false;
        _error = null;
      });
      _refreshLockState();
      // Los iconos se cargan después de pintar la lista, de uno en uno,
      // para que la pantalla aparezca al instante y se complete sola.
      unawaited(_loadIcons(apps));
    } catch (_) {
      // El canal nativo puede no responder en un reinicio del proceso.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo obtener la lista de aplicaciones instaladas.';
      });
    }
  }

  Future<void> _loadIcons(List<InstalledAppInfo> apps) async {
    for (final InstalledAppInfo app in apps) {
      if (_icons.containsKey(app.packageName)) continue;
      final Uint8List? bytes =
          await NativeBridge.instance.getAppIcon(app.packageName);
      if (!mounted) return;
      if (bytes != null) {
        setState(() => _icons[app.packageName] = bytes);
      }
    }
  }

  /// Relee el mapa local y lo empuja a Kotlin (fuente de verdad: Dart).
  void _refreshLockState() {
    final Map<String, LockedAppModel> locks = <String, LockedAppModel>{
      for (final LockedAppModel app
          in LocalStorageService.instance.getConfiguredApps())
        app.packageName: app,
    };
    if (!mounted) return;
    setState(() => _locks = locks);
    unawaited(LocalStorageService.instance.syncLockedApps());
  }

  // ------------------------------------------------------------------
  // Interacción
  // ------------------------------------------------------------------

  /// Abre `/config-app` y, al volver, refresca lista y sincronización.
  Future<void> _openConfig(InstalledAppInfo app) async {
    final LockedAppModel? current = _locks[app.packageName];
    await context.push<void>(
      AppRoutes.configApp,
      extra: LockedAppModel(
        packageName: app.packageName,
        appName: app.appName,
        isLocked: current != null,
        lockType: current?.lockType ?? LockType.none,
      ),
    );
    if (!mounted) return;
    _refreshLockState();
  }

  /// Activar el switch abre la configuración (falta elegir método y clave).
  /// Desactivarlo retira el bloqueo inmediatamente.
  Future<void> _toggleApp(InstalledAppInfo app, bool value) async {
    if (value) {
      await _openConfig(app);
      return;
    }
    final String label = app.appName.isEmpty ? app.packageName : app.appName;
    await LocalStorageService.instance.removeAppLock(app.packageName);
    if (!mounted) return;
    _refreshLockState();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label ya no está bloqueada.')),
    );
  }

  // ------------------------------------------------------------------
  // Lista visible
  // ------------------------------------------------------------------

  List<InstalledAppInfo> get _visibleApps {
    return _apps
        .where((InstalledAppInfo app) {
          if (!_showSystemApps && app.isSystem) return false;
          if (_filter == _AppsFilter.locked &&
              !_locks.containsKey(app.packageName)) {
            return false;
          }
          if (_query.isEmpty) return true;
          return app.appName.toLowerCase().contains(_query) ||
              app.packageName.toLowerCase().contains(_query);
        })
        .toList(growable: false);
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int lockedCount = _locks.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Aplicaciones'),
        actions: <Widget>[
          IconButton(
            tooltip: _showSystemApps
                ? 'Ocultar apps del sistema'
                : 'Mostrar apps del sistema',
            onPressed: () =>
                setState(() => _showSystemApps = !_showSystemApps),
            icon: Icon(
              _showSystemApps
                  ? Icons.filter_alt
                  : Icons.filter_alt_off_outlined,
            ),
          ),
          const _ServiceStatusButton(),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Buscar aplicaciones…',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Limpiar',
                          onPressed: () => _searchController.clear(),
                          icon: const Icon(Icons.clear),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  isDense: true,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<_AppsFilter>(
                showSelectedIcon: false,
                segments: <ButtonSegment<_AppsFilter>>[
                  const ButtonSegment<_AppsFilter>(
                    value: _AppsFilter.all,
                    label: Text('Todas'),
                  ),
                  ButtonSegment<_AppsFilter>(
                    value: _AppsFilter.locked,
                    label: Text('Bloqueadas ($lockedCount)'),
                  ),
                ],
                selected: <_AppsFilter>{_filter},
                onSelectionChanged: (Set<_AppsFilter> selection) =>
                    setState(() => _filter = selection.first),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(child: _buildBody(scheme)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Cargando aplicaciones…'),
          ],
        ),
      );
    }

    final String? error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, size: 44, color: scheme.error),
              const SizedBox(height: 12),
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: () => _loadApps(),
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    final List<InstalledAppInfo> visible = _visibleApps;
    if (visible.isEmpty) {
      return _buildEmptyState(scheme);
    }

    return RefreshIndicator(
      onRefresh: () => _loadApps(showSpinner: false),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        itemCount: visible.length,
        separatorBuilder: (BuildContext context, int index) => Divider(
          height: 1,
          indent: 78,
          color: scheme.outlineVariant.withValues(alpha: 0.4),
        ),
        itemBuilder: (BuildContext context, int index) {
          final InstalledAppInfo app = visible[index];
          final LockedAppModel? lock = _locks[app.packageName];
          return AppListTile(
            key: ValueKey<String>(app.packageName),
            appName: app.appName,
            packageName: app.packageName,
            iconBytes: _icons[app.packageName],
            isLocked: lock != null,
            lockType: lock?.lockType ?? LockType.none,
            onTap: () => _openConfig(app),
            onToggle: (bool value) => _toggleApp(app, value),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme scheme) {
    final IconData icon;
    final String message;
    if (_query.isNotEmpty) {
      icon = Icons.search_off;
      message = 'Sin resultados para "$_query".';
    } else if (_filter == _AppsFilter.locked) {
      icon = Icons.lock_open_outlined;
      message = 'Todavía no bloqueas ninguna app.\n'
          'Toca una aplicación y activa su interruptor.';
    } else {
      icon = Icons.apps_outlined;
      message = _showSystemApps
          ? 'No se encontraron aplicaciones instaladas.'
          : 'No hay apps de usuario visibles.\n'
              'Prueba a mostrar las apps del sistema con el filtro del superior.';
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Indicador/atajo del estado del servicio: verde si los permisos base están
/// concedidos; al pulsarlo se abre `/permissions` para verificarlos.
class _ServiceStatusButton extends StatelessWidget {
  const _ServiceStatusButton();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<NativeStatus>(
      valueListenable: NativeBridge.instance.status,
      builder: (BuildContext context, NativeStatus status, Widget? child) {
        final bool ok = status.hasCorePermissions;
        return IconButton(
          tooltip: ok
              ? 'Servicio activo · Ver permisos'
              : 'Servicio inactivo · Revisa los permisos',
          onPressed: () => context.push(AppRoutes.permissions),
          icon: Icon(
            ok ? Icons.verified_user : Icons.gpp_maybe,
            color: ok ? _kOnline : scheme.error,
          ),
        );
      },
    );
  }
}
