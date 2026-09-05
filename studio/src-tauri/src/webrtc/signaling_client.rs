// ============================================================
// SP Smart Studio — WebRTC Signaling Client
// ============================================================
// Cliente WebSocket que conecta ao servidor Node.js no caminho
// /ws/studio para trocar mensagens de sinalização WebRTC.
//
// Responsabilidades:
//  1. Autenticar com STUDIO_HELLO (mesmo HMAC dos repórteres)
//  2. Receber SERVER_REPORTER_OFFER → disparar IFBPeer.answer_offer()
//  3. Enviar STUDIO_IFB_ANSWER, STUDIO_ICE_CANDIDATE
//  4. Receber SERVER_REPORTER_ICE → disparar IFBPeer.add_ice_candidate()
// ============================================================

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;
use tokio::{
    net::TcpStream,
    sync::mpsc,
    time::{sleep, Duration},
};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, http::HeaderValue, Message},
    MaybeTlsStream, WebSocketStream,
};
use tracing::{debug, error, info, warn};

use crate::{
    device_monitor::DiscoveredDevices,
    error::StudioError,
    webrtc::{
        peer::{IFBPeer, OnIceCandidateFn, OnSdpAnswerFn, OnStateFn},
        IFBConnectionState, IFBSessionConfig, IFBSessionStatus,
    },
};

type HmacSha256 = Hmac<Sha256>;

// ─────────────────────────────────────────────────────────────

/// Mensagem interna: comandos enviados para a task de WebSocket
#[derive(Debug)]
enum OutboundMsg {
    SendRaw(String),
    Disconnect,
}

// ─────────────────────────────────────────────────────────────

/// Gerencia a conexão de sinalização do Studio e todas as sessões IFB ativas.
pub struct SignalingClient {
    studio_id: String,
    auth_secret: String,
    server_url: String, // ws://host:port/ws/studio

    /// Channel para enviar mensagens ao loop WS
    outbound_tx: mpsc::UnboundedSender<OutboundMsg>,

    /// Sessões IFB ativas: reporter_id → IFBPeer
    peers: Arc<Mutex<HashMap<String, IFBPeer>>>,
}

impl SignalingClient {
    pub fn new(
        studio_id: String,
        auth_secret: String,
        server_url: String,
    ) -> (Self, mpsc::UnboundedReceiver<OutboundMsg>) {
        let (tx, rx) = mpsc::unbounded_channel::<OutboundMsg>();
        let client = Self {
            studio_id,
            auth_secret,
            server_url,
            outbound_tx: tx,
            peers: Arc::new(Mutex::new(HashMap::new())),
        };
        (client, rx)
    }

    /// Envia uma mensagem JSON para o servidor via WebSocket.
    fn send(&self, payload: Value) {
        let _ = self
            .outbound_tx
            .send(OutboundMsg::SendRaw(payload.to_string()));
    }

    /// Inicia sessão IFB com um repórter.
    ///
    /// Cria o IFBPeer e aguarda SERVER_REPORTER_OFFER do servidor
    /// (o offer chega depois que o mobile envia CLIENT_IFB_REQUEST).
    pub fn start_ifb_session(
        &self,
        config: IFBSessionConfig,
        discovered: DiscoveredDevices,
    ) -> Result<(), StudioError> {
        let reporter_id = config.reporter_id.clone();
        let peers = Arc::clone(&self.peers);
        let tx = self.outbound_tx.clone();

        // Callbacks para quando o webrtcbin gerar SDP answer e ICE candidates
        let reporter_id_for_answer = reporter_id.clone();
        let tx_for_answer = tx.clone();
        let on_sdp_answer: OnSdpAnswerFn = Box::new(move |sdp_answer| {
            let msg = json!({
                "type":             "STUDIO_IFB_ANSWER",
                "targetReporterId": reporter_id_for_answer,
                "sdpAnswer":        sdp_answer,
            });
            let _ = tx_for_answer.send(OutboundMsg::SendRaw(msg.to_string()));
        });

        let reporter_id_for_ice = reporter_id.clone();
        let tx_for_ice = tx.clone();
        let on_ice: OnIceCandidateFn = Box::new(move |mlineindex, candidate| {
            let msg = json!({
                "type":             "STUDIO_ICE_CANDIDATE",
                "targetReporterId": reporter_id_for_ice,
                "candidate": {
                    "candidate":     candidate,
                    "sdpMLineIndex": mlineindex,
                }
            });
            let _ = tx_for_ice.send(OutboundMsg::SendRaw(msg.to_string()));
        });

        let on_state: OnStateFn = Box::new(move |state| {
            info!("IFB peer state → {:?}", state);
        });

        let peer = IFBPeer::new(config, &discovered, on_sdp_answer, on_ice, on_state)?;
        peer.start()?;

        peers.lock().unwrap().insert(reporter_id, peer);
        Ok(())
    }

