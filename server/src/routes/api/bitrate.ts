// ============================================================
// SP Smart — Bitrate Control REST Routes
// ============================================================
// POST /api/bitrate/:reporterId      — issue bitrate command
// GET  /api/bitrate/presets          — list all presets
// ============================================================
import { Router } from 'express';
import { z } from 'zod';
import { bitrateService } from '../../services/BitrateService';
import { logger } from '../../utils/logger';

const router = Router();

const EncodingPresetSchema = z.enum([
  'LOW_LATENCY_SD',
  'LOW_LATENCY_HD',
  'QUALITY_HD',
  'QUALITY_FHD',
  'QUALITY_FHD_HIGH',
]);

const BitrateCommandSchema = z.object({
  preset: EncodingPresetSchema.optional(),
  targetBitrate: z.number().int().positive().optional(),
  maxBitrate: z.number().int().positive().optional(),
  minBitrate: z.number().int().positive().optional(),
});

/** POST /api/bitrate/:reporterId */
router.post('/:reporterId', (req, res) => {
  const { reporterId } = req.params;
  const parse = BitrateCommandSchema.safeParse(req.body);
  if (!parse.success) {
    res.status(400).json({ error: 'Invalid body', details: parse.error.flatten() });
    return;
  }

  const ok = bitrateService.sendBitrateCommand(reporterId, parse.data);
  if (!ok) {
    res.status(404).json({ error: 'Reporter not found or not connected' });
    return;
  }

  logger.info({ reporterId, ...parse.data }, '[REST] Bitrate command sent');
  res.json({ success: true, reporterId, command: parse.data });
});

/** GET /api/bitrate/presets */
router.get('/presets', (_req, res) => {
  res.json(bitrateService.getAllPresets());
});

export { router as bitrateRouter };
