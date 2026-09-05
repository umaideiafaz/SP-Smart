// ============================================================
// SP Smart Studio — WebRTC Peer (GStreamer webrtcbin)
// ============================================================
//
// Usa o elemento `webrtcbin` do GStreamer (gst-plugins-bad)
// para implementar o lado Studio da sessão WebRTC de IFB.
//
// Pipeline de envio (Studio → Mobile):
//
//   [Audio Src Device] → audioconvert → audioresample
//     → opusenc (stereo, bitrate 128k) → rtpopuspay → webrtcbin
//
//   [Video Src Device] → videoconvert → videoscale → videorate
//     → vp8enc (bitrate configurável) → rtpvp8pay → webrtcbin
//
// O `webrtcbin` negocia DTLS-SRTP, STUN/TURN e ICE automaticamente.
//
// Referência: gstreamer.freedesktop.org/documentation/webrtc
// ============================================================

use std::sync::{Arc, Mutex};
use gstreamer::{self as gst, prelude::*};
use gstreamer_webrtc as gst_webrtc;
use tracing::{debug, error, info, warn};

use crate::{
    device_monitor::DiscoveredDevices,
    error::{StudioError, StudioResult},
    webrtc::{IFBConnectionState, IFBSessionConfig, IFBSessionStatus},
};

// ── Candidatos de encoder de vídeo ────────────────────────────
// VP8 tem melhor suporte WebRTC; H264 é aceito por mais hardware.
const VIDEO_ENCODER_CANDIDATES: &[&str] = &[
    "nvh264enc",   // NVIDIA NVENC (baixa latência)
    "d3d11h264enc",// DirectX 11
    "vp8enc",      // libvpx — fallback universal (melhor compatibilidade WebRTC)
];

const STUN_SERVER: &str = "stun://stun.l.google.com:19302";

// ─────────────────────────────────────────────────────────────

/// Callback chamado quando um SDP answer é criado pelo webrtcbin.
pub type OnSdpAnswerFn = Box<dyn Fn(String) + Send + Sync + 'static>;

/// Callback chamado quando um ICE candidate é gerado.
pub type OnIceCandidateFn = Box<dyn Fn(u32, String) + Send + Sync + 'static>;

/// Callback chamado quando o estado da conexão muda.
pub type OnStateFn = Box<dyn Fn(IFBConnectionState) + Send + Sync + 'static>;

// ─────────────────────────────────────────────────────────────

pub struct IFBPeer {
    config:   IFBSessionConfig,
    pipeline: gst::Pipeline,
    webrtc:   gst::Element,
    state:    Arc<Mutex<IFBConnectionState>>,
}

