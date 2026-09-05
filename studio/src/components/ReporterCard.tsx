// ============================================================
// SP Smart Studio — ReporterCard Component
// ============================================================
import { useState, useCallback } from 'react';
import {
  Radio, Square, RefreshCw, AlertTriangle,
  Wifi, WifiOff, Activity,
} from 'lucide-react';
import clsx from 'clsx';
import { DeviceSelector } from './DeviceSelector';
import { useStudioStore } from '@/store';
import type { PipelineStatus, ChannelConfig } from '@/types';

interface ReporterCardProps {
  channel:        ChannelConfig;
  pipelineStatus?: PipelineStatus;
}

// ── Helpers de display ────────────────────────────────────────

const STATE_STYLES: Record<string, { bg: string; text: string; label: string }> = {
  IDLE:       { bg: 'bg-gray-700',          text: 'text-gray-300',   label: 'Idle'       },
  STARTING:   { bg: 'bg-yellow-900/60',     text: 'text-yellow-300', label: 'Iniciando'  },
  RUNNING:    { bg: 'bg-green-900/60',      text: 'text-green-300',  label: 'On Air'     },
  PAUSED:     { bg: 'bg-blue-900/50',       text: 'text-blue-300',   label: 'Pausado'    },
  RECOVERING: { bg: 'bg-orange-900/50',     text: 'text-orange-300', label: 'Reconect.'  },
  STOPPED:    { bg: 'bg-gray-800',          text: 'text-gray-500',   label: 'Parado'     },
  ERROR:      { bg: 'bg-red-950/70',        text: 'text-red-400',    label: 'ERRO'       },
};

