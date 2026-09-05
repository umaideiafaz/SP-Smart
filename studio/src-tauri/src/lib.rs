// ============================================================
// SP Smart Studio — Library Root (Tauri App Setup)
// ============================================================

mod commands;
mod device_monitor;
mod error;
mod pipeline;
mod state;

use tracing::info;
use tracing_subscriber::EnvFilter;

use crate::{
    commands::{
        devices::{
            list_audio_devices,
            list_video_devices,
            refresh_devices,
        },
        pipeline::{
            get_pipeline_status,
            list_pipelines,
            start_pipeline,
            stop_pipeline,
            update_pipeline_devices,
        },
    },
    device_monitor::discover_devices,
    state::AppState,
};

/// Ponto de entrada da biblioteca — chamado por `main.rs`.
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // ── Logging ───────────────────────────────────────────────
    //
    // O tracing_subscriber será o único sistema responsável
    // pelo logging da aplicação.
    //
    // NÃO adicionar tauri_plugin_log aqui junto com ele,
    // pois os dois tentam registrar o logger global.
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| {
                    EnvFilter::new(
                        "info,sp_smart_studio_lib=debug"
                    )
                }),
        )
        .with_target(true)
        .init();

    info!("╔══════════════════════════════════════════╗");
    info!("║   SP Smart Studio — Starting up          ║");
    info!("╚══════════════════════════════════════════╝");

    // ── GStreamer Init ────────────────────────────────────────
    gstreamer::init()
        .expect(
            "Failed to initialize GStreamer. Is it installed?"
        );

    info!(
        "GStreamer initialized: {}",
        gstreamer::version_string()
    );

    // ── Device Discovery ──────────────────────────────────────
    let discovered = discover_devices()
        .unwrap_or_else(|e| {
            tracing::warn!(
                "Device discovery failed: {} — using empty list",
                e
            );

            device_monitor::DiscoveredDevices {
                video_sinks: vec![],
                audio_sinks: vec![],
            }
        });

    // ── Tauri App ─────────────────────────────────────────────
    tauri::Builder::default()

        // IMPORTANTE:
        // tauri_plugin_log foi removido daqui.
        // Ele estava inicializando um segundo logger
        // e causando o panic da aplicação.

        .manage(
            AppState::new(discovered)
        )

        .invoke_handler(
            tauri::generate_handler![
                // Device commands
                list_video_devices,
                list_audio_devices,
                refresh_devices,

                // Pipeline commands
                start_pipeline,
                stop_pipeline,
                update_pipeline_devices,
                get_pipeline_status,
                list_pipelines,
            ]
        )

        .run(
            tauri::generate_context!()
        )

        .expect(
            "Error running SP Smart Studio"
        );
}