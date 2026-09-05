// ============================================================
// SP Smart — Reporter Status REST Routes
// ============================================================
// GET /api/reporters          — list all connected reporters
// GET /api/reporters/:id      — get single reporter status
// ============================================================
import { Router } from 'express';
import { reporterRegistry } from '../../services/ReporterRegistry';

const router = Router();

const toSafeView = (s: ReturnType<typeof reporterRegistry.get>) => {
  if (!s) return null;
  return {
    sessionId: s.sessionId,
    reporterId: s.reporterId,
    displayName: s.displayName,
    srtStreamKey: s.srtStreamKey,
    state: s.state,
    tallyState: s.tallyState,
    encodingPreset: s.encodingPreset,
    connectedAt: s.connectedAt,
    lastSeenAt: s.lastSeenAt,
    lastStatus: s.lastStatus,
  };
};

/** GET /api/reporters */
router.get('/', (_req, res) => {
  const reporters = reporterRegistry.getAll().map((s) => toSafeView(s));
  res.json({ count: reporters.length, reporters });
});

/** GET /api/reporters/:reporterId */
router.get('/:reporterId', (req, res) => {
  const session = reporterRegistry.get(req.params.reporterId);
  if (!session) {
    res.status(404).json({ error: 'Reporter not found' });
    return;
  }
  res.json(toSafeView(session));
});

export { router as reportersRouter };
