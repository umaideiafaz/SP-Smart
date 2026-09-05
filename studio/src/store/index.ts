// ============================================================
// SP Smart Studio — Zustand Global Store
// ============================================================
import { create } from 'zustand';
import type { DeviceInfo, PipelineStatus, ChannelConfig } from '@/types';
import * as bridge from '@/lib/tauri-bridge';

// ── Tipos de slice ────────────────────────────────────────────

interface DeviceSlice {
  videoDevices:    DeviceInfo[];
  audioDevices:    DeviceInfo[];
  devicesLoading:  boolean;
  devicesError:    string | null;
  loadDevices:     () => Promise<void>;
  refreshDevices:  () => Promise<void>;
}

interface PipelineSlice {
  pipelines:          PipelineStatus[];
  pipelinesLoading:   boolean;
  pipelineError:      string | null;
  pollPipelines:      () => Promise<void>;
  startChannel:       (channel: ChannelConfig) => Promise<void>;
  stopChannel:        (id: string) => Promise<void>;
  routeChannelDevices:(id: string, videoDeviceId?: string, audioDeviceId?: string) => Promise<void>;
}

type StudioStore = DeviceSlice & PipelineSlice;

// ─────────────────────────────────────────────────────────────

export const useStudioStore = create<StudioStore>((set, get) => ({
  // ── Device Slice ──────────────────────────────────────────
  videoDevices:   [],
  audioDevices:   [],
  devicesLoading: false,
  devicesError:   null,

  loadDevices: async () => {
    set({ devicesLoading: true, devicesError: null });
    try {
      const [video, audio] = await Promise.all([
        bridge.listVideoDevices(),
        bridge.listAudioDevices(),
      ]);
      set({ videoDevices: video, audioDevices: audio });
    } catch (e) {
      set({ devicesError: String(e) });
    } finally {
      set({ devicesLoading: false });
    }
  },

  refreshDevices: async () => {
    set({ devicesLoading: true, devicesError: null });
    try {
      const result = await bridge.refreshDevices();
      set({
        videoDevices: result.video_sinks,
        audioDevices: result.audio_sinks,
      });
    } catch (e) {
      set({ devicesError: String(e) });
    } finally {
      set({ devicesLoading: false });
    }
  },

  // ── Pipeline Slice ────────────────────────────────────────
  pipelines:        [],
  pipelinesLoading: false,
  pipelineError:    null,

  pollPipelines: async () => {
    try {
      const pipelines = await bridge.listPipelines();
      set({ pipelines });
    } catch (e) {
      // Silently ignore poll errors (server might be busy)
      console.warn('Pipeline poll error:', e);
    }
  },

  startChannel: async (channel: ChannelConfig) => {
    set({ pipelineError: null });
    try {
      await bridge.startPipeline({
        id:               channel.reporterId,
        display_name:     channel.displayName,
        srt_url:          channel.srtUrl,
        video_device_id:  channel.videoDeviceId,
        audio_device_id:  channel.audioDeviceId,
        srt_latency_ms:   120,
        auto_reconnect:   true,
      });
      await get().pollPipelines();
    } catch (e) {
      set({ pipelineError: String(e) });
    }
  },

  stopChannel: async (id: string) => {
    set({ pipelineError: null });
    try {
      await bridge.stopPipeline(id);
      await get().pollPipelines();
    } catch (e) {
      set({ pipelineError: String(e) });
    }
  },

  routeChannelDevices: async (
    id: string,
    videoDeviceId?: string,
    audioDeviceId?: string,
  ) => {
    set({ pipelineError: null });
    try {
      await bridge.updatePipelineDevices(id, videoDeviceId, audioDeviceId);
      await get().pollPipelines();
    } catch (e) {
      set({ pipelineError: String(e) });
    }
  },
}));
