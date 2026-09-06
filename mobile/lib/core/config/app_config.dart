import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// ── Constants ──────────────────────────────────────────────────
const _kWsPath = '/ws';
const _kDefaultSrtPort = 8890;

// ── SharedPreferences keys ────────────────────────────────────
const _kReporterIdKey = 'reporter_id';
const _kDisplayNameKey = 'display_name';
const _kAuthSecretKey = 'auth_secret';
const _kSrtStreamKeyKey = 'srt_stream_key';
// Primary node
const _kPrimaryHostKey = 'primary_host';
const _kPrimaryPortKey = 'primary_port';
const _kPrimarySrtPortKey = 'primary_srt_port';
// Backup / secondary node
const _kBackupHostKey = 'backup_host';
const _kBackupPortKey = 'backup_port';
const _kBackupSrtPortKey = 'backup_srt_port';
const _kBackupEnabledKey = 'backup_enabled';

// ── Server Endpoint ───────────────────────────────────────────

/// Represents a single signaling + SRT ingest node.
class ServerEndpoint {
  final String host;
  final int signalingPort;
  final int srtPort;
  final bool isPrimary;

  const ServerEndpoint({
    required this.host,
    required this.signalingPort,
    this.srtPort = _kDefaultSrtPort,
    this.isPrimary = false,
  });

  /// WebSocket URL for the signaling connection.
  ///
  /// A interface aceita somente DNS. Todo hostname usa TLS e precisa apresentar
  /// um certificado valido para o dominio informado.
  /// Porta pública do cliente. 8080 é a porta do origin Termux e nunca deve
  /// ser acessada diretamente através da Internet; o Tunnel termina TLS/443.
  int get publicSignalingPort => signalingPort == 8080 ? 443 : signalingPort;

  Uri get wsUri => Uri(
        scheme: 'wss',
        host: host,
        port: publicSignalingPort,
        path: _kWsPath,
      );

  String get wsUrl => wsUri.toString();

  /// Base SRT ingest URL (stream key appended by SrtEngine).
  String get srtBaseUrl => 'srt://$host:$srtPort';

  String get label => isPrimary ? 'PRIMARY' : 'BACKUP';

  ServerEndpoint copyWith({
    String? host,
    int? signalingPort,
    int? srtPort,
    bool? isPrimary,
  }) =>
      ServerEndpoint(
        host: host ?? this.host,
        signalingPort: signalingPort ?? this.signalingPort,
        srtPort: srtPort ?? this.srtPort,
        isPrimary: isPrimary ?? this.isPrimary,
      );

  @override
  String toString() => '$label [$host:$publicSignalingPort | SRT:$srtPort]';
}

// ── App Configuration ─────────────────────────────────────────

/// Immutable snapshot of all app configuration.
class AppConfig {
  final String reporterId;
  final String displayName;
  final String authSecret;
  final String srtStreamKey;

  /// Primary node — always index 0 in [endpoints].
  final ServerEndpoint primary;

  /// Optional backup/secondary node.
  final ServerEndpoint? backup;

  /// Whether the backup node is enabled.
  final bool backupEnabled;

  const AppConfig({
    required this.reporterId,
    required this.displayName,
    required this.authSecret,
    required this.srtStreamKey,
    required this.primary,
    this.backup,
    this.backupEnabled = false,
  });

  /// Ordered list of endpoints: primary first, then backup (if enabled).
  List<ServerEndpoint> get endpoints => [
        primary,
        if (backup != null && backupEnabled) backup!,
      ];

  AppConfig copyWith({
    String? displayName,
    String? authSecret,
    String? srtStreamKey,
    ServerEndpoint? primary,
    ServerEndpoint? backup,
    bool? backupEnabled,
  }) =>
      AppConfig(
        reporterId: reporterId,
        displayName: displayName ?? this.displayName,
        authSecret: authSecret ?? this.authSecret,
        srtStreamKey: srtStreamKey ?? this.srtStreamKey,
        primary: primary ?? this.primary,
        backup: backup ?? this.backup,
        backupEnabled: backupEnabled ?? this.backupEnabled,
      );
}

// ── Riverpod Notifier ────────────────────────────────────────

class AppConfigNotifier extends AsyncNotifier<AppConfig> {
  @override
  Future<AppConfig> build() async {
    final prefs = await SharedPreferences.getInstance();

    // Stable reporter ID — generated once on first launch
    String reporterId = prefs.getString(_kReporterIdKey) ?? '';
    if (reporterId.isEmpty) {
      reporterId = const Uuid().v4();
      await prefs.setString(_kReporterIdKey, reporterId);
    }

    // Auto-generate SRT stream key from reporter ID prefix
    final srtStreamKey = prefs.getString(_kSrtStreamKeyKey) ??
        'reporter-${reporterId.substring(0, 8)}';

    final primary = ServerEndpoint(
      host: prefs.getString(_kPrimaryHostKey) ?? 'spsmart.syncplayer.com.br',
      signalingPort: _publicWsPort(prefs.getInt(_kPrimaryPortKey) ?? 443),
      srtPort: prefs.getInt(_kPrimarySrtPortKey) ?? _kDefaultSrtPort,
      isPrimary: true,
    );

    final backupHost = prefs.getString(_kBackupHostKey) ?? '';
    final ServerEndpoint? backup = backupHost.isNotEmpty
        ? ServerEndpoint(
            host: backupHost,
            signalingPort: _publicWsPort(prefs.getInt(_kBackupPortKey) ?? 443),
            srtPort: prefs.getInt(_kBackupSrtPortKey) ?? _kDefaultSrtPort,
            isPrimary: false,
          )
        : null;

    return AppConfig(
      reporterId: reporterId,
      displayName: prefs.getString(_kDisplayNameKey) ?? 'Reporter',
      authSecret: prefs.getString(_kAuthSecretKey) ?? '',
      srtStreamKey: srtStreamKey,
      primary: primary,
      backup: backup,
      backupEnabled: prefs.getBool(_kBackupEnabledKey) ?? false,
    );
  }

  Future<void> save(AppConfig config) async {
    final normalized = config.copyWith(
      primary: config.primary.copyWith(
        signalingPort: config.primary.publicSignalingPort,
      ),
      backup: config.backup?.copyWith(
        signalingPort: config.backup!.publicSignalingPort,
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDisplayNameKey, normalized.displayName);
    await prefs.setString(_kAuthSecretKey, normalized.authSecret);
    await prefs.setString(_kSrtStreamKeyKey, normalized.srtStreamKey);
    // Primary
    await prefs.setString(_kPrimaryHostKey, normalized.primary.host);
    await prefs.setInt(
      _kPrimaryPortKey,
      normalized.primary.publicSignalingPort,
    );
    await prefs.setInt(_kPrimarySrtPortKey, normalized.primary.srtPort);
    // Backup
    if (normalized.backup != null) {
      await prefs.setString(_kBackupHostKey, normalized.backup!.host);
      await prefs.setInt(
        _kBackupPortKey,
        normalized.backup!.publicSignalingPort,
      );
      await prefs.setInt(_kBackupSrtPortKey, normalized.backup!.srtPort);
    }
    await prefs.setBool(_kBackupEnabledKey, normalized.backupEnabled);
    state = AsyncValue.data(normalized);
  }
}

int _publicWsPort(int persistedPort) =>
    persistedPort == 8080 ? 443 : persistedPort;

final appConfigNotifierProvider =
    AsyncNotifierProvider<AppConfigNotifier, AppConfig>(AppConfigNotifier.new);
