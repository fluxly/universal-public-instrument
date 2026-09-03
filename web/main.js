// Phase 0 stub. Calls the `app_status` Tauri command and paints two status dots.

async function refresh() {
  const invoke = window.__TAURI__?.core?.invoke;
  const embed = document.getElementById("dot-embed");
  const reg = document.getElementById("dot-reg");
  const hint = document.getElementById("hint");

  if (!invoke) {
    hint.textContent = "Running outside Tauri — status unavailable.";
    return;
  }

  try {
    const s = await invoke("app_status");
    embed.classList.toggle("ok", s.extension_embedded);
    embed.classList.toggle("bad", !s.extension_embedded);
    reg.classList.toggle("ok", s.extension_registered);
    reg.classList.toggle("bad", !s.extension_registered);
    hint.textContent = s.extension_registered
      ? `Ready — load “UPI: Universal Public Instrument” in any AU host (v${s.version}).`
      : "Open this app once so macOS registers the extension, then relaunch your DAW.";
  } catch (e) {
    hint.textContent = `status error: ${e}`;
  }
}

refresh();
