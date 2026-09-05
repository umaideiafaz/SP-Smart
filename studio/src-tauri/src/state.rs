// ============================================================
// SP Smart Studio — Application State (Tauri Managed State)
// ============================================================
use std::sync::{Arc, RwLock};

use crate::{
    device_monitor::DiscoveredDevices,
    pipeline::manager::PipelineManager,
};

/// Estado global da aplicação, gerenciado pelo Tauri.
///
/// Tauri mantém uma instância singleton deste struct, acessível
/// em qualquer Tauri command via `tauri::State<AppState>`.
pub struct AppState {
    /// Dispositivos descobertos na inicialização (e atualizáveis via refresh).
    pub discovered_devices: Arc<RwLock<DiscoveredDevices>>,

    /// Gerenciador de pipelines de decodificação.
    pub pipeline_manager: PipelineManager,
}

impl AppState {
    pub fn new(discovered: DiscoveredDevices) -> Self {
        Self {
            discovered_devices: Arc::new(RwLock::new(discovered)),
            pipeline_manager:   PipelineManager::new(),
        }
    }
}
