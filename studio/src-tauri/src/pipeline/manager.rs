// ============================================================
// SP Smart Studio — Pipeline Manager
// ============================================================
// Gerencia múltiplos pipelines GStreamer concorrentes.
// Cada reporter / canal tem seu próprio pipeline isolado.
//
// Thread-safety:
//   PipelineManager é um Arc<Mutex<Inner>> — pode ser clonado
//   e compartilhado entre o main thread e os event callbacks.
// ============================================================

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use gstreamer::{self as gst, prelude::*, MessageView};
use tokio::task;
use tracing::{error, info, warn};

use crate::{
    device_monitor::DiscoveredDevices,
    error::{StudioError, StudioResult},
    pipeline::{
        builder::build_pipeline, PipelineConfig, PipelineId, PipelineState, PipelineStatus,
        PipelineStats,
    },
};

// ─────────────────────────────────────────────────────────────
// Estrutura interna de uma entrada no manager
// ─────────────────────────────────────────────────────────────

struct PipelineEntry {
    config:        PipelineConfig,
    pipeline:      gst::Pipeline,
    state:         PipelineState,
    error_message: Option<String>,
    stats:         Option<PipelineStats>,
    /// Handle da task Tokio que monitora o bus do GStreamer
    _bus_task:     Option<task::JoinHandle<()>>,
}

impl PipelineEntry {
    fn to_status(&self) -> PipelineStatus {
        PipelineStatus {
            id:              self.config.id.clone(),
            display_name:    self.config.display_name.clone(),
            state:           self.state.clone(),
            srt_url:         self.config.srt_url.clone(),
            video_device_id: self.config.video_device_id.clone(),
            audio_device_id: self.config.audio_device_id.clone(),
            stats:           self.stats.clone(),
            error_message:   self.error_message.clone(),
        }
    }
}

// ─────────────────────────────────────────────────────────────

type SharedManager = Arc<Mutex<HashMap<PipelineId, PipelineEntry>>>;

/// Gerenciador de pipelines de decodificação.
/// Pode ser clonado (barato — é apenas Arc<Mutex<...>>).
#[derive(Clone)]
pub struct PipelineManager {
    inner: SharedManager,
}

impl PipelineManager {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    // ── Iniciar Pipeline ─────────────────────────────────────

    /// Cria e inicia um novo pipeline de decodificação.
    ///
    /// Se um pipeline com o mesmo ID já existir, retorna erro
    /// (use `update_pipeline` para alterar devices de um ativo).
    pub fn start_pipeline(
        &self,
        config: PipelineConfig,
        discovered: &DiscoveredDevices,
    ) -> StudioResult<()> {
        let id = config.id.clone();

        {
            let map = self.inner.lock().unwrap();
            if map.contains_key(&id) {
                return Err(StudioError::PipelineAlreadyExists { id });
            }
        }

        // Constrói o pipeline (pode falhar se plugins faltarem)
        let built = build_pipeline(&config, discovered)?;
        let pipeline = built.pipeline;

        // Inicia o GStreamer bus watcher em background (Tokio task)
        let bus_handle = self.spawn_bus_watcher(&pipeline, id.clone());

        // Transiciona para PLAYING
        pipeline
            .set_state(gst::State::Playing)
            .map_err(|e| StudioError::StateChange(format!("{:?}", e)))?;

        info!("Pipeline '{}' → PLAYING", id);

        let entry = PipelineEntry {
            config,
            pipeline,
            state:         PipelineState::Starting,
            error_message: None,
            stats:         None,
            _bus_task:     Some(bus_handle),
        };

        self.inner.lock().unwrap().insert(id, entry);
        Ok(())
    }

    // ── Parar Pipeline ───────────────────────────────────────

    /// Para e remove um pipeline.
    pub fn stop_pipeline(&self, id: &str) -> StudioResult<()> {
        let mut map = self.inner.lock().unwrap();
        let entry = map.remove(id).ok_or_else(|| StudioError::PipelineNotFound { id: id.into() })?;

        // Transiciona para NULL (libera recursos de hardware)
        let _ = entry.pipeline.set_state(gst::State::Null);
        info!("Pipeline '{}' → NULL (stopped)", id);
        Ok(())
    }

    // ── Trocar Dispositivos de Saída ─────────────────────────

    /// Atualiza os devices de saída de um pipeline em execução.
    /// Reconstrói o pipeline com a nova configuração de sink.
    ///
    /// Internamente:
    ///  1. Para o pipeline atual (NULL)
    ///  2. Reconstrói com o novo device_id
    ///  3. Reinicia em PLAYING
    pub fn update_pipeline_devices(
        &self,
        id: &str,
        video_device_id: Option<String>,
        audio_device_id: Option<String>,
        discovered: &DiscoveredDevices,
    ) -> StudioResult<()> {
        // Extrai config atual
        let config = {
            let map = self.inner.lock().unwrap();
            let entry = map.get(id).ok_or_else(|| StudioError::PipelineNotFound { id: id.into() })?;
            entry.config.clone()
        };

        // Para o pipeline atual
        self.stop_pipeline(id)?;

        // Reconstrói com novos devices
        let new_config = PipelineConfig {
            video_device_id,
            audio_device_id,
            ..config
        };
        self.start_pipeline(new_config, discovered)
    }

