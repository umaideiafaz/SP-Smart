// ============================================================
// SP Smart Studio — Dashboard
// ============================================================
import { useEffect, useRef, useState } from 'react';
import { RefreshCw, Tv2, HardDrive, AlertCircle, Plus, X } from 'lucide-react';
import clsx from 'clsx';
import { ReporterCard } from './ReporterCard';
import { useStudioStore } from '@/store';
import type { ChannelConfig } from '@/types';

const POLL_INTERVAL_MS = 1500; // Atualiza stats a cada 1,5s

// ── Mock: canais pré-configurados (Fase 3 virá do SignalingServer via WS) ──
const DEMO_CHANNELS: ChannelConfig[] = [
  {
    reporterId:  'reporter-001',
    displayName: 'Repórter São Paulo',
    srtUrl:      'srt://192.168.1.50:8890?streamid=reporter-001&latency=120',
  },
  {
    reporterId:  'reporter-002',
    displayName: 'Repórter Rio de Janeiro',
    srtUrl:      'srt://192.168.1.51:8890?streamid=reporter-002&latency=120',
  },
];

// ─────────────────────────────────────────────────────────────

export function Dashboard() {
  const {
    videoDevices, audioDevices,
    devicesLoading, devicesError,
    loadDevices, refreshDevices,
    pipelines, pollPipelines,
  } = useStudioStore();

  const [channels, setChannels] = useState<ChannelConfig[]>(DEMO_CHANNELS);
  const [showAddChannel, setShowAddChannel] = useState(false);
  const pollRef = useRef<ReturnType<typeof setInterval>>();

  // ── Carrega dispositivos na montagem ──────────────────────
  useEffect(() => {
    loadDevices();
  }, [loadDevices]);

  // ── Poll de status dos pipelines ─────────────────────────
  useEffect(() => {
    pollPipelines(); // inicial
    pollRef.current = setInterval(pollPipelines, POLL_INTERVAL_MS);
    return () => clearInterval(pollRef.current);
  }, [pollPipelines]);

  // ── Utilitário: status de um canal ───────────────────────
  const getPipelineStatus = (reporterId: string) =>
    pipelines.find(p => p.id === reporterId);

  const runningCount = pipelines.filter(p => p.state === 'RUNNING').length;
  const errorCount   = pipelines.filter(p => p.state === 'ERROR').length;

  return (
    <div className="flex h-screen flex-col bg-gray-950 text-gray-100">

      {/* ── Top Bar ──────────────────────────────────────────── */}
      <header className="flex items-center justify-between border-b border-gray-800 px-6 py-3">
        <div className="flex items-center gap-3">
          <Tv2 size={22} className="text-red-500" />
          <span className="text-base font-bold tracking-tight">SP Smart Studio</span>
          <span className="text-xs text-gray-600">IP-to-Baseband Decoder</span>
        </div>

        {/* ── Status summary ─────────────────────────────── */}
        <div className="flex items-center gap-4 text-xs">
          <span className="flex items-center gap-1.5">
            <span className="h-2 w-2 rounded-full bg-green-500" />
            {runningCount} on air
          </span>
          {errorCount > 0 && (
            <span className="flex items-center gap-1.5 text-red-400">
              <AlertCircle size={12} />
              {errorCount} erro{errorCount > 1 ? 's' : ''}
            </span>
          )}

          {/* Device count badge */}
          <span className="flex items-center gap-1.5 text-gray-500">
            <HardDrive size={12} />
            {videoDevices.length}V / {audioDevices.length}A dispositivos
          </span>

          {/* Refresh button */}
          <button
            onClick={refreshDevices}
            disabled={devicesLoading}
            className="flex items-center gap-1 rounded-md border border-gray-700 px-2.5 py-1 text-gray-400 hover:text-gray-100 hover:border-gray-500 transition-colors disabled:opacity-40"
          >
            <RefreshCw size={12} className={clsx(devicesLoading && 'animate-spin')} />
            Atualizar Hardware
          </button>
        </div>
      </header>

      {/* ── Device error banner ───────────────────────────────── */}
      {devicesError && (
        <div className="mx-6 mt-3 flex items-center gap-2 rounded-md border border-red-900 bg-red-950/50 px-4 py-2 text-sm text-red-300">
          <AlertCircle size={14} />
          Erro ao carregar dispositivos: {devicesError}
        </div>
      )}

      {/* ── No devices warning ───────────────────────────────── */}
      {!devicesLoading && videoDevices.length === 0 && (
        <div className="mx-6 mt-3 flex items-center gap-2 rounded-md border border-yellow-900/50 bg-yellow-950/30 px-4 py-2 text-xs text-yellow-400">
          <AlertCircle size={12} />
          Nenhum dispositivo de saída de vídeo encontrado. Verifique os plugins GStreamer instalados
          (decklinkvideosink, d3d11videosink, autovideosink...).
        </div>
      )}

      {/* ── Main content ─────────────────────────────────────── */}
      <main className="flex-1 overflow-y-auto p-6">
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-sm font-semibold uppercase tracking-widest text-gray-500">
            Canais de Repórter ({channels.length})
          </h2>
          <button
            onClick={() => setShowAddChannel(true)}
            className="flex items-center gap-1.5 rounded-md bg-gray-800 hover:bg-gray-700 px-3 py-1.5 text-xs text-gray-300 transition-colors"
          >
            <Plus size={12} />
            Adicionar Canal
          </button>
        </div>

        {/* ── Channel grid ─────────────────────────────────── */}
        <div className="grid gap-4 grid-cols-1 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4">
          {channels.map(channel => (
            <ReporterCard
              key={channel.reporterId}
              channel={channel}
              pipelineStatus={getPipelineStatus(channel.reporterId)}
            />
          ))}

          {channels.length === 0 && (
            <div className="col-span-full flex flex-col items-center justify-center rounded-xl border border-dashed border-gray-800 py-16 text-gray-600">
              <Tv2 size={32} className="mb-3 opacity-30" />
              <p className="text-sm">Nenhum canal configurado.</p>
              <p className="text-xs mt-1">Clique em "Adicionar Canal" para começar.</p>
            </div>
          )}
        </div>
      </main>

      {/* ── Add Channel Modal ─────────────────────────────────── */}
      {showAddChannel && (
        <AddChannelModal
          onAdd={(ch) => { setChannels(prev => [...prev, ch]); setShowAddChannel(false); }}
          onClose={() => setShowAddChannel(false)}
        />
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// AddChannelModal
// ─────────────────────────────────────────────────────────────

function AddChannelModal({
  onAdd, onClose,
}: {
  onAdd: (ch: ChannelConfig) => void;
  onClose: () => void;
}) {
  const [displayName, setDisplayName] = useState('');
  const [srtUrl, setSrtUrl] = useState('srt://');
  const [reporterId, setReporterId] = useState(() =>
    `reporter-${Math.random().toString(36).slice(2, 10)}`
  );

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!displayName.trim() || !srtUrl.trim()) return;
    onAdd({ reporterId, displayName: displayName.trim(), srtUrl: srtUrl.trim() });
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 backdrop-blur-sm">
      <div className="w-full max-w-md rounded-xl border border-gray-700 bg-gray-900 p-6 shadow-2xl">
        <div className="mb-5 flex items-center justify-between">
          <h3 className="font-semibold">Adicionar Canal de Repórter</h3>
          <button onClick={onClose} className="text-gray-500 hover:text-gray-300">
            <X size={18} />
          </button>
        </div>

        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <label className="flex flex-col gap-1 text-sm">
            <span className="text-gray-400">Nome do Repórter</span>
            <input
              value={displayName}
              onChange={e => setDisplayName(e.target.value)}
              placeholder="ex: Repórter Brasília"
              required
              className="rounded-md border border-gray-700 bg-gray-800 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-600"
            />
          </label>

          <label className="flex flex-col gap-1 text-sm">
            <span className="text-gray-400">URL SRT</span>
            <input
              value={srtUrl}
              onChange={e => setSrtUrl(e.target.value)}
              placeholder="srt://192.168.1.100:8890?streamid=reporter-xxx"
              required
              className="rounded-md border border-gray-700 bg-gray-800 px-3 py-2 text-sm font-mono focus:outline-none focus:ring-2 focus:ring-blue-600"
            />
          </label>

          <label className="flex flex-col gap-1 text-sm">
            <span className="text-gray-400">Reporter ID</span>
            <input
              value={reporterId}
              onChange={e => setReporterId(e.target.value)}
              className="rounded-md border border-gray-700 bg-gray-800 px-3 py-2 text-sm font-mono text-gray-500 focus:outline-none focus:ring-2 focus:ring-blue-600"
            />
          </label>

          <div className="flex gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="flex-1 rounded-md border border-gray-700 py-2 text-sm text-gray-400 hover:text-gray-200 transition-colors"
            >
              Cancelar
            </button>
            <button
              type="submit"
              className="flex-1 rounded-md bg-blue-700 py-2 text-sm font-semibold text-white hover:bg-blue-600 transition-colors"
            >
              Adicionar
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
