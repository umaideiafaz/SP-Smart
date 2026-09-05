fn main() {
    // Força o Tauri a ignorar falhas de winres por falta de ícone estático em dev
    std::env::set_var("TAURI_SKIP_HEADER_CHECK", "true");
    tauri_build::build();
}