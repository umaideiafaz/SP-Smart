// ============================================================
// SP Smart Studio — Pipeline Module
// ============================================================
pub mod builder;
pub mod manager;

use serde::{Deserialize, Serialize};

/// Identificador único de um pipeline (= reporterId do app mobile).
pub type PipelineId = String;

/// Estado atual de um pipeline individual.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PipelineState {
    /// Pipeline criado mas não iniciado.
    Idle,
    /// Pipeline iniciando (negociando SRT, decodificando primeiros frames).
    Starting,
    /// Pipeline rodando e enviando vídeo/áudio para o hardware.
    Running,
    /// Pipeline pausado (sem destruir o hardware sink).
    Paused,
    /// Pipeline sofrendo erro recuperável (tentando reconectar).
    Recovering,
    /// Pipeline encerrado pelo operador ou por erro fatal.
    Stopped,
    /// Erro fatal — pipeline requer intervenção manual.
    Error,
}

/// Configuração completa para criação de um pipeline.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PipelineConfig {
    /// Identificador único deste canal (ex: reporterId do app).
    pub id: PipelineId,

    /// Nome amigável do canal (ex: "Repórter São Paulo").
    pub display_name: String,

    /// URL SRT do fluxo de entrada.
    /// Formato: srt://<host>:<port>?streamid=<key>&latency=<ms>
    pub srt_url: String,

    /// ID do dispositivo de saída de vídeo (do DeviceInfo.id).
    /// None = sem saída de vídeo (modo áudio apenas).
    pub video_device_id: Option<String>,

    /// ID do dispositivo de saída de áudio (do DeviceInfo.id).
    /// None = sem saída de áudio.
    pub audio_device_id: Option<String>,

    /// Latência SRT em ms (padrão 120ms para broadcast).
    #[serde(default = "default_latency")]
    pub srt_latency_ms: u32,

    /// Se true, tenta reconectar automaticamente em caso de queda do SRT.
    #[serde(default = "default_true")]
    pub auto_reconnect: bool,
}

fn default_latency() -> u32 { 120 }
fn default_true()   -> bool { true }

/// Snapshot de status de um pipeline (enviado ao frontend).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PipelineStatus {
    pub id:           PipelineId,
    pub display_name: String,
    pub state:        PipelineState,
    pub srt_url:      String,
    pub video_device_id: Option<String>,
    pub audio_device_id: Option<String>,
    /// Estatísticas de link (atualizadas a cada segundo)
    pub stats:        Option<PipelineStats>,
    pub error_message: Option<String>,
}

/// Estatísticas de link SRT e qualidade de decodificação.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PipelineStats {
    /// Bitrate de entrada SRT em kbps
    pub recv_bitrate_kbps: u64,
    /// Round-trip time em ms
    pub rtt_ms: u32,
    /// Pacotes perdidos (0.0 – 100.0)
    pub packet_loss_percent: f64,
    /// Frames decodificados por segundo
    pub decoded_fps: f64,
    /// Frames descartados desde o início
    pub dropped_frames: u64,
}