function StatBadge({ label, value, unit }: { label: string; value: string | number; unit?: string }) {
  return (
    <div className="flex flex-col items-center rounded bg-gray-800/70 px-2 py-1 min-w-[52px]">
      <span className="text-[9px] uppercase tracking-widest text-gray-500">{label}</span>
      <span className="text-xs font-mono font-bold text-gray-200">
        {value}
        {unit && <span className="text-gray-500 text-[9px] ml-0.5">{unit}</span>}
      </span>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────

export function ReporterCard({ channel, pipelineStatus }: ReporterCardProps) {
  const { videoDevices, audioDevices, startChannel, stopChannel, routeChannelDevices } =
    useStudioStore();

  const [videoDeviceId, setVideoDeviceId] = useState<string | undefined>(
    channel.videoDeviceId ?? pipelineStatus?.video_device_id,
  );
  const [audioDeviceId, setAudioDeviceId] = useState<string | undefined>(
    channel.audioDeviceId ?? pipelineStatus?.audio_device_id,
  );
  const [isRouting, setIsRouting] = useState(false);

  const state = pipelineStatus?.state ?? 'IDLE';
  const stateStyle = STATE_STYLES[state] ?? STATE_STYLES.IDLE;
  const isRunning = state === 'RUNNING' || state === 'STARTING' || state === 'RECOVERING';

  // ── Iniciar pipeline ──────────────────────────────────────
  const handleStart = useCallback(async () => {
    await startChannel({
      reporterId:    channel.reporterId,
      displayName:   channel.displayName,
      srtUrl:        channel.srtUrl,
      videoDeviceId,
      audioDeviceId,
    });
  }, [channel, videoDeviceId, audioDeviceId, startChannel]);

  // ── Parar pipeline ────────────────────────────────────────
  const handleStop = useCallback(async () => {
    await stopChannel(channel.reporterId);
  }, [channel.reporterId, stopChannel]);

  // ── Roteamento dinâmico (troca device sem parar) ──────────
  const handleRouteVideo = useCallback(async (devId?: string) => {
    setVideoDeviceId(devId);
    if (isRunning) {
      setIsRouting(true);
      try {
        await routeChannelDevices(channel.reporterId, devId, audioDeviceId);
      } finally {
        setIsRouting(false);
      }
    }
  }, [isRunning, channel.reporterId, audioDeviceId, routeChannelDevices]);

  const handleRouteAudio = useCallback(async (devId?: string) => {
    setAudioDeviceId(devId);
    if (isRunning) {
      setIsRouting(true);
      try {
        await routeChannelDevices(channel.reporterId, videoDeviceId, devId);
      } finally {
        setIsRouting(false);
      }
    }
  }, [isRunning, channel.reporterId, videoDeviceId, routeChannelDevices]);

  const stats = pipelineStatus?.stats;

  return (
    <div
      className={clsx(
        'flex flex-col gap-3 rounded-xl border p-4 transition-all duration-300',
        'bg-gray-950',
        state === 'RUNNING'  && 'border-green-700/60 shadow-lg shadow-green-950/40',
        state === 'ERROR'    && 'border-red-800/60   shadow-lg shadow-red-950/40',
        state === 'IDLE' || state === 'STOPPED' ? 'border-gray-800' : '',
        state !== 'RUNNING' && state !== 'ERROR' && state !== 'IDLE' && state !== 'STOPPED'
          && 'border-yellow-800/40',
      )}
    >
      {/* ── Header ─────────────────────────────────────────── */}
      <div className="flex items-start justify-between gap-2">
        <div className="flex items-center gap-2 min-w-0">
          {/* Indicador de status */}
          {isRunning
            ? <Radio size={16} className="text-green-400 shrink-0 animate-pulse" />
            : <WifiOff size={16} className="text-gray-600 shrink-0" />
          }
          <div className="min-w-0">
            <h3 className="truncate font-semibold text-sm text-gray-100">
              {channel.displayName}
            </h3>
            <p className="truncate text-[10px] text-gray-600 font-mono">
              {channel.srtUrl}
            </p>
          </div>
        </div>

        {/* Badge de estado */}
        <span
          className={clsx(
            'shrink-0 rounded-md px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider',
            stateStyle.bg, stateStyle.text,
          )}
        >
          {stateStyle.label}
        </span>
      </div>

      {/* ── Stats (quando running) ──────────────────────────── */}
      {stats && (
        <div className="flex flex-wrap gap-1.5">
          <StatBadge label="Bitrate"  value={stats.recv_bitrate_kbps}   unit="kbps" />
          <StatBadge label="RTT"      value={stats.rtt_ms}               unit="ms"   />
          <StatBadge label="Loss"     value={stats.packet_loss_percent.toFixed(1)} unit="%" />
          <StatBadge label="FPS"      value={stats.decoded_fps.toFixed(0)} />
          <StatBadge label="Dropped"  value={stats.dropped_frames} />
        </div>
      )}

      {/* ── Error Message ───────────────────────────────────── */}
      {pipelineStatus?.error_message && (
        <div className="flex items-start gap-2 rounded-md bg-red-950/50 border border-red-900/50 px-3 py-2">
          <AlertTriangle size={14} className="text-red-400 mt-0.5 shrink-0" />
          <p className="text-xs text-red-300 break-all">{pipelineStatus.error_message}</p>
        </div>
      )}

      {/* ── Device Selectors ────────────────────────────────── */}
      <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
        <DeviceSelector
          label="Saída de Vídeo"
          type="video"
          devices={videoDevices}
          value={videoDeviceId}
          onChange={handleRouteVideo}
          disabled={isRouting}
        />
        <DeviceSelector
          label="Saída de Áudio"
          type="audio"
          devices={audioDevices}
          value={audioDeviceId}
          onChange={handleRouteAudio}
          disabled={isRouting}
        />
      </div>

      {/* ── Routing indicator ───────────────────────────────── */}
      {isRouting && (
        <p className="flex items-center gap-1.5 text-xs text-yellow-400 animate-pulse">
          <RefreshCw size={12} className="animate-spin" />
          Reencaminhando pipeline...
        </p>
      )}

      {/* ── Actions ─────────────────────────────────────────── */}
      <div className="flex gap-2 pt-1">
        {!isRunning ? (
          <button
            onClick={handleStart}
            disabled={!channel.srtUrl}
            className={clsx(
              'flex flex-1 items-center justify-center gap-2 rounded-md py-2 text-sm font-semibold',
              'bg-green-800 hover:bg-green-700 text-white transition-colors',
              'disabled:opacity-40 disabled:cursor-not-allowed',
            )}
          >
            <Radio size={14} />
            Iniciar Decodificação
          </button>
        ) : (
          <button
            onClick={handleStop}
            className="flex flex-1 items-center justify-center gap-2 rounded-md py-2 text-sm font-semibold bg-red-900 hover:bg-red-800 text-white transition-colors"
          >
            <Square size={14} />
            Parar
          </button>
        )}
      </div>
    </div>
  );
}
