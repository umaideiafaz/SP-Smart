// ============================================================
// SP Smart Studio — Error Types
// ============================================================
use thiserror::Error;

#[derive(Debug, Error)]
pub enum StudioError {
    #[error("GStreamer initialization failed: {0}")]
    GstInit(#[from] gstreamer::glib::Error),

    #[error("GStreamer error: {0}")]
    Gst(String),

    #[error("Pipeline '{id}' not found")]
    PipelineNotFound { id: String },

    #[error("Pipeline '{id}' already exists")]
    PipelineAlreadyExists { id: String },

    #[error("Failed to create GStreamer element '{name}': element type not found. Ensure the GStreamer plugin is installed.")]
    ElementCreate { name: String },

    #[error("Failed to link GStreamer elements: {0}")]
    ElementLink(String),

    #[error("Device not found: {device_id}")]
    DeviceNotFound { device_id: String },

    #[error("Device '{device_id}' cannot create a GStreamer element")]
    DeviceCreateElement { device_id: String },

    #[error("Invalid SRT URI: {0}")]
    InvalidSrtUri(String),

    #[error("Pipeline state change failed: {0}")]
    StateChange(String),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("Internal error: {0}")]
    Internal(String),
}

/// Converte StudioError para String para ser retornado via Tauri IPC.
/// O Tauri exige que comandos retornem Result<T, String> ou implementem Serialize.
impl serde::Serialize for StudioError {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_string())
    }
}

pub type StudioResult<T> = Result<T, StudioError>;
