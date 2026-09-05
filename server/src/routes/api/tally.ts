// ============================================================
// SP Smart — Tally REST Routes
// ============================================================
// POST /api/tally/:reporterId       — set tally for one reporter
// POST /api/tally/broadcast         — set tally for all reporters
// GET  /api/tally/:reporterId       — get current tally state
// ============================================================
import { Router } from 'express';
import { z } from 'zod';
import { tallyService } from '../../services/TallyService';
import { reporterRegistry } from '../../services/ReporterRegistry';
import { logger } from '../../utils/logger';

const router = Router();

const TallyBodySchema = z.object({
  state: z.enum(['PGM', 'PVW', 'IDLE']),
  color: z
    .object({
      r: z.number().int().min(0).max(255),
      g: z.number().int().min(0).max(255),
      b: z.number().int().min(0).max(255),
    })
    .optional(),
});

/** POST /api/tally/:reporterId */
router.post('/:reporterId', (req, res) => {
  const { reporterId } = req.params;
  const parse = TallyBodySchema.safeParse(req.body);
  if (!parse.success) {
    res.status(400).json({ error: 'Invalid body', details: parse.error.flatten() });
    return;
  }

  const { state } = parse.data;
  const ok = tallyService.setTally(reporterId, state);

  if (!ok) {
    res.status(404).json({ error: 'Reporter not found or not connected' });
    return;
  }

  logger.info({ reporterId, state }, '[REST] Tally set');
  res.json({ success: true, reporterId, state });
});

/** POST /api/tally/broadcast */
router.post('/broadcast', (req, res) => {
  const parse = TallyBodySchema.safeParse(req.body);
  if (!parse.success) {
    res.status(400).json({ error: 'Invalid body', details: parse.error.flatten() });
    return;
  }

  const { state } = parse.data;
  tallyService.broadcastTally(state);
  logger.info({ state }, '[REST] Tally broadcast');
  res.json({ success: true, state, count: reporterRegistry.count() });
});

/** GET /api/tally/:reporterId */
router.get('/:reporterId', (req, res) => {
  const { reporterId } = req.params;
  const state = tallyService.getTally(reporterId);
  if (state === null) {
    res.status(404).json({ error: 'Reporter not found' });
    return;
  }
  res.json({ reporterId, state });
});

export { router as tallyRouter };
