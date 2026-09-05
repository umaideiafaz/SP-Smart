// ============================================================
// SP Smart Studio — WebRTC Module
// ============================================================
pub mod peer;
pub mod signaling_client;
pub mod audio_capture;
pub mod video_capture;

use serde::{Deserialize, Serialize};

/// Estado da conexão WebRTC com um repórter específico.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum IFBConnectionState {
    /// Nenhuma sessão iniciada.
    Idle,
    /// Aguardando SDP offer do repórter ou criando offer local.
    Signaling,
    /// ICE em progresso.
    Connecting,
    /// WebRTC conectado e mídia fluindo.
    Connected,
    /// Conexão encerrada.
    Closed,
    /// Erro fatal na sessão.
    Error,
}

/// Status de uma sessão IFB ativa (enviado ao frontend).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IFBSessionStatus {
    pub reporter_id:    String,
    pub state:          IFBConnectionState,
    pub audio_source:   Option<String>,  // device display name
    pub video_source:   Option<String>,  // device display name
    pub error_message:  Option<String>,
}

/// Configuração para iniciar uma sessão IFB com um repórter.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IFBSessionConfig {
    pub reporter_id:       String,
    /// ID do dispositivo de CAPTURA de áudio (saída da mesa de som / Mix-Minus).
    pub audio_device_id:   Option<String>,
    /// ID do dispositivo de CAPTURA de vídeo (NDI ou capture card).
    pub video_device_id:   Option<String>,
    /// Bitrate-alvo do vídeo de retorno em kbps (padrão 800kbps — baixo bitrate).
    #[serde(default = "default_video_bitrate")]
    pub video_bitrate_kbps: u32,
    /// Largura do vídeo de retorno (padrão 640px).
    #[serde(default = "default_video_width")]
    pub video_width: u32,
    /// Altura do vídeo de retorno (padrão 360px).
    #[serde(default = "default_video_height")]
    pub video_height: u32,
}

fn default_video_bitrate() -> u32 { 800 }
fn default_video_width()   -> u32 { 640 }
fn default_video_height()  -> u32 { 360 }
