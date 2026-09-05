// ============================================================
// SP Smart Studio — Dynamic Pipeline Builder
// ============================================================
//
// Constrói o pipeline GStreamer:
//
//   srtsrc → tsdemux ┬→ h265parse → [HW/SW decoder] → videoconvert → [video_sink]
//                    └→ [audio_parser] → [audio_decoder] → audioconvert → [audio_sink]
//
// O decoder de vídeo é selecionado automaticamente:
//   1. vaapih265dec   (Intel/AMD via VAAPI — Linux)
//   2. nvh265dec      (NVIDIA NVDEC — Linux/Windows)
//   3. d3d11h265dec   (DirectX 11 — Windows)
//   4. vtdec          (VideoToolbox — macOS)
//   5. avdec_h265     (libav software — fallback universal)
//
// O "sink" de vídeo e áudio é instanciado dinamicamente pelo
// DeviceMonitor a partir do device_id selecionado pelo operador.
// ============================================================

use gstreamer::{self as gst, prelude::*};
use gstreamer_video as gst_video;
use tracing::{debug, info, warn};

use crate::{
    device_monitor::{create_element_for_device, DiscoveredDevices},
    error::{StudioError, StudioResult},
    pipeline::PipelineConfig,
};

// ── Candidatos de decoder (ordem de preferência) ─────────────
const HEVC_DECODER_CANDIDATES: &[&str] = &[
    "nvh265dec",      // NVIDIA NVDEC (melhor performance)
    "d3d11h265dec",   // DirectX 11 (Windows — placa genérica)
    "vaapih265dec",   // VAAPI (Intel Quick Sync / AMD VCE — Linux)
    "vtdec",          // VideoToolbox (macOS)
    "avdec_h265",     // libav software (fallback universal)
];

/// Resultado da construção de um pipeline.
pub struct BuiltPipeline {
    pub pipeline: gst::Pipeline,
}

// ─────────────────────────────────────────────────────────────

