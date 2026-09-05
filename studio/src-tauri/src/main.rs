// Previne janela de console no Windows em builds de release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    sp_smart_studio_lib::run();
}
