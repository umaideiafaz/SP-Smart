// ============================================================
// SP Smart Studio — Tauri Commands: Pipeline Control
// ============================================================
use tauri::State;

use crate::{
    error::{StudioResult},
    pipeline::{PipelineConfig, PipelineStatus},
    state::AppState,
};

/// Inicia um pipeline de decodificação para um canal de repórter.
///
/// Frontend:
///   `invoke('start_pipeline', { config: PipelineConfig })`
///   → Promise<void>
#[tauri::command]
pub fn start_pipeline(
    config: PipelineConfig,
    state:  State<AppState>,
) -> StudioResult<()> {
    let devices = state.discovered_devices.read().unwrap();
    state.pipeline_manager.start_pipeline(config, &devices)
}

/// Para e remove o pipeline de um canal.
///
/// Frontend:
///   `invoke('stop_pipeline', { id: string })`
///   → Promise<void>
#[tauri::command]
pub fn stop_pipeline(
    id:    String,
    state: State<AppState>,
) -> StudioResult<()> {
    state.pipeline_manager.stop_pipeline(&id)
}

/// Atualiza os devices de saída de um pipeline em execução.
/// Reconstrói o pipeline internamente com zero-downtime na interface.
///
/// Frontend:
///   `invoke('update_pipeline_devices', { id, videoDeviceId, audioDeviceId })`
///   → Promise<void>
#[tauri::command]
pub fn update_pipeline_devices(
    id:              String,
    video_device_id: Option<String>,
    audio_device_id: Option<String>,
    state:           State<AppState>,
) -> StudioResult<()> {
    let devices = state.discovered_devices.read().unwrap();
    state.pipeline_manager.update_pipeline_devices(
        &id,
        video_device_id,
        audio_device_id,
        &devices,
    )
}

/// Retorna o status atual de um pipeline.
///
/// Frontend:
///   `invoke('get_pipeline_status', { id: string })`
///   → Promise<PipelineStatus>
#[tauri::command]
pub fn get_pipeline_status(
    id:    String,
    state: State<AppState>,
) -> StudioResult<PipelineStatus> {
    state.pipeline_manager.get_status(&id)
}

/// Lista todos os pipelines ativos com seus status.
///
/// Frontend:
///   `invoke('list_pipelines')`
///   → Promise<PipelineStatus[]>
#[tauri::command]
pub fn list_pipelines(state: State<AppState>) -> Vec<PipelineStatus> {
    state.pipeline_manager.list_status()
}
