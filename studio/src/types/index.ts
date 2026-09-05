// ============================================================
// SP Smart Studio — Frontend Types
// ============================================================
// Espelho exato dos tipos Rust/Serde para garantir type-safety
// no IPC Tauri. Qualquer alteração nos tipos Rust deve ser
// refletida aqui.
// ============================================================

// ── Dispositivos ─────────────────────────────────────────────

export type DeviceClass =
  | 'VIDEO_SINK'
  | 'AUDIO_SINK'
  | 'VIDEO_SOURCE'
  | 'AUDIO_SOURCE'
  | 'OTHER';

export interface DeviceInfo {
  id:           string;
  display_name: string;
  gst_class:    string;
  device_class: DeviceClass;
  element_type: string;
  properties:   Record<string, string>;
  is_auto:      boolean;
}

export interface DiscoveredDevices {
  video_sinks: DeviceInfo[];
  audio_sinks: DeviceInfo[];
}

// ── Pipeline ──────────────────────────────────────────────────

export type PipelineState =
  | 'IDLE'
  | 'STARTING'
  | 'RUNNING'
  | 'PAUSED'
  | 'RECOVERING'
  | 'STOPPED'
  | 'ERROR';

export interface PipelineConfig {
  id:               string;
  display_name:     string;
  srt_url:          string;
  video_device_id?: string;
  audio_device_id?: string;
  srt_latency_ms?:  number;
  auto_reconnect?:  boolean;
}

export interface PipelineStats {
  recv_bitrate_kbps:   number;
  rtt_ms:              number;
  packet_loss_percent: number;
  decoded_fps:         number;
  dropped_frames:      number;
}

export interface PipelineStatus {
  id:               string;
  display_name:     string;
  state:            PipelineState;
  srt_url:          string;
  video_device_id?: string;
  audio_device_id?: string;
  stats?:           PipelineStats;
  error_message?:   string;
}

// ── Configuração de Canal (UI model) ─────────────────────────
// Estende PipelineStatus com dados UI que não vêm do backend

export interface ChannelConfig {
  /** ID do repórter (usado como PipelineId) */
  reporterId:     string;
  /** Nome exibido na UI */
  displayName:    string;
  /** URL SRT recebida do SignalingServer (SERVER_WELCOME) */
  srtUrl:         string;
  /** Device selecionado pelo operador para vídeo */
  videoDeviceId?: string;
  /** Device selecionado pelo operador para áudio */
  audioDeviceId?: string;
}
