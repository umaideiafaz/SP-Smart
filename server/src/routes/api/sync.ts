// ============================================================
// SP Smart — State Sync Route  /api/sync
// ============================================================
// Este endpoint é chamado pelo script do Controle Mestre (vMix)
// SIMULTANEAMENTE nos dois servidores (Principal e Secundário).
//
// O script do vMix envia um único POST para cada servidor:
//   curl -X POST http://<server>/api/sync \
//     -H "Content-Type: application/json" \
//     -d '{"state":"PGM","source":"vmix","reporterId":"all"}'
//
// Cada servidor recebe o estado e repassa IMEDIATAMENTE
// a todos os repórteres WebSocket conectados a ele.
// ============================================================
import { Router } from 'express';
import { z } from 'zod';
import { tallyService } from '../../services/TallyService';
import { bitrateService } from '../../services/BitrateService';
import { reporterRegistry } from '../../services/ReporterRegistry';
import { logger } from '../../utils/logger';

const router = Router();

// ── Schema de validação ──────────────────────────────────────
const SyncBodySchema = z.object({
  /**
   * 'all' → broadcast para todos os repórteres conectados.
   * Um reporterId específico → apenas aquele repórter.
   */
  reporterId: z.string().default('all'),

  /** Estado Tally a ser aplicado. */
  state: z.enum(['PGM', 'PVW', 'IDLE']).optional(),

  /**
   * Comando de bitrate opcional (pode vir junto com o tally).
   * Útil para o vMix reduzir bitrate quando o repórter entra em PVW.
   */
  bitrateCommand: z
    .object({
      preset: z
        .enum(['LOW_LATENCY_SD', 'LOW_LATENCY_HD', 'QUALITY_HD', 'QUALITY_FHD', 'QUALITY_FHD_HIGH'])
        .optional(),
      targetBitrate: z.number().int().positive().optional(),
    })
    .optional(),

  /**
   * Identificação da origem do comando (para rastreabilidade no log).
   * ex: "vmix", "atem", "manual", "obs"
   */
  source: z.string().default('unknown'),

  /** Timestamp Unix ms do momento em que o evento ocorreu na origem. */
  originTimestamp: z.number().int().positive().optional(),
});

export type SyncBody = z.infer<typeof SyncBodySchema>;

// ─────────────────────────────────────────────────────────────

/**
 * POST /api/sync
 *
 * Recebe estado unificado do Controle Mestre e distribui
 * para todos os repórteres conectados a este servidor.
 *
 * Projetado para ser chamado de AMBOS os servidores
 * (Principal e Secundário) simultaneamente pelo script vMix.
 */
router.post('/', (req, res) => {
  const parse = SyncBodySchema.safeParse(req.body);
  if (!parse.success) {
    res.status(400).json({ error: 'Invalid body', details: parse.error.flatten() });
    return;
  }

  const { reporterId, state, bitrateCommand, source, originTimestamp } = parse.data;
  const serverReceiveAt = Date.now();
  const latencyMs = originTimestamp ? serverReceiveAt - originTimestamp : null;

  logger.info(
    { source, reporterId, state, bitrateCommand, latencyMs },
    '[SYNC] Received state sync'
  );

  const results: {
    tally: { ok: boolean; affected: number };
    bitrate: { ok: boolean; affected: number };
  } = {
    tally:   { ok: true, affected: 0 },
    bitrate: { ok: true, affected: 0 },
  };

  // ── 1. Aplicar Tally ──────────────────────────────────────
  if (state) {
    if (reporterId === 'all') {
      tallyService.broadcastTally(state);
      results.tally.affected = reporterRegistry.count();
    } else {
      const ok = tallyService.setTally(reporterId, state);
      results.tally.ok = ok;
      results.tally.affected = ok ? 1 : 0;
    }
  }

  // ── 2. Aplicar Bitrate (opcional) ─────────────────────────
  if (bitrateCommand) {
    const targets = reporterId === 'all'
      ? reporterRegistry.getAll().map((s) => s.reporterId)
      : [reporterId];

    for (const id of targets) {
      const ok = bitrateService.sendBitrateCommand(id, bitrateCommand);
      if (ok) results.bitrate.affected++;
    }
    results.bitrate.ok = results.bitrate.affected > 0;
  }

  res.json({
    success: true,
    serverReceiveAt,
    latencyMs,
    connectedReporters: reporterRegistry.count(),
    results,
  });
});

/**
 * GET /api/sync/status
 *
 * Retorna o estado atual de todos os repórteres.
 * Útil para o Controle Mestre verificar o estado antes de enviar um sync.
 */
router.get('/status', (_req, res) => {
  const reporters = reporterRegistry.getAll().map((s) => ({
    reporterId:     s.reporterId,
    displayName:    s.displayName,
    tallyState:     s.tallyState,
    encodingPreset: s.encodingPreset,
    state:          s.state,
    lastSeenAgo:    Date.now() - s.lastSeenAt,
  }));

  res.json({
    serverTime:         Date.now(),
    connectedReporters: reporters.length,
    reporters,
  });
});

export { router as syncRouter };
