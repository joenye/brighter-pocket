//! What a run saw, for the report main.rs prints: the client's console, Steam's and the
//! network's logs, the files it opened, the imports it called (and those not answered).
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Default)]
pub struct Report {
    console: Mutex<Vec<String>>,
    steam: Mutex<Vec<String>>,
    network: Mutex<Vec<String>>,
    files: Mutex<Vec<String>>,
    unanswered: Mutex<Vec<String>>,
    answered: Mutex<HashMap<String, u64>>,
    mappings: Mutex<Vec<u64>>,
    progress: std::sync::atomic::AtomicBool,
}

impl Report {
    pub fn set_progress(&self, on: bool) {
        self.progress.store(on, std::sync::atomic::Ordering::Relaxed)
    }
    pub fn progress(&self) -> bool {
        self.progress.load(std::sync::atomic::Ordering::Relaxed)
    }
    /// A line the client printed or logged (several lines are split).
    pub fn console(&self, text: impl Into<String>) {
        let text = text.into();
        let mut console = self.console.lock().unwrap();
        console.extend(text.trim_end_matches('\n').split('\n').map(str::to_string));
    }
    pub fn steam(&self, line: impl Into<String>) {
        self.steam.lock().unwrap().push(line.into())
    }
    pub fn network(&self, line: impl Into<String>) {
        let line = line.into();
        self.console(format!("[network] {line}"));
        self.network.lock().unwrap().push(line)
    }
    pub fn file_opened(&self, path: impl Into<String>) {
        self.files.lock().unwrap().push(path.into())
    }
    pub fn unanswered(&self, name: &str) {
        self.unanswered.lock().unwrap().push(name.to_string())
    }
    pub fn answered(&self, name: &str) {
        *self.answered.lock().unwrap().entry(name.to_string()).or_insert(0) += 1
    }
    pub fn mapping(&self, length: u64) {
        self.mappings.lock().unwrap().push(length)
    }

    pub fn console_lines(&self) -> Vec<String> {
        self.console.lock().unwrap().clone()
    }
    pub fn steam_lines(&self) -> Vec<String> {
        self.steam.lock().unwrap().clone()
    }
    pub fn network_lines(&self) -> Vec<String> {
        self.network.lock().unwrap().clone()
    }
    pub fn files_opened(&self) -> Vec<String> {
        self.files.lock().unwrap().clone()
    }
    pub fn mappings(&self) -> Vec<u64> {
        self.mappings.lock().unwrap().clone()
    }
    /// The answered imports by calls, most first.
    pub fn busiest(&self, count: usize) -> Vec<(String, u64)> {
        let mut calls: Vec<(String, u64)> = self.answered.lock().unwrap().iter().map(|(k, &v)| (k.clone(), v)).collect();
        calls.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        calls.truncate(count);
        calls
    }
}