    // ── Consultas ────────────────────────────────────────────

    /// Retorna o status de um pipeline específico.
    pub fn get_status(&self, id: &str) -> StudioResult<PipelineStatus> {
        let map = self.inner.lock().unwrap();
        map.get(id)
            .map(|e| e.to_status())
            .ok_or_else(|| StudioError::PipelineNotFound { id: id.into() })
    }

    /// Retorna o status de todos os pipelines ativos.
    pub fn list_status(&self) -> Vec<PipelineStatus> {
        let map = self.inner.lock().unwrap();
        map.values().map(|e| e.to_status()).collect()
    }

    // ── Bus Watcher (monitora eventos GStreamer em background) ─

    fn spawn_bus_watcher(
        &self,
        pipeline: &gst::Pipeline,
        id: PipelineId,
    ) -> task::JoinHandle<()> {
        let bus = pipeline.bus().expect("Pipeline has no bus");
        let manager_clone = self.inner.clone();

        task::spawn_blocking(move || {
            info!("Bus watcher started for pipeline '{}'", id);

            for msg in bus.iter_timed(gst::ClockTime::NONE) {
                match msg.view() {
                    // ── Stream running ────────────────────────
                    MessageView::StreamStart(_) => {
                        info!("[{}] Stream started — pipeline RUNNING", id);
                        if let Ok(mut map) = manager_clone.lock() {
                            if let Some(entry) = map.get_mut(&id) {
                                entry.state = PipelineState::Running;
                            }
                        }
                    }

                    // ── EOS (fim do stream) ───────────────────
                    MessageView::Eos(_) => {
                        warn!("[{}] EOS received", id);
                        if let Ok(mut map) = manager_clone.lock() {
                            if let Some(entry) = map.get_mut(&id) {
                                entry.state = PipelineState::Stopped;
                            }
                        }
                        // Se auto_reconnect, tentará reconectar (Fase 3)
                        break;
                    }

                    // ── Erro fatal ────────────────────────────
                    MessageView::Error(err) => {
                        let msg = format!(
                            "{} (debug: {:?})",
                            err.error(),
                            err.debug()
                        );
                        error!("[{}] GStreamer error: {}", id, msg);
                        if let Ok(mut map) = manager_clone.lock() {
                            if let Some(entry) = map.get_mut(&id) {
                                entry.state = PipelineState::Error;
                                entry.error_message = Some(msg);
                            }
                        }
                        break;
                    }

                    // ── Warning ───────────────────────────────
                    MessageView::Warning(w) => {
                        warn!("[{}] GStreamer warning: {}", id, w.error());
                    }

                    // ── State change ──────────────────────────
                    MessageView::StateChanged(sc) => {
                        // Só nos interessa a mudança do pipeline principal
                        if msg.src().as_ref().map(|s| s.name()) ==
                           Some(id.as_str().into())
                        {
                            let new = sc.current();
                            tracing::debug!("[{}] State → {:?}", id, new);

                            if let Ok(mut map) = manager_clone.lock() {
                                if let Some(entry) = map.get_mut(&id) {
                                    entry.state = match new {
                                        gst::State::Playing => PipelineState::Running,
                                        gst::State::Paused  => PipelineState::Paused,
                                        gst::State::Null    => PipelineState::Stopped,
                                        _                   => PipelineState::Starting,
                                    };
                                }
                            }
                        }
                    }

                    // ── QoS (qualidade do decoder) ────────────
                    MessageView::Qos(qos) => {
                        // Atualiza estatísticas de dropped frames usando .value() seguro
                        let (_, dropped) = qos.stats();
                        if let Ok(mut map) = manager_clone.lock() {
                            if let Some(entry) = map.get_mut(&id) {
                                let stats = entry.stats.get_or_insert(PipelineStats {
                                    recv_bitrate_kbps:  0,
                                    rtt_ms:             0,
                                    packet_loss_percent: 0.0,
                                    decoded_fps:        0.0,
                                    dropped_frames:     0,
                                });
                                stats.dropped_frames += u64::try_from(dropped.value()).unwrap_or(0);
                            }
                        }
                    }

                    _ => {}
                }
            }

            info!("Bus watcher exited for pipeline '{}'", id);
        })
    }
}

impl Default for PipelineManager {
    fn default() -> Self { Self::new() }
}