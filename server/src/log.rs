use std::io::Write;

const LOG_FILE: &str = "quire_server.log";

pub fn log(event: &str, data: &serde_json::Value) {
    let ts = chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f");
    let entry = serde_json::json!({
        "ts": ts.to_string(),
        "event": event,
        "data": data,
    });
    let line = format!("{entry}\n");
    eprint!("[{ts}] {event}: {data}");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(LOG_FILE)
    {
        let _ = f.write_all(line.as_bytes());
    }
}