impl IFBPeer {
    /// Cria e inicializa o pipeline WebRTC para uma sessão IFB.
    ///
    /// `on_sdp_answer` — chamado quando o webrtcbin cria o SDP answer
    /// `on_ice`        — chamado para cada ICE candidate gerado
    /// `on_state`      — chamado em mudanças de estado da conexão
    pub fn new(
        config:        IFBSessionConfig,
        discovered:    &DiscoveredDevices,
        on_sdp_answer: OnSdpAnswerFn,
        on_ice:        OnIceCandidateFn,
        on_state:      OnStateFn,
    ) -> StudioResult<Self> {
        info!(
            "Creating IFB WebRTC peer for reporter '{}' | audio={:?} video={:?}",
            config.reporter_id, config.audio_device_id, config.video_device_id,
        );

        let pipeline_name = format!("ifb-{}", config.reporter_id);
        let pipeline = gst::Pipeline::with_name(&pipeline_name);

        // ── webrtcbin ─────────────────────────────────────────
        let webrtc = make_element("webrtcbin", &format!("webrtc-{}", config.reporter_id))?;
        webrtc.set_property("stun-server", STUN_SERVER);
        // bundle-policy=max-bundle: audio+video share one DTLS connection
        webrtc.set_property_from_str("bundle-policy", "max-bundle");
        pipeline
            .add(&webrtc)
            .map_err(|_| StudioError::Gst("Cannot add webrtcbin to pipeline".into()))?;

        let state = Arc::new(Mutex::new(IFBConnectionState::Signaling));

        // ── Audio pipeline ────────────────────────────────────
        if let Some(audio_src) = build_audio_src_chain(
            &config,
            discovered,
            &pipeline,
            &webrtc,
        )? {
            info!("Audio capture chain attached for '{}'", config.reporter_id);
            let _ = audio_src; // ownership moved into pipeline
        }

        // ── Video pipeline ────────────────────────────────────
        if let Some(video_src) = build_video_src_chain(
            &config,
            discovered,
            &pipeline,
            &webrtc,
        )? {
            info!("Video capture chain attached for '{}'", config.reporter_id);
            let _ = video_src;
        }

        // ── Callbacks do webrtcbin ────────────────────────────

        // on-negotiation-needed — disparado quando o webrtcbin quer criar uma offer
        // Neste flow (mobile faz offer), não usamos este callback.
        // Mas conectamos para debug:
        webrtc.connect("on-negotiation-needed", false, move |_| {
            debug!("webrtcbin: on-negotiation-needed (Studio is answering, not offering)");
            None
        });

        // on-ice-candidate — envia candidatos ao signaling server
        let on_ice_clone = Arc::new(on_ice);
        let on_ice_for_signal = Arc::clone(&on_ice_clone);
        webrtc.connect("on-ice-candidate", false, move |values| {
            let mlineindex = values[1].get::<u32>().unwrap_or(0);
            let candidate  = values[2].get::<String>().unwrap_or_default();
            debug!("ICE candidate generated: mline={} cand={}", mlineindex, &candidate[..candidate.len().min(40)]);
            on_ice_for_signal(mlineindex, candidate);
            None
        });

        // notify::connection-state — monitora o estado ICE
        let state_clone  = Arc::clone(&state);
        let on_state_arc = Arc::new(on_state);
        webrtc.connect_notify(Some("connection-state"), move |webrtc, _pspec| {
            use gstreamer_webrtc::WebRTCPeerConnectionState;
            let conn_state: WebRTCPeerConnectionState = webrtc
                .property("connection-state");
            let new_state = match conn_state {
                WebRTCPeerConnectionState::Connected    => IFBConnectionState::Connected,
                WebRTCPeerConnectionState::Disconnected => IFBConnectionState::Closed,
                WebRTCPeerConnectionState::Failed       => IFBConnectionState::Error,
                WebRTCPeerConnectionState::Closed       => IFBConnectionState::Closed,
                WebRTCPeerConnectionState::Connecting   => IFBConnectionState::Connecting,
                _                                       => IFBConnectionState::Signaling,
            };
            info!("WebRTC connection-state → {:?}", new_state);
            *state_clone.lock().unwrap() = new_state.clone();
            on_state_arc(new_state);
        });

        // ── Armazena referência ao on_sdp_answer ──────────────
        // Será chamado em set_remote_description() após criar o answer.
        let _ = on_sdp_answer; // stored via closure in answer_offer()

        Ok(Self { config, pipeline, webrtc, state })
    }