/// Constrói o pipeline GStreamer completo de forma dinâmica.
///
/// Nenhum elemento de sink é hardcoded. Os sinks de vídeo e áudio
/// são criados a partir dos device_ids selecionados pelo operador.
pub fn build_pipeline(
    config: &PipelineConfig,
    discovered: &DiscoveredDevices,
) -> StudioResult<BuiltPipeline> {
    info!(
        "Building pipeline '{}' | SRT: {} | video_device={:?} | audio_device={:?}",
        config.id,
        config.srt_url,
        config.video_device_id,
        config.audio_device_id,
    );

    // ── 1. Cria pipeline container ────────────────────────────
    let pipeline = gst::Pipeline::with_name(&config.id);

    // ── 2. SRT Source ─────────────────────────────────────────
    let srtsrc = make_element("srtsrc", &format!("srtsrc_{}", config.id))?;
    srtsrc.set_property("uri", &config.srt_url);
    srtsrc.set_property("latency", config.srt_latency_ms as i32);
    // Buffer local para absorver variações de rede (jitter)
    srtsrc.set_property("recv-buffer-size", 1024 * 1024i32); // 1 MB

    // ── 3. MPEG-TS Demuxer ────────────────────────────────────
    // tsdemux não pode ser linkado estaticamente (pads dinâmicos)
    let tsdemux = make_element("tsdemux", &format!("demux_{}", config.id))?;

    // ── 4. Filas (evitam bloqueio entre threads do pipeline) ──
    let video_queue = make_element("queue2", &format!("vqueue_{}", config.id))?;
    video_queue.set_property("max-size-time", 2_000_000_000u64); // 2s buffer
    video_queue.set_property("max-size-bytes", 8 * 1024 * 1024u32);

    let audio_queue = make_element("queue2", &format!("aqueue_{}", config.id))?;
    audio_queue.set_property("max-size-time", 2_000_000_000u64);

    // ── 5. Parsers ────────────────────────────────────────────
    let h265parse  = make_element("h265parse", &format!("h265parse_{}", config.id))?;
    // Passa SPS/PPS inline nos pacotes para facilitar decoders de HW
    h265parse.set_property_from_str("config-interval", "-1");

    // Parser de áudio — tenta AAC primeiro, depois AC3/MP2
    let audio_parse = make_best_audio_parser(config)?;

    // ── 6. Decoder de Vídeo (auto-seleção HW→SW) ─────────────
    let video_decoder = select_best_hevc_decoder(&format!("vdec_{}", config.id))?;
    info!("Selected HEVC decoder: {}", video_decoder.factory_name_of_element());

    // ── 7. Decoder de Áudio ───────────────────────────────────
    let audio_decoder = make_best_audio_decoder(config)?;

    // ── 8. Conversores (normalizam colorspace/sample rate) ────
    let videoconvert  = make_element("videoconvert",  &format!("vconv_{}", config.id))?;
    let videoscale    = make_element("videoscale",    &format!("vscale_{}", config.id))?;
    let audioconvert  = make_element("audioconvert",  &format!("aconv_{}", config.id))?;
    let audioresample = make_element("audioresample", &format!("aresample_{}", config.id))?;

    // ── 9. Sinks Dinâmicos ────────────────────────────────────
    let video_sink_elem = build_video_sink(config, discovered)?;
    let audio_sink_elem = build_audio_sink(config, discovered)?;

    // ── 10. Adiciona todos os elementos ao pipeline ───────────
    let video_elements: &[&gst::Element] = &[
        &srtsrc, &tsdemux,
        &video_queue, &h265parse, &video_decoder,
        &videoconvert, &videoscale, &video_sink_elem,
    ];
    let audio_elements: &[&gst::Element] = &[
        &audio_queue, &audio_parse, &audio_decoder,
        &audioconvert, &audioresample, &audio_sink_elem,
    ];

    for elem in video_elements.iter().chain(audio_elements) {
        pipeline
            .add(*elem)
            .map_err(|_| StudioError::Gst(format!("Failed to add '{}' to pipeline", elem.name())))?;
    }

    // ── 11. Linka a cadeia estática de vídeo (exceto tsdemux) ─
    gst::Element::link_many(&[
        &h265parse, &video_decoder, &videoconvert, &videoscale, &video_sink_elem,
    ])
    .map_err(|_| StudioError::ElementLink("video decode chain".into()))?;

    // Insere video_queue antes de h265parse (a ser linkado via pad-added)
    video_queue
        .link(&h265parse)
        .map_err(|_| StudioError::ElementLink("video_queue → h265parse".into()))?;

    // ── 12. Linka a cadeia de áudio (exceto tsdemux) ──────────
    gst::Element::link_many(&[
        &audio_queue, &audio_parse, &audio_decoder,
        &audioconvert, &audioresample, &audio_sink_elem,
    ])
    .map_err(|_| StudioError::ElementLink("audio decode chain".into()))?;

    // ── 13. SRT → tsdemux (link simples) ─────────────────────
    srtsrc
        .link(&tsdemux)
        .map_err(|_| StudioError::ElementLink("srtsrc → tsdemux".into()))?;

    // ── 14. tsdemux: pad-added (pads criados dinamicamente) ───
    // O tsdemux cria um pad para cada stream encontrada no TS.
    // Precisamos conectar esses pads ao video_queue e audio_queue.
    let video_queue_sink = video_queue
        .static_pad("sink")
        .ok_or_else(|| StudioError::Gst("video_queue has no sink pad".into()))?;
    let audio_queue_sink = audio_queue
        .static_pad("sink")
        .ok_or_else(|| StudioError::Gst("audio_queue has no sink pad".into()))?;

    tsdemux.connect_pad_added(move |_demux, src_pad| {
        let caps = src_pad.current_caps().unwrap_or_else(|| src_pad.query_caps(None));
        let structure = match caps.structure(0) {
            Some(s) => s,
            None    => return,
        };
        let name = structure.name().as_str();

        debug!("tsdemux pad-added: name='{}' caps='{:?}'", src_pad.name(), caps);

        if name.starts_with("video/x-h265") || name.starts_with("video/") {
            if !video_queue_sink.is_linked() {
                if let Err(e) = src_pad.link(&video_queue_sink) {
                    warn!("Failed to link video pad: {:?}", e);
                } else {
                    info!("Linked video stream → video_queue");
                }
            }
        } else if name.starts_with("audio/") {
            if !audio_queue_sink.is_linked() {
                if let Err(e) = src_pad.link(&audio_queue_sink) {
                    warn!("Failed to link audio pad: {:?}", e);
                } else {
                    info!("Linked audio stream → audio_queue");
                }
            }
        }
    });

    info!("Pipeline '{}' built successfully", config.id);
    Ok(BuiltPipeline { pipeline })
}

