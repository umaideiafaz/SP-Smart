// ============================================================
// SP Smart — Authentication Service
// ============================================================
// Uses HMAC-SHA256 to verify reporter tokens.
// Token = HMAC(reporterId + ":" + timestamp, AUTH_SECRET)
// ============================================================
import { createHmac, timingSafeEqual } from 'crypto';
import { config } from '../config';
import { logger } from '../utils/logger';

const REPLAY_WINDOW_MS = 30_000; // ±30 seconds

/**
 * Validates a reporter's authentication token.
 * @returns true if the token is valid and not replayed.
 */
export function validateAuthToken(
  reporterId: string,
  timestamp: number,
  receivedToken: string
): boolean {
  // 1. Replay attack check
  const now = Date.now();
  if (Math.abs(now - timestamp) > REPLAY_WINDOW_MS) {
    logger.warn(
      { reporterId, timestamp, now, delta: now - timestamp },
      'Auth rejected: timestamp outside replay window'
    );
    return false;
  }

  // 2. HMAC verification
  const expected = computeToken(reporterId, timestamp);
  try {
    const expectedBuf = Buffer.from(expected, 'hex');
    const receivedBuf = Buffer.from(receivedToken, 'hex');

    if (expectedBuf.length !== receivedBuf.length) {
      logger.warn({ reporterId }, 'Auth rejected: token length mismatch');
      return false;
    }

    // Timing-safe comparison to prevent timing attacks
    const match = timingSafeEqual(expectedBuf, receivedBuf);
    if (!match) {
      logger.warn({ reporterId }, 'Auth rejected: token mismatch');
    }
    return match;
  } catch (err) {
    logger.error({ err, reporterId }, 'Auth error during comparison');
    return false;
  }
}

/**
 * Computes the expected HMAC token for a given reporter + timestamp.
 * Exposed for use in testing and token generation utilities.
 */
export function computeToken(reporterId: string, timestamp: number): string {
  return createHmac('sha256', config.authSecret)
    .update(`${reporterId}:${timestamp}`)
    .digest('hex');
}
