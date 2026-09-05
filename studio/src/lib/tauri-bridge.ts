// ============================================================
// SP Smart Studio — Tauri IPC Bridge
// ============================================================
// Wrapper type-safe sobre invoke() do Tauri.
// Centraliza todos os command calls em um único lugar.
// ============================================================
import { invoke } from '@tauri-apps/api/core';
import type {
  DeviceInfo,
  DiscoveredDevices,
  PipelineConfig,
  PipelineStatus,
} from '@/types';

// ── Device Commands ───────────────────────────────────────────

export const listVideoDevices = (): Promise<DeviceInfo[]> =>
  invoke('list_video_devices');

export const listAudioDevices = (): Promise<DeviceInfo[]> =>
  invoke('list_audio_devices');

export const refreshDevices = (): Promise<DiscoveredDevices> =>
  invoke('refresh_devices');

// ── Pipeline Commands ─────────────────────────────────────────

export const startPipeline = (config: PipelineConfig): Promise<void> =>
  invoke('start_pipeline', { config });

export const stopPipeline = (id: string): Promise<void> =>
  invoke('stop_pipeline', { id });

export const updatePipelineDevices = (
  id: string,
  videoDeviceId?: string,
  audioDeviceId?: string,
): Promise<void> =>
  invoke('update_pipeline_devices', {
    id,
    videoDeviceId: videoDeviceId ?? null,
    audioDeviceId: audioDeviceId ?? null,
  });

export const getPipelineStatus = (id: string): Promise<PipelineStatus> =>
  invoke('get_pipeline_status', { id });

export const listPipelines = (): Promise<PipelineStatus[]> =>
  invoke('list_pipelines');
