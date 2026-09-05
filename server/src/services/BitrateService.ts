// ============================================================
// SP Smart — Bitrate Control Service
// ============================================================
// Issues dynamic bitrate commands to reporters.
// The studio triggers changes via REST; this service validates
// constraints and delivers the command via WebSocket.
// ============================================================
import type { EncodingPreset } from '../types/protocol';
import { reporterRegistry } from './ReporterRegistry';
import { sendToReporter } from '../ws/utils';
import { logger } from '../utils/logger';

/** Preset bitrate boundaries (kbps) */
const PRESET_CONSTRAINTS: Record<
  EncodingPreset,
  { min: number; target: number; max: number }
> = {
  LOW_LATENCY_SD:    { min: 500,  target: 1000, max: 1500  },
  LOW_LATENCY_HD:    { min: 1500, target: 3000, max: 4500  },
  QUALITY_HD:        { min: 2000, target: 5000, max: 7000  },
  QUALITY_FHD:       { min: 4000, target: 8000, max: 12000 },
  QUALITY_FHD_HIGH:  { min: 8000, target: 15000, max: 20000 },
};

export class BitrateService {
  /**
   * Sends a bitrate command to a specific reporter.
   * If preset is provided, it overrides individual bitrate values.
   */
  sendBitrateCommand(
    reporterId: string,
    options: {
      preset?: EncodingPreset;
      targetBitrate?: number;
      maxBitrate?: number;
      minBitrate?: number;
    }
  ): boolean {
    const session = reporterRegistry.get(reporterId);
    if (!session) {
      logger.warn({ reporterId }, 'BitrateService: reporter not found');
      return false;
    }

    const preset: EncodingPreset = options.preset ?? session.encodingPreset;
    const constraints = PRESET_CONSTRAINTS[preset];

    const targetBitrate = options.targetBitrate ?? constraints.target;
    const maxBitrate    = options.maxBitrate    ?? constraints.max;
    const minBitrate    = options.minBitrate    ?? constraints.min;

    const sent = sendToReporter(session, {
      type: 'SERVER_BITRATE_CMD',
      reporterId,
      targetBitrate,
      maxBitrate,
      minBitrate,
      encodingPreset: preset,
    });

    if (sent) {
      reporterRegistry.updateStatus(reporterId, { encodingPreset: preset });
      logger.info(
        { reporterId, preset, targetBitrate, minBitrate, maxBitrate },
        'Bitrate command sent'
      );
    }

    return sent;
  }

  getPresetConstraints(preset: EncodingPreset) {
    return PRESET_CONSTRAINTS[preset];
  }

  getAllPresets(): Record<EncodingPreset, { min: number; target: number; max: number }> {
    return PRESET_CONSTRAINTS;
  }
}

export const bitrateService = new BitrateService();