    /// Aplica o SDP offer do mobile e cria o SDP answer.
    ///
    /// Deve ser chamado quando o servidor encaminha o offer do repórter.
    pub fn answer_offer(
        &self,
        sdp_offer_str: String,
        on_sdp_answer: OnSdpAnswerFn,
    ) -> StudioResult<()> {
        let sdp = gst_webrtc::WebRTCSessionDescription::new(
            gst_webrtc::WebRTCSDPType::Offer,
            gst_sdp::SDPMessage::parse_buffer(sdp_offer_str.as_bytes())
                .map_err(|_| StudioError::Gst("Invalid SDP offer".into()))?,
        );

        let webrtc_clone = self.webrtc.clone();

        // 1. set-remote-description (offer do mobile)
        self.webrtc.emit_by_name::<()>(
            "set-remote-description",
            &[&sdp, &None::<gst::Promise>],
        );

        // 2. Cria o answer via promise
        let promise = gst::Promise::with_change_func(move |reply| {
            let reply = match reply {
                Ok(Some(s)) => s,
                Ok(None) => {
                    warn!("create-answer returned empty structure");
                    return;
                }
                Err(e) => {
                    error!("create-answer failed: {:?}", e);
                    return;
                }
            };

            let answer: gst_webrtc::WebRTCSessionDescription = match reply.get("answer") {
                Ok(v) => v,
                Err(e) => {
                    error!("Cannot get 'answer' from SDP reply: {:?}", e);
                    return;
                }
            };

            // Aplica o answer localmente
            webrtc_clone.emit_by_name::<()>(
                "set-local-description",
                &[&answer, &None::<gst::Promise>],
            );

            // Extrai o SDP como string
            let sdp_str = answer.sdp().as_text().unwrap_or_default().to_string();
            info!("SDP answer created ({} bytes)", sdp_str.len());
            on_sdp_answer(sdp_str);
        });

        self.webrtc.emit_by_name::<()>("create-answer", &[&None::<gst::Structure>, &promise]);
        Ok(())
    }

    /// Adiciona um ICE candidate recebido do mobile.
    pub fn add_ice_candidate(&self, mlineindex: u32, candidate: &str) {
        debug!("Adding ICE candidate: mline={} cand={}", mlineindex, &candidate[..candidate.len().min(40)]);
        self.webrtc.emit_by_name::<()>(
            "add-ice-candidate",
            &[&mlineindex, &candidate],
        );
    }

    /// Inicia o pipeline (GStreamer → PLAYING).
    pub fn start(&self) -> StudioResult<()> {
        self.pipeline
            .set_state(gst::State::Playing)
            .map_err(|e| StudioError::StateChange(format!("{:?}", e)))?;
        info!("IFB pipeline '{}' → PLAYING", self.config.reporter_id);
        Ok(())
    }

    /// Para e destrói o pipeline.
    pub fn stop(&self) {
        let _ = self.pipeline.set_state(gst::State::Null);
        info!("IFB pipeline '{}' → NULL", self.config.reporter_id);
    }

    pub fn status(&self) -> IFBSessionStatus {
        IFBSessionStatus {
            reporter_id:   self.config.reporter_id.clone(),
            state:         self.state.lock().unwrap().clone(),
            audio_source:  self.config.audio_device_id.clone(),
            video_source:  self.config.video_device_id.clone(),
            error_message: None,
        }
    }
}

// ─────────────────────────────────────────────────────────────
// Pipeline builders
// ─────────────────────────────────────────────────────────────

