// ============================================================
// SP Smart Studio — Audio Source Device Discovery
// ============================================================
// Descobre os dispositivos de CAPTURA de áudio disponíveis no sistema:
//   • Linhas de entrada de mesas de som (WASAPI, ALSA, Core Audio)
//   • Interfaces de áudio profissional (RME, Focusrite, etc.)
//   • Entradas de placas DeckLink / AJA
//   • Qualquer dispositivo Audio/Source que o GStreamer suporte
//
// PROPÓSITO: O operador seleciona qual saída física da mesa de som
// (Mix-Minus) enviará o IFB para o repórter em campo.
// ============================================================

use gstreamer::{self as gst, prelude::*, DeviceMonitor};
use serde::{Deserialize, Serialize};
use tracing::{debug, info, warn};

use crate::error::StudioResult;

/// Dispositivo de captura de áudio disponível no sistema.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioSourceDevice {
    pub id:           String,
    pub display_name: String,
    pub element_type: String,
    pub gst_class:    String,
    pub properties:   std::collections::HashMap<String, String>,
    /// True se é o device de captura padrão do SO
    pub is_default:   bool,
}

fn make_device_id(display_name: &str, element_type: &str) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    display_name.hash(&mut h);
    element_type.hash(&mut h);
    format!("asrc:{:016x}", h.finish())
}

/// Varre todos os dispositivos de captura de áudio disponíveis.
pub fn discover_audio_sources() -> StudioResult<Vec<AudioSourceDevice>> {
    info!("Discovering audio source devices...");

    let monitor = DeviceMonitor::new();
    monitor.add_filter(Some("Audio/Source"), None);

    monitor
        .start()
        .map_err(|e| crate::error::StudioError::Gst(format!("AudioSource monitor start: {e}")))?;

    let raw = monitor.devices();
    let mut devices: Vec<AudioSourceDevice> = Vec::new();

    for device in &raw {
        let display_name = device.display_name().to_string();
        let gst_class    = device.device_class().to_string();

        // Filtra apenas Audio/Source
        if !gst_class.to_lowercase().contains("audio") {
            continue;
        }
        if !gst_class.to_lowercase().contains("source") {
            continue;
        }

        let element_type = device
            .element_factory()
            .map(|f| f.name().to_string())
            .unwrap_or_else(|| "unknown".into());

        if element_type == "unknown" {
            warn!("Audio source '{}' has no factory — skipping", display_name);
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

        let id = make_device_id(&display_name, &element_type);
        let is_default = display_name.to_lowercase().contains("default")
            || element_type == "autoaudiosrc";

        debug!("Audio source: '{}' → '{}'", display_name, element_type);

        devices.push(AudioSourceDevice {
            id,
            display_name,
            element_type,
            gst_class,
            properties,
            is_default,
        });
    }

    monitor.stop();

    // Inject autoaudiosrc fallback
    if gst::ElementFactory::find("autoaudiosrc").is_some() {
        devices.insert(0, AudioSourceDevice {
            id:           make_device_id("Default Audio Input", "autoaudiosrc"),
            display_name: "Default Audio Input (OS Default)".into(),
            element_type: "autoaudiosrc".into(),
            gst_class:    "Audio/Source".into(),
            properties:   Default::default(),
            is_default:   true,
        });
    }

    info!("Found {} audio source device(s)", devices.len());
    Ok(devices)
}

/// Cria um elemento GStreamer para o dispositivo de captura selecionado.
pub fn create_audio_source(
    device_id: &str,
    sources:   &[AudioSourceDevice],
) -> StudioResult<gst::Element> {
    let dev = sources
        .iter()
        .find(|d| d.id == device_id)
        .ok_or_else(|| crate::error::StudioError::DeviceNotFound { device_id: device_id.into() })?;

    let elem = gst::ElementFactory::make(&dev.element_type)
        .name("ifb-audio-capture")
        .build()
        .map_err(|_| crate::error::StudioError::ElementCreate { name: dev.element_type.clone() })?;

    // Aplica propriedades específicas do driver
    for (key, value) in &dev.properties {
        match key.as_str() {
            "device" | "device-name" if elem.has_property(key, Some(String::static_type())) => {
                elem.set_property(key.as_str(), value.as_str());
            }
            "device-index" | "device-number" if elem.has_property(key, Some(i32::static_type())) => {
                if let Ok(n) = value.parse::<i32>() {
                    elem.set_property(key.as_str(), n);
                }
            }
            _ => {}
        }
    }

    Ok(elem)
}
