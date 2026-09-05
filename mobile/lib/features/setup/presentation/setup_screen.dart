import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sp_smart/core/config/app_config.dart';
import 'package:sp_smart/core/router/app_router.dart';

/// Setup Screen
/// Configura: servidor primário, servidor backup (opcional) e identidade.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _formKey = GlobalKey<FormState>();

  // Controllers — inicializados em build() com os dados atuais
  late TextEditingController _nameCtrl;
  late TextEditingController _secretCtrl;
  // Primary
  late TextEditingController _primaryHostCtrl;
  late TextEditingController _primaryPortCtrl;
  late TextEditingController _primarySrtPortCtrl;
  // Backup
  late TextEditingController _backupHostCtrl;
  late TextEditingController _backupPortCtrl;
  late TextEditingController _backupSrtPortCtrl;

  bool _backupEnabled = false;
  bool _controllersInitialized = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _secretCtrl.dispose();
    _primaryHostCtrl.dispose();
    _primaryPortCtrl.dispose();
    _primarySrtPortCtrl.dispose();
    _backupHostCtrl.dispose();
    _backupPortCtrl.dispose();
    _backupSrtPortCtrl.dispose();
    super.dispose();
  }

  void _initControllers(AppConfig config) {
    if (_controllersInitialized) return;
    _nameCtrl          = TextEditingController(text: config.displayName);
    _secretCtrl        = TextEditingController(text: config.authSecret);
    _primaryHostCtrl   = TextEditingController(text: config.primary.host);
    _primaryPortCtrl   = TextEditingController(text: config.primary.signalingPort.toString());
    _primarySrtPortCtrl = TextEditingController(text: config.primary.srtPort.toString());
    _backupHostCtrl    = TextEditingController(text: config.backup?.host ?? '');
    _backupPortCtrl    = TextEditingController(text: (config.backup?.signalingPort ?? 3000).toString());
    _backupSrtPortCtrl = TextEditingController(text: (config.backup?.srtPort ?? 8890).toString());
    _backupEnabled     = config.backupEnabled;
    _controllersInitialized = true;
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(appConfigNotifierProvider);

    return configAsync.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('Erro de config: $e'))),
      data: (config) {
        _initControllers(config);
        return Scaffold(
          appBar: AppBar(title: const Text('SP Smart — Configuração')),
          body: SafeArea(
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  // ── Identidade ─────────────────────────────
                  _SectionLabel('Identidade do Repórter'),
                  const SizedBox(height: 4),
                  SelectableText(
                    'ID: ${config.reporterId}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey,
                          fontFamily: 'monospace',
                        ),
                  ),
                  const SizedBox(height: 12),
                  _field(_nameCtrl,   'Nome do Repórter',   required: true),
                  const SizedBox(height: 8),
                  _field(_secretCtrl, 'Auth Secret',        obscure: true,
                      validator: (v) => (v == null || v.length < 8) ? 'Mínimo 8 caracteres' : null),

                  const SizedBox(height: 28),

                  // ── Servidor Principal ─────────────────────
                  _SectionLabel('Servidor Principal (Primary)'),
                  const SizedBox(height: 12),
                  _ServerFields(
                    hostCtrl:   _primaryHostCtrl,
                    portCtrl:   _primaryPortCtrl,
                    srtPortCtrl: _primarySrtPortCtrl,
                  ),

                  const SizedBox(height: 28),

                  // ── Servidor Backup ────────────────────────
                  Row(
                    children: [
                      _SectionLabel('Servidor Backup (Secondary)'),
                      const Spacer(),
                      Switch(
                        value: _backupEnabled,
                        onChanged: (v) => setState(() => _backupEnabled = v),
                      ),
                    ],
                  ),

                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: _backupEnabled
                        ? Column(
                            key: const ValueKey('backup_fields'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              _InfoBanner(
                                '⚡ Failover automático: se o Principal ficar '
                                'indisponível, o app comuta para este servidor '
                                'em até ${_kHeartbeatDisplaySec}s.',
                              ),
                              const SizedBox(height: 12),
                              _ServerFields(
                                hostCtrl:    _backupHostCtrl,
                                portCtrl:    _backupPortCtrl,
                                srtPortCtrl: _backupSrtPortCtrl,
                                hostHint:    'ex: 192.168.1.110 ou 10.0.0.5',
                                required:    _backupEnabled,
                              ),
                            ],
                          )
                        : const SizedBox.shrink(key: ValueKey('backup_hidden')),
                  ),

                  const SizedBox(height: 40),

                  FilledButton(
                    onPressed: _onSave,
                    child: const Text('Salvar e Conectar'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Salvar ────────────────────────────────────────────────
  Future<void> _onSave() async {
    if (!_formKey.currentState!.validate()) return;

    final config = ref.read(appConfigNotifierProvider).valueOrNull;
    if (config == null) return;

    final updated = config.copyWith(
      displayName: _nameCtrl.text.trim(),
      authSecret:  _secretCtrl.text.trim(),
      primary: ServerEndpoint(
        host:           _primaryHostCtrl.text.trim(),
        signalingPort:  int.tryParse(_primaryPortCtrl.text.trim()) ?? 3000,
        srtPort:        int.tryParse(_primarySrtPortCtrl.text.trim()) ?? 8890,
        isPrimary:      true,
      ),
      backup: _backupEnabled && _backupHostCtrl.text.trim().isNotEmpty
          ? ServerEndpoint(
              host:          _backupHostCtrl.text.trim(),
              signalingPort: int.tryParse(_backupPortCtrl.text.trim()) ?? 3000,
              srtPort:       int.tryParse(_backupSrtPortCtrl.text.trim()) ?? 8890,
              isPrimary:     false,
            )
          : null,
      backupEnabled: _backupEnabled,
    );

    await ref.read(appConfigNotifierProvider.notifier).save(updated);
    if (mounted) context.go(Routes.broadcast);
  }

  // ── Helpers ───────────────────────────────────────────────
  Widget _field(
    TextEditingController ctrl,
    String label, {
    bool required = false,
    bool obscure  = false,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: ctrl,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      validator: validator ??
          (required
              ? (v) => (v == null || v.isEmpty) ? 'Obrigatório' : null
              : null),
    );
  }
}

// ── Display constant ─────────────────────────────────────────
// Sincronizado com _kHeartbeatTimeoutSec em signaling_service.dart
const _kHeartbeatDisplaySec = 12;

// ── Sub-widgets ───────────────────────────────────────────────

class _ServerFields extends StatelessWidget {
  const _ServerFields({
    required this.hostCtrl,
    required this.portCtrl,
    required this.srtPortCtrl,
    this.hostHint = 'ex: 192.168.1.100',
    this.required = true,
  });

  final TextEditingController hostCtrl;
  final TextEditingController portCtrl;
  final TextEditingController srtPortCtrl;
  final String hostHint;
  final bool required;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextFormField(
          controller: hostCtrl,
          decoration: InputDecoration(
            labelText: 'IP / Hostname',
            hintText: hostHint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          keyboardType: TextInputType.url,
          validator: required
              ? (v) => (v == null || v.isEmpty) ? 'Obrigatório' : null
              : null,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: portCtrl,
                decoration: const InputDecoration(
                  labelText: 'Porta WS',
                  hintText: '3000',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  if (n == null || n < 1 || n > 65535) return 'Inválida';
                  return null;
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: srtPortCtrl,
                decoration: const InputDecoration(
                  labelText: 'Porta SRT',
                  hintText: '8890',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  if (n == null || n < 1 || n > 65535) return 'Inválida';
                  return null;
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
            ),
      );
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer.withAlpha(60),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withAlpha(80),
          ),
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
              ),
        ),
      );
}
