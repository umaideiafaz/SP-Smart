// ============================================================
// SP Smart Studio — Video Source Device Discovery
// ============================================================
// Descobre os dispositivos de CAPTURA de vídeo disponíveis:
//   • Fontes NDI (ndisrc — gst-plugins-rs/ndi)
//   • Placas DeckLink em modo captura (decklinkvideosrc)
//   • AJA em modo captura (ajavideosrc)
//   • Dispositivos V4L2 / DirectShow genéricos
//   • autovideosrc (fallback do SO)
//
// PROPÓSITO: O operador seleciona qual fonte de vídeo (ex: PGM limpo
// via NDI do switcher) será enviada como retorno de vídeo para o repórter.
// ============================================================

use gstreamer::{self as gst, prelude::*, DeviceMonitor};
use serde::{Deserialize, Serialize};
use tracing::{debug, info, warn};

use crate::error::StudioResult;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VideoSourceDevice {
    pub id:           String,
    pub display_name: String,
    pub element_type: String,
    pub gst_class:    String,
    pub properties:   std::collections::HashMap<String, String>,
    pub is_ndi:       bool,
    pub is_default:   bool,
}

fn make_device_id(display_name: &str, element_type: &str) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    display_name.hash(&mut h);
    element_type.hash(&mut h);
    format!("vsrc:{:016x}", h.finish())
}

/// Descobre dispositivos de captura de vídeo (Video/Source).
pub fn discover_video_sources() -> StudioResult<Vec<VideoSourceDevice>> {
    info!("Discovering video source devices...");

    let monitor = DeviceMonitor::new();
    monitor.add_filter(Some("Video/Source"), None);

    monitor
        .start()
        .map_err(|e| crate::error::StudioError::Gst(format!("VideoSource monitor start: {e}")))?;

    let raw = monitor.devices();
    let mut devices: Vec<VideoSourceDevice> = Vec::new();

    for device in &raw {
        let display_name = device.display_name().to_string();
        let gst_class    = device.device_class().to_string();

        let lower = gst_class.to_lowercase();
        if !lower.contains("video") || !lower.contains("source") {
            continue;
        }

        let element_type = device
            .element_factory()
            .map(|f| f.name().to_string())
            .unwrap_or_else(|| "unknown".into());

        if element_type == "unknown" {
            warn!("Video source '{}' has no factory — skipping", display_name);
            continue;
        }

        let mut properties = std::collections::HashMap::new();
        if let Some(props) = device.properties() {
            for i in 0..props.n_fields() {
                if let Some(field_name) = props.nth_field_name(i) {
                    if let Ok(v) = props.get::<String>(field_name.as_str()) {
                        properties.insert(field_name.to_string(), v);
                    } else if let Ok(v) = props.get::<i32>(field_name.as_str()) {
                        properties.insert(field_name.to_string(), v.to_string());
                    }
                }
            }
        }

        let id       = make_device_id(&display_name, &element_type);
        let is_ndi   = element_type.contains("ndi");
        let is_default = element_type == "autovideosrc";

        debug!("Video source: '{}' → '{}' [ndi={}]", display_name, element_type, is_ndi);

        devices.push(VideoSourceDevice {
            id,
            display_name,
            element_type,
            gst_class,
            properties,
            is_ndi,
            is_default,
        });
    }

    monitor.stop();

    // NDI sources não aparecem via DeviceMonitor pois são rede.
    // Injeta a opção de seleção de NDI por nome:
    if gst::ElementFactory::find("ndisrc").is_some() {
        devices.push(VideoSourceDevice {
            id:           make_device_id("NDI Source (nome configurável)", "ndisrc"),
            display_name: "NDI Source (configure o nome no campo abaixo)".into(),
            element_type: "ndisrc".into(),
            gst_class:    "Video/Source".into(),
            properties:   Default::default(),
            is_ndi:       true,
            is_default:   false,
        });
    }

    // autovideosrc fallback
    if gst::ElementFactory::find("autovideosrc").is_some() {
        devices.insert(0, VideoSourceDevice {
            id:           make_device_id("Default Video Input", "autovideosrc"),
            display_name: "Default Video Input (OS Default)".into(),
            element_type: "autovideosrc".into(),
            gst_class:    "Video/Source".into(),
            properties:   Default::default(),
            is_ndi:       false,
            is_default:   true,
        });
    }

    info!("Found {} video source device(s)", devices.len());
    Ok(devices)
}

/// Cria o elemento GStreamer para a fonte de vídeo selecionada.
/// Para NDI, configura o `ndi-name` property.
pub fn create_video_source(
    device_id:  &str,
    sources:    &[VideoSourceDevice],
    ndi_name:   Option<&str>, // nome da fonte NDI, se aplicável
) -> StudioResult<gst::Element> {
    let dev = sources
        .iter()
        .find(|d| d.id == device_id)
        .ok_or_else(|| crate::error::StudioError::DeviceNotFound { device_id: device_id.into() })?;

    let elem = gst::ElementFactory::make(&dev.element_type)
        .name("ifb-video-capture")
        .build()
        .map_err(|_| crate::error::StudioError::ElementCreate { name: dev.element_type.clone() })?;

    // NDI: configurar o nome da fonte
    if dev.is_ndi {
        if let Some(name) = ndi_name {
            elem.set_property("ndi-name", name);
        } else {
            warn!("NDI source selected but no ndi_name provided — using empty name");
        }
        // Configurações de latência NDI para broadcast
        elem.set_property_from_str("timestamp-mode", "receive-time-vs-rtc");
    }

    // Configurações gerais de captura
    for (key, value) in &dev.properties {
        match key.as_str() {
            "device" | "device-path" | "device-name" => {
                if elem.has_property(key, Some(String::static_type())) {
                    elem.set_property(key.as_str(), value.as_str());
                }
            }
            "device-index" | "device-number" => {
                if let Ok(n) = value.parse::<i32>() {
                    if elem.has_property(key, Some(i32::static_type())) {
                        elem.set_property(key.as_str(), n);
                    }
                }
            }
            _ => {}
        }
    }

    Ok(elem)
}