    /// Encerra a sessão IFB de um repórter.
    pub fn stop_ifb_session(&self, reporter_id: &str) {
        let mut peers = self.peers.lock().unwrap();
        if let Some(peer) = peers.remove(reporter_id) {
            peer.stop();
            self.send(json!({
                "type":             "STUDIO_IFB_HANGUP",
                "targetReporterId": reporter_id,
            }));
        }
    }

    /// Retorna status de todas as sessões IFB ativas.
    pub fn list_sessions(&self) -> Vec<IFBSessionStatus> {
        self.peers
            .lock()
            .unwrap()
            .values()
            .map(|p| p.status())
            .collect()
    }

    /// Gera o HMAC-SHA256 para autenticação (mesmo algoritmo do mobile).
    fn compute_auth_token(&self, timestamp: u64) -> String {
        let data = format!("{}:{}", self.studio_id, timestamp);
        let mut mac = HmacSha256::new_from_slice(self.auth_secret.as_bytes())
            .expect("HMAC accepts any key size");
        mac.update(data.as_bytes());
        hex::encode(mac.finalize().into_bytes())
    }

    /// Task principal do loop WebSocket — roda em background Tokio.
    ///
    /// Reconecta automaticamente em caso de queda.
    pub async fn run_ws_loop(
        self_arc: Arc<Self>,
        mut outbound_rx: mpsc::UnboundedReceiver<OutboundMsg>,
    ) {
        loop {
            info!("SignalingClient connecting to {}", self_arc.server_url);

            let mut request = match self_arc.server_url.as_str().into_client_request() {
                Ok(request) => request,
                Err(e) => {
                    error!("Invalid signaling URL: {}", e);
                    sleep(Duration::from_secs(5)).await;
                    continue;
                }
            };
            let bearer = match HeaderValue::from_str(&format!("Bearer {}", self_arc.auth_secret)) {
                Ok(value) => value,
                Err(_) => {
                    error!("AUTH_SECRET cannot be represented as an HTTP header");
                    sleep(Duration::from_secs(5)).await;
                    continue;
                }
            };
            request.headers_mut().insert("Authorization", bearer);

            let ws_result = connect_async(request).await;
            match ws_result {
                Err(e) => {
                    warn!("SignalingClient connection failed: {} — retry in 5s", e);
                    sleep(Duration::from_secs(5)).await;
                    continue;
                }
                Ok((ws_stream, _)) => {
                    info!("SignalingClient connected");
                    Self::handle_connection(Arc::clone(&self_arc), ws_stream, &mut outbound_rx)
                        .await;
                    warn!("SignalingClient disconnected — retry in 3s");
                    sleep(Duration::from_secs(3)).await;
                }
            }
        }
    }

