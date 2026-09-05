// ============================================================
// SP Smart Studio — Device Monitor
// Hardware-Agnostic Discovery + Factory Fallbacks
// ============================================================

use gstreamer::{
    self as gst,
    prelude::*,
    Device,
    DeviceMonitor,
};

use serde::{Deserialize, Serialize};
use tracing::{debug, info, warn};

use crate::error::{
    StudioError,
    StudioResult,
};

// ── Tipos serializáveis para o frontend ──────────────────────

#[derive(
    Debug,
    Clone,
    PartialEq,
    Eq,
    Serialize,
    Deserialize,
)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum DeviceClass {
    VideoSink,
    AudioSink,
    VideoSource,
    AudioSource,
    Other,
}

impl DeviceClass {
    pub fn from_gst_class(class: &str) -> Self {
        let lower = class.to_lowercase();

        if lower.contains("video")
            && lower.contains("sink")
        {
            DeviceClass::VideoSink
        } else if lower.contains("audio")
            && lower.contains("sink")
        {
            DeviceClass::AudioSink
        } else if lower.contains("video")
            && lower.contains("source")
        {
            DeviceClass::VideoSource
        } else if lower.contains("audio")
            && lower.contains("source")
        {
            DeviceClass::AudioSource
        } else {
            DeviceClass::Other
        }
    }
}

#[derive(
    Debug,
    Clone,
    Serialize,
    Deserialize,
)]
pub struct DeviceInfo {
    pub id: String,
    pub display_name: String,
    pub gst_class: String,
    pub device_class: DeviceClass,
    pub element_type: String,
    pub properties:
        std::collections::HashMap<String, String>,
    pub is_auto: bool,
}

#[derive(
    Debug,
    Clone,
    Serialize,
    Deserialize,
)]
pub struct DiscoveredDevices {
    pub video_sinks: Vec<DeviceInfo>,
    pub audio_sinks: Vec<DeviceInfo>,
}

// ============================================================
// ID estável
// ============================================================

pub fn make_device_id(
    display_name: &str,
    element_type: &str,
) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{
        Hash,
        Hasher,
    };

    let mut h = DefaultHasher::new();

    display_name.hash(&mut h);
    element_type.hash(&mut h);

    format!("{:016x}", h.finish())
}

// ============================================================
// Conversão Device → DeviceInfo
// ============================================================

pub fn device_to_info(
    device: &Device,
) -> Option<DeviceInfo> {
    let display_name =
        device.display_name().to_string();

    let gst_class =
        device.device_class().to_string();

    let device_class =
        DeviceClass::from_gst_class(
            &gst_class
        );

    if device_class != DeviceClass::VideoSink
        && device_class != DeviceClass::AudioSink
    {
        return None;
    }

    let element =
        match device.create_element(None) {
            Ok(element) => element,

            Err(err) => {
                warn!(
                    "Could not create element for device '{}': {}",
                    display_name,
                    err
                );

                return None;
            }
        };

    let element_type = element
        .factory()
        .map(
            |factory| {
                factory
                    .name()
                    .to_string()
            }
        )
        .unwrap_or_else(
            || "unknown".into()
        );

    if element_type == "unknown" {
        return None;
    }

    let mut properties =
        std::collections::HashMap::new();

    if let Some(props) =
        device.properties()
    {
        for i in 0..props.n_fields() {
            if let Some(field_name) =
                props.nth_field_name(i)
            {
                if let Ok(value) =
                    props.get::<String>(
                        field_name.as_str()
                    )
                {
                    properties.insert(
                        field_name.to_string(),
                        value,
                    );
                } else if let Ok(value) =
                    props.get::<i32>(
                        field_name.as_str()
                    )
                {
                    properties.insert(
                        field_name.to_string(),
                        value.to_string(),
                    );
                } else if let Ok(value) =
                    props.get::<u32>(
                        field_name.as_str()
                    )
                {
                    properties.insert(
                        field_name.to_string(),
                        value.to_string(),
                    );
                }
            }
        }
    }

    let id =
        make_device_id(
            &display_name,
            &element_type,
        );

    let is_auto =
        element_type
            .starts_with("auto");

    debug!(
        "Discovered Device: '{}' [{}] → '{}'",
        display_name,
        gst_class,
        element_type
    );

    Some(
        DeviceInfo {
            id,
            display_name,
            gst_class,
            device_class,
            element_type,
            properties,
            is_auto,
        }
    )
}

// ============================================================
// Descoberta principal
// ============================================================

pub fn discover_devices(
) -> StudioResult<DiscoveredDevices> {
    info!(
        "Starting hardware device discovery..."
    );

    let mut video_sinks:
        Vec<DeviceInfo> = Vec::new();

    let mut audio_sinks:
        Vec<DeviceInfo> = Vec::new();

    // --------------------------------------------------------
    // Tenta DeviceMonitor primeiro
    // --------------------------------------------------------

    let monitor =
        DeviceMonitor::new();

    monitor.add_filter(
        Some("Video/Sink"),
        None,
    );

    monitor.add_filter(
        Some("Audio/Sink"),
        None,
    );

    match monitor.start() {
        Ok(_) => {
            let raw_devices =
                monitor.devices();

            for device in &raw_devices {
                if let Some(info) =
                    device_to_info(device)
                {
                    match info.device_class {
                        DeviceClass::VideoSink => {
                            video_sinks
                                .push(info);
                        }

                        DeviceClass::AudioSink => {
                            audio_sinks
                                .push(info);
                        }

                        _ => {}
                    }
                }
            }

            monitor.stop();
        }

        Err(err) => {
            warn!(
                "DeviceMonitor unavailable: {}",
                err
            );
        }
    }

    // --------------------------------------------------------
    // Factory fallbacks
    // --------------------------------------------------------

    inject_factory_fallbacks(
        &mut video_sinks,
        &mut audio_sinks,
    );

    info!(
        "Device discovery complete: {} video sink(s), {} audio sink(s)",
        video_sinks.len(),
        audio_sinks.len()
    );

    Ok(
        DiscoveredDevices {
            video_sinks,
            audio_sinks,
        }
    )
}

