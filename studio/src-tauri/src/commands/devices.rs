// ============================================================
// SP Smart Studio — Tauri Commands: Device Discovery
// ============================================================
use tauri::State;

use crate::{
    device_monitor::{discover_devices, DeviceInfo, DiscoveredDevices},
    error::{StudioError, StudioResult},
    state::AppState,
};

/// Retorna todos os dispositivos de saída de VÍDEO disponíveis no sistema.
///
/// Frontend:
///   `invoke('list_video_devices')`
///   → Promise<DeviceInfo[]>
#[tauri::command]
pub fn list_video_devices(state: State<AppState>) -> StudioResult<Vec<DeviceInfo>> {
    let devices = state.discovered_devices.read().unwrap();
    Ok(devices.video_sinks.clone())
}

/// Retorna todos os dispositivos de saída de ÁUDIO disponíveis no sistema.
///
/// Frontend:
///   `invoke('list_audio_devices')`
///   → Promise<DeviceInfo[]>
#[tauri::command]
pub fn list_audio_devices(state: State<AppState>) -> StudioResult<Vec<DeviceInfo>> {
    let devices = state.discovered_devices.read().unwrap();
    Ok(devices.audio_sinks.clone())
}

/// Re-executa a varredura de hardware e atualiza a lista em memória.
///
/// Útil quando o operador conecta uma nova placa sem reiniciar o app.
///
/// Frontend:
///   `invoke('refresh_devices')`
///   → Promise<DiscoveredDevices>
#[tauri::command]
pub fn refresh_devices(state: State<AppState>) -> StudioResult<DiscoveredDevices> {
    let fresh = discover_devices()?;
    let mut devices = state.discovered_devices.write().unwrap();
    *devices = fresh.clone();
    Ok(fresh)
}