    async fn handle_connection(
        client: Arc<Self>,
        ws_stream: WebSocketStream<MaybeTlsStream<TcpStream>>,
        outbound_rx: &mut mpsc::UnboundedReceiver<OutboundMsg>,
    ) {
        let (mut ws_write, mut ws_read) = ws_stream.split();

        // ── Enviar STUDIO_HELLO ───────────────────────────────
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;

        let auth_token = client.compute_auth_token(timestamp);
        let hello = json!({
            "type":      "STUDIO_HELLO",
            "studioId":  client.studio_id,
            "authToken": auth_token,
            "timestamp": timestamp,
            "capabilities": {
                "webrtc":        true,
                "ndi":           true,
                "audioCapture":  true,
            }
        });

        if ws_write
            .send(Message::Text(hello.to_string()))
            .await
            .is_err()
        {
            error!("Failed to send STUDIO_HELLO");
            return;
        }

        // ── Loop de mensagens ─────────────────────────────────
        loop {
            tokio::select! {
                // Mensagem inbound do servidor
                inbound = ws_read.next() => {
                    match inbound {
                        None => { info!("WS stream ended"); break; }
                        Some(Err(e)) => { warn!("WS read error: {}", e); break; }
                        Some(Ok(Message::Text(text))) => {
                            client.handle_server_message(&text, &mut ws_write).await;
                        }
                        Some(Ok(Message::Ping(data))) => {
                            let _ = ws_write.send(Message::Pong(data)).await;
                        }
                        Some(Ok(Message::Close(_))) => { info!("Server closed"); break; }
                        _ => {}
                    }
                }

                // Mensagem outbound da app
                outbound = outbound_rx.recv() => {
                    match outbound {
                        None => { info!("Outbound channel closed"); break; }
                        Some(OutboundMsg::Disconnect) => { break; }
                        Some(OutboundMsg::SendRaw(text)) => {
                            if ws_write.send(Message::Text(text)).await.is_err() {
                                warn!("Failed to send WS message — reconnecting");
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    /// Processa uma mensagem JSON recebida do servidor.
    async fn handle_server_message(
        &self,
        text: &str,
        _ws_sink: &mut (impl SinkExt<Message, Error = impl std::fmt::Debug> + Unpin),
    ) {
        let Ok(v) = serde_json::from_str::<Value>(text) else {
            warn!(
                "SignalingClient: invalid JSON from server: {}",
                &text[..text.len().min(80)]
            );
            return;
        };

        let msg_type = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
        debug!("SignalingClient received: {}", msg_type);

        match msg_type {
            "SERVER_STUDIO_WELCOME" => {
                info!(
                    "Studio authenticated with server: sessionId={:?}",
                    v.get("sessionId")
                );
            }

            // Servidor encaminhou o SDP offer de um repórter
            "SERVER_REPORTER_OFFER" => {
                let reporter_id = v["reporterId"].as_str().unwrap_or("").to_string();
                let sdp_offer = v["sdpOffer"].as_str().unwrap_or("").to_string();
                info!("Received SDP offer from reporter '{}'", reporter_id);

                let peers = self.peers.lock().unwrap();
                if let Some(peer) = peers.get(&reporter_id) {
                    let tx = self.outbound_tx.clone();
                    let rid = reporter_id.clone();

                    let on_answer: OnSdpAnswerFn = Box::new(move |sdp_answer| {
                        let msg = json!({
                            "type":             "STUDIO_IFB_ANSWER",
                            "targetReporterId": rid,
                            "sdpAnswer":        sdp_answer,
                        });
                        let _ = tx.send(OutboundMsg::SendRaw(msg.to_string()));
                    });

                    if let Err(e) = peer.answer_offer(sdp_offer, on_answer) {
                        error!("Failed to answer SDP offer for '{}': {}", reporter_id, e);
                    }
                } else {
                    warn!(
                        "No IFB session found for reporter '{}' — offer ignored. \
                         Call start_ifb_session() first.",
                        reporter_id
                    );
                }
            }

            // Candidato ICE do reporter → adiciona ao peer
            "SERVER_REPORTER_ICE" => {
                let reporter_id = v["reporterId"].as_str().unwrap_or("");
                if let Some(candidate_obj) = v.get("candidate") {
                    let candidate = candidate_obj["candidate"].as_str().unwrap_or("");
                    let mlineindex = candidate_obj["sdpMLineIndex"].as_u64().unwrap_or(0) as u32;

                    let peers = self.peers.lock().unwrap();
                    if let Some(peer) = peers.get(reporter_id) {
                        peer.add_ice_candidate(mlineindex, candidate);
                    }
                }
            }

            "SERVER_REPORTER_LEFT" => {
                let reporter_id = v["reporterId"].as_str().unwrap_or("");
                info!("Reporter '{}' left — cleaning up IFB session", reporter_id);
                let mut peers = self.peers.lock().unwrap();
                if let Some(peer) = peers.remove(reporter_id) {
                    peer.stop();
                }
            }

            "SERVER_PING" => {} // Handled at WS level (Pong sent automatically)

            _ => {
                debug!("Unhandled server message type: '{}'", msg_type);
            }
        }
    }
}