// ─────────────────────────────────────────────────────────────
// Builders de sink dinâmico
// ─────────────────────────────────────────────────────────────

/// Instancia o video sink selecionado pelo operador.
/// Se nenhum device_id for fornecido, usa autovideosink como fallback.
fn build_video_sink(
    config: &PipelineConfig,
    discovered: &DiscoveredDevices,
) -> StudioResult<gst::Element> {
    let elem_name = format!("vsink_{}", config.id);

    match &config.video_device_id {
        Some(device_id) => {
            info!("Creating video sink from device_id='{}'", device_id);
            create_element_for_device(device_id, discovered, &elem_name)
        }
        None => {
            warn!("No video device selected for '{}' — using autovideosink", config.id);
            make_element("autovideosink", &elem_name)
        }
    }
}

/// Instancia o audio sink selecionado pelo operador.
fn build_audio_sink(
    config: &PipelineConfig,
    discovered: &DiscoveredDevices,
) -> StudioResult<gst::Element> {
    let elem_name = format!("asink_{}", config.id);

    match &config.audio_device_id {
        Some(device_id) => {
            info!("Creating audio sink from device_id='{}'", device_id);
            create_element_for_device(device_id, discovered, &elem_name)
        }
        None => {
            warn!("No audio device selected for '{}' — using autoaudiosink", config.id);
            make_element("autoaudiosink", &elem_name)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// Seleção automática de decoders
// ─────────────────────────────────────────────────────────────

/// Seleciona o melhor decoder HEVC disponível no sistema.
/// Ordem: NVDEC > D3D11 > VAAPI > VideoToolbox > libav software.
fn select_best_hevc_decoder(element_name: &str) -> StudioResult<gst::Element> {
    for &candidate in HEVC_DECODER_CANDIDATES {
        if gst::ElementFactory::find(candidate).is_some() {
            debug!("HEVC decoder candidate available: '{}'", candidate);
            match make_element(candidate, element_name) {
                Ok(elem) => {
                    info!("Using HEVC decoder: '{}'", candidate);
                    return Ok(elem);
                }
                Err(e) => {
                    warn!("Failed to create '{}': {:?}", candidate, e);
                    continue;
                }
            }
        }
    }
    Err(StudioError::Gst(
        "No HEVC decoder available. Install GStreamer libav or a hardware decoder plugin.".into(),
    ))
}

/// Seleciona o melhor parser de áudio baseado no conteúdo esperado.
/// Para transmissões broadcast, AAC é o mais comum.
fn make_best_audio_parser(config: &PipelineConfig) -> StudioResult<gst::Element> {
    let parsers = ["aacparse", "ac3parse", "mpegaudioparse"];
    for &p in &parsers {
        if gst::ElementFactory::find(p).is_some() {
            return make_element(p, &format!("aparse_{}", config.id));
        }
    }
    // Fallback genérico
    make_element("identity", &format!("aparse_{}", config.id))
}

/// Seleciona o melhor decoder de áudio disponível.
fn make_best_audio_decoder(config: &PipelineConfig) -> StudioResult<gst::Element> {
    let decoders = ["avdec_aac", "faad", "avdec_ac3", "avdec_mp3"];
    for &d in &decoders {
        if gst::ElementFactory::find(d).is_some() {
            return make_element(d, &format!("adec_{}", config.id));
        }
    }
    Err(StudioError::Gst(
        "No audio decoder available. Install GStreamer libav plugin.".into(),
    ))
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

/// Cria um elemento GStreamer pelo nome da factory.
/// Wrapper ergonômico que converte a falha para StudioError.
fn make_element(factory: &str, name: &str) -> StudioResult<gst::Element> {
    gst::ElementFactory::make(factory)
        .name(name)
        .build()
        .map_err(|_| StudioError::ElementCreate { name: factory.into() })
}

/// Obtém o nome da factory que criou um elemento.
trait ElementFactoryName {
    fn factory_name_of_element(&self) -> String;
}

impl ElementFactoryName for gst::Element {
    fn factory_name_of_element(&self) -> String {
        self.factory()
            .map(|f| f.name().to_string())
            .unwrap_or_else(|| "unknown".into())
    }
}