/// Constrói a cadeia de captura e encoding de áudio.
///
/// Cadeia: [audio src device] → audioconvert → audioresample
///           → opusenc (stereo, CBR) → rtpopuspay → webrtcbin.sink_X
///
/// CRÍTICO: opusenc é configurado para SEMPRE saída estéreo.
/// O SDP resultante terá:  a=fmtp:111 stereo=1;sprop-stereo=1
fn build_audio_src_chain(
    config:     &IFBSessionConfig,
    discovered: &DiscoveredDevices,
    pipeline:   &gst::Pipeline,
    webrtc:     &gst::Element,
) -> StudioResult<Option<()>> {
    let audio_src = match &config.audio_device_id {
        Some(device_id) => {
            // Usa o dispositivo de captura de áudio selecionado (linha de entrada / Mix-Minus)
            create_audio_source_element(device_id, discovered)?
        }
        None => {
            warn!("No audio device selected for IFB — using autoaudiosrc as fallback");
            make_element("autoaudiosrc", "ifb-audio-src")?
        }
    };

    // Configurações de captura para Mix-Minus:
    // 2 canais (L: PGM+Dir.Jornalismo / R: PGM+Dir.TV)
    // Rate 48kHz (padrão broadcast e Opus)
    let audio_caps = gst::Caps::builder("audio/x-raw")
        .field("channels", 2i32)       // STEREO — nunca downmix
        .field("rate", 48000i32)
        .field("format", "S16LE")
        .build();

    let audio_capsfilter = make_element("capsfilter", "audio-caps")?;
    audio_capsfilter.set_property("caps", &audio_caps);

    let audioconvert  = make_element("audioconvert",  "audio-convert")?;
    let audioresample = make_element("audioresample",  "audio-resample")?;

    // Opus encoder — STEREO obrigatório para preservar L/R do Mix-Minus
    let opusenc = make_element("opusenc", "opus-enc")?;
    opusenc.set_property("bitrate",  128_000i32);  // 128 kbps para broadcast
    opusenc.set_property_from_str("audio-type", "restricted-lowdelay");
    opusenc.set_property("bandwidth", -1000i32);   // FULLBAND
    // dtx=false: desativa DTX para garantir stream contínuo (critical for IFB)
    opusenc.set_property("dtx", false);

    // RTP packetizer para Opus
    let rtpopuspay = make_element("rtpopuspay", "rtp-opus-pay")?;
    rtpopuspay.set_property("pt", 111u32);

    let elements: &[&gst::Element] = &[
        &audio_src, &audio_capsfilter, &audioconvert, &audioresample, &opusenc, &rtpopuspay,
    ];

    for elem in elements {
        pipeline.add(*elem)
            .map_err(|_| StudioError::Gst(format!("Cannot add '{}' to IFB pipeline", elem.name())))?;
    }

    gst::Element::link_many(&[
        &audio_src, &audio_capsfilter, &audioconvert, &audioresample, &opusenc, &rtpopuspay,
    ]).map_err(|_| StudioError::ElementLink("audio chain".into()))?;

    // Conecta rtpopuspay → webrtcbin (pad request)
    let rtp_src_pad = rtpopuspay
        .static_pad("src")
        .ok_or_else(|| StudioError::Gst("rtpopuspay has no src pad".into()))?;

    let webrtc_sink_pad = webrtc
        .request_pad_simple("sink_%u")
        .ok_or_else(|| StudioError::Gst("webrtcbin: cannot request audio sink pad".into()))?;

    rtp_src_pad
        .link(&webrtc_sink_pad)
        .map_err(|_| StudioError::ElementLink("rtpopuspay → webrtcbin".into()))?;

    info!("Audio chain: src → audioconvert → opusenc(stereo, 128kbps) → webrtcbin");
    Ok(Some(()))
}

