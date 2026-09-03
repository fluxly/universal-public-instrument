use serde::Serialize;

#[derive(Serialize)]
struct AppStatus {
    version: &'static str,
    /// True if UPIInstrument.appex is embedded next to this executable.
    extension_embedded: bool,
    /// Whether macOS currently has the AU registered (pluginkit).
    extension_registered: bool,
}

fn extension_embedded() -> bool {
    // <UPI.app>/Contents/MacOS/UPI  ->  <UPI.app>/Contents/PlugIns/UPIInstrument.appex
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .and_then(|macos| macos.parent().map(|c| c.to_path_buf()))
        .map(|contents| contents.join("PlugIns/UPIInstrument.appex").is_dir())
        .unwrap_or(false)
}

fn extension_registered() -> bool {
    std::process::Command::new("pluginkit")
        .args(["-m", "-p", "com.apple.AudioUnit-UI"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("com.upi.app.UPIInstrument"))
        .unwrap_or(false)
}

#[tauri::command]
fn app_status() -> AppStatus {
    AppStatus {
        version: env!("CARGO_PKG_VERSION"),
        extension_embedded: extension_embedded(),
        extension_registered: extension_registered(),
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![app_status])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