// ============================================================
// Factory-based fallback discovery
// ============================================================

pub fn inject_factory_fallbacks(
    video_sinks: &mut Vec<DeviceInfo>,
    audio_sinks: &mut Vec<DeviceInfo>,
) {
    // --------------------------------------------------------
    // DeckLink
    // --------------------------------------------------------

    if gst::ElementFactory::find(
        "decklinkvideosink"
    )
    .is_some()
    {
        push_unique(
            video_sinks,
            DeviceInfo {
                id:
                    make_device_id(
                        "Blackmagic DeckLink",
                        "decklinkvideosink",
                    ),

                display_name:
                    "Blackmagic DeckLink Output"
                        .into(),

                gst_class:
                    "Video/Sink/Hardware"
                        .into(),

                device_class:
                    DeviceClass::VideoSink,

                element_type:
                    "decklinkvideosink"
                        .into(),

                properties:
                    Default::default(),

                is_auto:
                    false,
            },
        );
    }

    // --------------------------------------------------------
    // Direct3D 11
    // --------------------------------------------------------

    if gst::ElementFactory::find(
        "d3d11videosink"
    )
    .is_some()
    {
        push_unique(
            video_sinks,
            DeviceInfo {
                id:
                    make_device_id(
                        "Direct3D11 Video",
                        "d3d11videosink",
                    ),

                display_name:
                    "Direct3D11 Video Output"
                        .into(),

                gst_class:
                    "Video/Sink"
                        .into(),

                device_class:
                    DeviceClass::VideoSink,

                element_type:
                    "d3d11videosink"
                        .into(),

                properties:
                    Default::default(),

                is_auto:
                    false,
            },
        );
    }

    // --------------------------------------------------------
    // Auto Video
    // --------------------------------------------------------

    if gst::ElementFactory::find(
        "autovideosink"
    )
    .is_some()
    {
        push_unique(
            video_sinks,
            DeviceInfo {
                id:
                    make_device_id(
                        "Auto Video Output",
                        "autovideosink",
                    ),

                display_name:
                    "Auto Video Output (OS Default)"
                        .into(),

                gst_class:
                    "Video/Sink"
                        .into(),

                device_class:
                    DeviceClass::VideoSink,

                element_type:
                    "autovideosink"
                        .into(),

                properties:
                    Default::default(),

                is_auto:
                    true,
            },
        );
    }

    // --------------------------------------------------------
    // Auto Audio
    // --------------------------------------------------------

    if gst::ElementFactory::find(
        "autoaudiosink"
    )
    .is_some()
    {
        push_unique(
            audio_sinks,
            DeviceInfo {
                id:
                    make_device_id(
                        "Auto Audio Output",
                        "autoaudiosink",
                    ),

                display_name:
                    "Auto Audio Output (OS Default)"
                        .into(),

                gst_class:
                    "Audio/Sink"
                        .into(),

                device_class:
                    DeviceClass::AudioSink,

                element_type:
                    "autoaudiosink"
                        .into(),

                properties:
                    Default::default(),

                is_auto:
                    true,
            },
        );
    }
}

// ============================================================
// Evita duplicação
// ============================================================

fn push_unique(
    list: &mut Vec<DeviceInfo>,
    device: DeviceInfo,
) {
    let already_exists =
        list.iter().any(
            |existing| {
                existing.element_type
                    == device.element_type
                    && existing.display_name
                        == device.display_name
            }
        );

    if !already_exists {
        list.push(device);
    }
}

// ============================================================
// Criação do elemento selecionado
// ============================================================

pub fn create_element_for_device(
    device_id: &str,
    discovered: &DiscoveredDevices,
    element_name: &str,
) -> StudioResult<gst::Element> {
    let info = discovered
        .video_sinks
        .iter()
        .chain(
            discovered
                .audio_sinks
                .iter()
        )
        .find(
            |d| d.id == device_id
        )
        .ok_or_else(
            || {
                StudioError::DeviceNotFound {
                    device_id:
                        device_id.into(),
                }
            }
        )?;

    let element =
        gst::ElementFactory::make(
            &info.element_type
        )
        .name(element_name)
        .build()
        .map_err(
            |_| {
                StudioError::ElementCreate {
                    name:
                        info
                            .element_type
                            .clone(),
                }
            }
        )?;

    apply_device_properties(
        &element,
        info,
    );

    Ok(element)
}

// ============================================================
// Propriedades específicas do dispositivo
// ============================================================

pub fn apply_device_properties(
    element: &gst::Element,
    info: &DeviceInfo,
) {
    for (key, value)
        in &info.properties
    {
        match key.as_str() {
            "device-number"
            | "device-index" => {
                if let Ok(n) =
                    value.parse::<i32>()
                {
                    if element.has_property(
                        key,
                        Some(
                            i32::static_type()
                        ),
                    ) {
                        element
                            .set_property(
                                key.as_str(),
                                n,
                            );
                    }
                }
            }

            "device"
            | "device-identifier"
            | "device-name" => {
                if element.has_property(
                    key,
                    Some(
                        String::static_type()
                    ),
                ) {
                    element
                        .set_property(
                            key.as_str(),
                            value.as_str(),
                        );
                }
            }

            _ => {}
        }
    }
}