/// Constrói a cadeia de captura e encoding de vídeo de retorno.
///
/// Cadeia: [video src device] → videoconvert → videoscale → videorate
///           → [encoder] → [rtppay] → webrtcbin.sink_X
///
/// O vídeo de retorno é intencionalmente de baixa resolução/bitrate
/// (640×360 @ 800kbps) para minimizar o uso de banda ascendente do celular.
fn build_video_src_chain(
    config:     &IFBSessionConfig,
    discovered: &DiscoveredDevices,
    pipeline:   &gst::Pipeline,
    webrtc:     &gst::Element,
) -> StudioResult<Option<()>> {
    let video_src = match &config.video_device_id {
        Some(device_id) => create_video_source_element(device_id, discovered)?,
        None => {
            warn!("No video device for IFB return — skipping video track");
            return Ok(None);
        }
    };

    let video_caps = gst::Caps::builder("video/x-raw")
        .field("width",  config.video_width as i32)
        .field("height", config.video_height as i32)
        .field("framerate", gst::Fraction::new(30, 1))
        .build();

    let video_capsfilter = make_element("capsfilter", "video-caps")?;
    video_capsfilter.set_property("caps", &video_caps);

    let videoconvert  = make_element("videoconvert",  "video-convert")?;
    let videoscale    = make_element("videoscale",    "video-scale")?;
    let videorate     = make_element("videorate",     "video-rate")?;

    // Seleção automática do encoder (HW preferido → VP8 fallback)
    let (encoder, rtppay, pt) = select_video_encoder(config)?;
    let pt_u32 = pt as u32;

    let elements: &[&gst::Element] = &[
        &video_src, &video_capsfilter, &videoconvert, &videoscale, &videorate, &encoder, &rtppay,
    ];
    for elem in elements {
        pipeline.add(*elem)
            .map_err(|_| StudioError::Gst(format!("Cannot add '{}' to IFB pipeline", elem.name())))?;
    }

    gst::Element::link_many(&[
        &video_src, &video_capsfilter, &videoconvert, &videoscale, &videorate, &encoder, &rtppay,
    ]).map_err(|_| StudioError::ElementLink("video chain".into()))?;

    let rtp_src_pad = rtppay
        .static_pad("src")
        .ok_or_else(|| StudioError::Gst("rtppay has no src pad".into()))?;

    let webrtc_sink_pad = webrtc
        .request_pad_simple("sink_%u")
        .ok_or_else(|| StudioError::Gst("webrtcbin: cannot request video sink pad".into()))?;

    rtp_src_pad
        .link(&webrtc_sink_pad)
        .map_err(|_| StudioError::ElementLink("rtppay → webrtcbin".into()))?;

    info!(
        "Video chain: src({}x{}@30fps) → {} → webrtcbin [pt={}]",
        config.video_width, config.video_height,
        encoder.factory_name_of_element(), pt_u32,
    );
    Ok(Some(()))
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

fn select_video_encoder(
    config: &IFBSessionConfig,
) -> StudioResult<(gst::Element, gst::Element, u32)> {
    for &candidate in VIDEO_ENCODER_CANDIDATES {
        if gst::ElementFactory::find(candidate).is_none() { continue; }
        match candidate {
            "nvh264enc" | "d3d11h264enc" => {
                let enc = make_element(candidate, "video-enc")?;
                enc.set_property("bitrate", config.video_bitrate_kbps);
                // Zero-latency preset for live broadcast
                if enc.has_property("zerolatency", Some(bool::static_type())) {
                    enc.set_property("zerolatency", true);
                }
                let pay = make_element("rtph264pay", "rtp-pay")?;
                pay.set_property("pt", 96u32);
                pay.set_property_from_str("aggregate-mode", "zero-latency");
                return Ok((enc, pay, 96));
            }
            "vp8enc" => {
                let enc = make_element("vp8enc", "video-enc")?;
                enc.set_property("target-bitrate", (config.video_bitrate_kbps * 1000) as i32);
                enc.set_property("deadline", 1i64); // 1µs = realtime
                enc.set_property_from_str("error-resilient", "default");
                let pay = make_element("rtpvp8pay", "rtp-pay")?;
                pay.set_property("pt", 97u32);
                return Ok((enc, pay, 97));
            }
            _ => {}
        }
    }
    Err(StudioError::Gst(
        "No suitable WebRTC video encoder found (nvh264enc, d3d11h264enc, or vp8enc)".into()
    ))
}

fn create_audio_source_element(
    device_id:  &str,
    discovered: &DiscoveredDevices,
) -> StudioResult<gst::Element> {
    use crate::device_monitor::create_element_for_device;
    create_element_for_device(device_id, discovered, "ifb-audio-src-phys")
}

fn create_video_source_element(
    device_id:  &str,
    discovered: &DiscoveredDevices,
) -> StudioResult<gst::Element> {
    use crate::device_monitor::create_element_for_device;
    create_element_for_device(device_id, discovered, "ifb-video-src-phys")
}

fn make_element(factory: &str, name: &str) -> StudioResult<gst::Element> {
    gst::ElementFactory::make(factory)
        .name(name)
        .build()
        .map_err(|_| StudioError::ElementCreate { name: factory.into() })
}

trait ElementFactoryName {
    fn factory_name_of_element(&self) -> String;
}

impl ElementFactoryName for gst::Element {
    fn factory_name_of_element(&self) -> String {
        self.factory().map(|f| f.name().to_string()).unwrap_or_else(|| "unknown".into())
    }
}
