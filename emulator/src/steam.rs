//! A real Steam session for --steam-live, as tests/emulate/steam_session.py has it: the app's
//! session core (pocket/launcher/Pocket/PocketSteam.c, linked by build.rs), signed in with the
//! refresh token DepotDownloader remembers for the account, over the same SOCKS5 proxy into the
//! VPN as the game's own connections. The bridge the game's Steam library reaches then answers
//! with the account's Steam ID, persona name and real web API tickets, as the phone's session would.
//!
//! A thread keeps the session alive while the emulated client runs: it reads Steam's messages as
//! they come (whole websocket frames: a partial one waits in the reader) and sends a heartbeat at
//! the interval Steam asked for. Should the connection drop, it signs in again, once, and says
//! so; should Steam log the session off (the account signed in elsewhere: Joe's own Steam, say),
//! it stops there, and the bridge has no ticket to give: the account is never taken back.
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::io::{ErrorKind, Read, Write};
use std::net::TcpStream;
use std::os::fd::{AsRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use tungstenite::{Message, WebSocket};

use crate::socks::Socks5;

pub type Log = Box<dyn Fn(String) + Send + Sync>;

const APP_ID: u32 = 2791440;
const LOGGING_ON: c_int = 2; // PocketSteamStatus
const ONLINE: c_int = 3;
const LOGGED_OFF: c_int = 5;
const LOGGED_IN_ELSEWHERE: c_int = 6; // EResult
const TICKET_SIZE: usize = 2560;
const TIMEOUT: Duration = Duration::from_secs(30);

#[repr(C)]
struct PocketSteamSession {
    _opaque: [u8; 0],
}
type SendFn = extern "C" fn(*mut c_void, *const u8, usize);
type RandomFn = extern "C" fn(*mut c_void, usize);
type GunzipFn = extern "C" fn(*const u8, usize, *mut u8, usize) -> c_int;

#[link(name = "pocketsteam", kind = "static")]
unsafe extern "C" {
    fn pocket_steam_create(send: SendFn, context: *mut c_void, random: RandomFn, gunzip: GunzipFn)
    -> *mut PocketSteamSession;
    fn pocket_steam_destroy(session: *mut PocketSteamSession);
    fn pocket_steam_hello(session: *mut PocketSteamSession);
    fn pocket_steam_logon(
        session: *mut PocketSteamSession,
        account: *const c_char,
        refresh_token: *const c_char,
        machine_name: *const c_char,
    );
    fn pocket_steam_logoff(session: *mut PocketSteamSession);
    fn pocket_steam_heartbeat(session: *mut PocketSteamSession);
    fn pocket_steam_receive(session: *mut PocketSteamSession, frame: *const u8, size: usize) -> c_int;
    fn pocket_steam_status(session: *const PocketSteamSession, result: *mut c_int) -> c_int;
    fn pocket_steam_steam_id(session: *const PocketSteamSession) -> u64;
    fn pocket_steam_persona_name(session: *const PocketSteamSession) -> *const c_char;
    fn pocket_steam_heartbeat_seconds(session: *const PocketSteamSession) -> c_int;
    fn pocket_steam_connect_tokens(session: *const PocketSteamSession) -> usize;
    fn pocket_steam_request_ownership(session: *mut PocketSteamSession, app_id: u32);
    fn pocket_steam_ownership(session: *const PocketSteamSession, app_id: u32, result: *mut c_int) -> c_int;
    fn pocket_steam_games_played(session: *mut PocketSteamSession, app_id: u32);
    fn pocket_steam_web_ticket(
        session: *mut PocketSteamSession,
        app_id: u32,
        identity: *const c_char,
        ticket: *mut u8,
        crc: *mut u32,
    ) -> c_int;
}

/// The session core: one caller at a time, under LiveSession::core.
struct Core(*mut PocketSteamSession);
// SAFETY: the core is plain C with no thread affinity; the Mutex around it serialises every call.
unsafe impl Send for Core {}

impl Drop for Core {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { pocket_steam_destroy(self.0) };
        }
    }
}

impl Core {
    fn status(&self) -> (c_int, c_int) {
        let mut result = 0;
        let status = if self.0.is_null() { 0 } else { unsafe { pocket_steam_status(self.0, &mut result) } };
        (status, result)
    }

    fn persona(&self) -> String {
        let name = unsafe { pocket_steam_persona_name(self.0) };
        if name.is_null() { String::new() } else { unsafe { CStr::from_ptr(name) }.to_string_lossy().into_owned() }
    }
}

type Tls = rustls::StreamOwned<rustls::ClientConnection, TcpStream>;

/// The websocket to a connection manager, non-blocking once open.
struct Socket {
    ws: WebSocket<Tls>,
    fd: RawFd,
}

struct Info {
    steam_id: u64,
    persona: String,
    heartbeat: u64,
}

pub struct LiveSession {
    vpn: Socks5,
    account: String,
    log: Log,
    core: Mutex<Core>,
    socket: Mutex<Option<Socket>>, // the core's sends take this under core, so never the reverse
    connected: Mutex<bool>,
    connected_changed: Condvar,
    ended: Mutex<Option<String>>, // why the session ended for good
    running: AtomicBool,
    info: Mutex<Info>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl LiveSession {
    pub fn open(vpn: &Socks5, account: &str, log: Log) -> Result<Arc<LiveSession>, String> {
        let session = Arc::new(LiveSession {
            vpn: Socks5 { host: vpn.host.clone(), port: vpn.port, user: vpn.user.clone(), password: vpn.password.clone() },
            account: account.to_string(),
            log,
            core: Mutex::new(Core(std::ptr::null_mut())),
            socket: Mutex::new(None),
            connected: Mutex::new(false),
            connected_changed: Condvar::new(),
            ended: Mutex::new(None),
            running: AtomicBool::new(true),
            info: Mutex::new(Info { steam_id: 0, persona: String::new(), heartbeat: 9 }),
            thread: Mutex::new(None),
        });
        session.connect()?;
        let keeper = Arc::clone(&session);
        *session.thread.lock().unwrap() = Some(std::thread::spawn(move || keeper.keep_alive()));
        Ok(session)
    }

    pub fn steam_id(&self) -> u64 {
        self.info.lock().unwrap().steam_id
    }

    pub fn persona(&self) -> String {
        self.info.lock().unwrap().persona.clone()
    }

    // --- connecting and signing in ---------------------------------------------------------
    fn connect(&self) -> Result<(), String> {
        if let Some(mut old) = self.socket.lock().unwrap().take() {
            let _ = old.ws.close(None);
            let _ = old.ws.flush();
        }
        let mut socket = None;
        for endpoint in endpoints(&self.vpn)?.iter().take(5) {
            // a manager may drop a new connection: try the next
            if let Ok(opened) = open_websocket(&self.vpn, endpoint) {
                socket = Some(opened);
                break;
            }
        }
        let socket = socket.ok_or("no Steam connection manager answered through the VPN")?;
        *self.socket.lock().unwrap() = Some(socket);
        let token = CString::new(saved_refresh_token(&self.account)?).map_err(|_| "the saved refresh token holds a NUL")?;
        let account = CString::new(self.account.as_str()).map_err(|_| "the account name holds a NUL")?;
        {
            let mut core = self.core.lock().unwrap();
            let context = &self.socket as *const Mutex<Option<Socket>> as *mut c_void;
            *core = Core(unsafe { pocket_steam_create(send_frame, context, random_bytes, gunzip_into) });
            if core.0.is_null() {
                return Err("the session core could not be created".into());
            }
            unsafe {
                pocket_steam_hello(core.0);
                pocket_steam_logon(core.0, account.as_ptr(), token.as_ptr(), c"Brighter Pocket".as_ptr());
            }
        }
        drop(token);
        self.pump_until(|core| core.status().0 != LOGGING_ON, "the logon")?;
        if self.core.lock().unwrap().status().0 != ONLINE {
            return Err("Steam refused the logon".into());
        }
        unsafe { pocket_steam_request_ownership(self.core.lock().unwrap().0, APP_ID) };
        let mut owned = 0;
        self.pump_until(|core| unsafe { pocket_steam_ownership(core.0, APP_ID, &mut owned) } != 0, "ownership")?;
        if owned != 1 {
            return Err(format!("no ownership ticket for {APP_ID} (result {owned})"));
        }
        unsafe { pocket_steam_games_played(self.core.lock().unwrap().0, APP_ID) };
        self.pump_until(
            |core| !core.persona().is_empty() && unsafe { pocket_steam_connect_tokens(core.0) } > 0,
            "account info and tokens",
        )?;
        {
            let core = self.core.lock().unwrap();
            let seconds = unsafe { pocket_steam_heartbeat_seconds(core.0) };
            *self.info.lock().unwrap() = Info {
                steam_id: unsafe { pocket_steam_steam_id(core.0) },
                persona: core.persona(),
                heartbeat: if seconds > 0 { seconds as u64 } else { 9 },
            };
        }
        self.set_connected(true);
        Ok(())
    }

    fn set_connected(&self, value: bool) {
        *self.connected.lock().unwrap() = value;
        self.connected_changed.notify_all();
    }

    // --- reading Steam's messages ----------------------------------------------------------
    /// Hand the core one message from Steam if one arrives within timeout.
    fn receive_ready(&self, timeout: Duration) -> Result<(), String> {
        let mut frame = self.read_frame()?;
        if frame.is_none() {
            let fd = self.socket.lock().unwrap().as_ref().ok_or("no connection to Steam")?.fd;
            if !wait_for(fd, libc::POLLIN, timeout) {
                return Ok(());
            }
            frame = self.read_frame()?;
        }
        let Some(frame) = frame else { return Ok(()) };
        let core = self.core.lock().unwrap();
        if unsafe { pocket_steam_receive(core.0, frame.as_ptr(), frame.len()) } != 0 {
            return Err("a message from Steam could not be read".into());
        }
        Ok(())
    }

    /// A whole binary frame if one is in, else None (pings and pongs are not Steam's messages).
    fn read_frame(&self) -> Result<Option<Vec<u8>>, String> {
        let mut socket = self.socket.lock().unwrap();
        let socket = socket.as_mut().ok_or("no connection to Steam")?;
        match socket.ws.read() {
            Ok(Message::Binary(frame)) if !frame.is_empty() => Ok(Some(frame)),
            Ok(Message::Close(_)) => Err("Steam closed the connection".into()),
            Ok(_) => Ok(None),
            Err(tungstenite::Error::Io(error)) if error.kind() == ErrorKind::WouldBlock => Ok(None),
            Err(error) => Err(format!("the connection to Steam failed: {error}")),
        }
    }

    fn pump_until(&self, mut done: impl FnMut(&Core) -> bool, what: &str) -> Result<(), String> {
        let deadline = Instant::now() + TIMEOUT;
        while !done(&self.core.lock().unwrap()) {
            if Instant::now() > deadline {
                return Err(format!("timed out waiting for {what}"));
            }
            if let Some(reason) = self.logged_off() {
                return Err(reason);
            }
            self.receive_ready(Duration::from_secs(1))?;
        }
        Ok(())
    }

    /// Why Steam ended the session, if it did: that is Steam's decision, never fought.
    fn logged_off(&self) -> Option<String> {
        let (status, result) = self.core.lock().unwrap().status();
        if status != LOGGED_OFF {
            return None;
        }
        let elsewhere =
            if result == LOGGED_IN_ELSEWHERE { " (LoggedInElsewhere: the account signed in elsewhere)" } else { "" };
        Some(format!("Steam logged the session off: EResult {result}{elsewhere}"))
    }

    fn keep_alive(&self) {
        let mut beat = Instant::now();
        while self.running.load(Ordering::SeqCst) {
            let step = self.receive_ready(Duration::from_secs(1)).and_then(|()| {
                let heartbeat = Duration::from_secs(self.info.lock().unwrap().heartbeat);
                if beat.elapsed() >= heartbeat {
                    unsafe { pocket_steam_heartbeat(self.core.lock().unwrap().0) };
                    beat = Instant::now();
                }
                if self.core.lock().unwrap().status().0 != ONLINE {
                    return Err("the session is no longer online".to_string());
                }
                Ok(())
            });
            let Err(error) = step else { continue };
            if !self.running.load(Ordering::SeqCst) {
                return;
            }
            self.set_connected(false);
            // Steam ending the session (another sign-in to the account, above all) is final:
            // signing in again would take the account back from wherever it is in use.
            if let Some(reason) = self.logged_off() {
                (self.log)(format!("{reason}; not signing in again"));
                *self.ended.lock().unwrap() = Some(reason);
                return;
            }
            (self.log)(format!("the connection to Steam was lost ({error}); signing in again"));
            std::thread::sleep(Duration::from_secs(2));
            if let Err(again) = self.connect() {
                let reason = format!("signing in again failed ({again})");
                (self.log)(reason.clone());
                *self.ended.lock().unwrap() = Some(reason);
                return;
            }
            (self.log)("signed in to Steam again".into());
            beat = Instant::now();
        }
    }

    // --- what the bridge asks --------------------------------------------------------------
    /// A web API ticket for the identity, and its CRC; None without a connected session in 60 s.
    pub fn web_ticket(&self, identity: &str) -> Option<(Vec<u8>, u32)> {
        let connected = {
            let guard = self.connected.lock().unwrap();
            let (guard, _) = self
                .connected_changed
                .wait_timeout_while(guard, Duration::from_secs(60), |connected| {
                    !*connected && self.ended.lock().unwrap().is_none()
                })
                .unwrap();
            *guard
        };
        if self.ended.lock().unwrap().is_some() || !connected {
            (self.log)(format!("no Steam session for a ticket for {identity:?}"));
            return None;
        }
        let identity = CString::new(identity).ok()?;
        let mut ticket = vec![0u8; TICKET_SIZE];
        let mut crc = 0u32;
        let core = self.core.lock().unwrap();
        let made = unsafe { pocket_steam_web_ticket(core.0, APP_ID, identity.as_ptr(), ticket.as_mut_ptr(), &mut crc) };
        (made == 0).then_some((ticket, crc))
    }

    pub fn close(&self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(thread) = self.thread.lock().unwrap().take() {
            let _ = thread.join();
        }
        if std::mem::replace(&mut *self.connected.lock().unwrap(), false) {
            {
                let core = self.core.lock().unwrap();
                unsafe {
                    pocket_steam_games_played(core.0, 0);
                    pocket_steam_logoff(core.0);
                }
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        self.connected_changed.notify_all();
        if let Some(mut socket) = self.socket.lock().unwrap().take() {
            let _ = socket.ws.close(None);
            let _ = socket.ws.flush();
        }
    }
}

// --- the core's callbacks ------------------------------------------------------------------
/// Called by the core under LiveSession::core, context being LiveSession::socket. An error here
/// cannot cross back into C: the next read finds the connection gone.
extern "C" fn send_frame(context: *mut c_void, frame: *const u8, size: usize) {
    let socket = unsafe { &*(context as *const Mutex<Option<Socket>>) };
    let frame = unsafe { std::slice::from_raw_parts(frame, size) }.to_vec();
    let Ok(mut socket) = socket.lock() else { return };
    let Some(socket) = socket.as_mut() else { return };
    let mut sent = socket.ws.send(Message::Binary(frame));
    let deadline = Instant::now() + TIMEOUT;
    // Non-blocking: the frame is queued; flush it as the socket takes it.
    while matches!(&sent, Err(tungstenite::Error::Io(error)) if error.kind() == ErrorKind::WouldBlock)
        && Instant::now() < deadline
    {
        wait_for(socket.fd, libc::POLLOUT, Duration::from_secs(1));
        sent = socket.ws.flush();
    }
}

extern "C" fn random_bytes(buffer: *mut c_void, size: usize) {
    let mut filled = 0;
    while filled < size {
        let got = unsafe { libc::getrandom(buffer.cast::<u8>().add(filled).cast(), size - filled, 0) };
        if got > 0 {
            filled += got as usize;
        } else if std::io::Error::last_os_error().kind() != ErrorKind::Interrupted {
            panic!("getrandom failed: {}", std::io::Error::last_os_error());
        }
    }
}

extern "C" fn gunzip_into(data: *const u8, size: usize, output: *mut u8, output_size: usize) -> c_int {
    let data = unsafe { std::slice::from_raw_parts(data, size) };
    let mut plain = Vec::with_capacity(output_size);
    if flate2::read::GzDecoder::new(data).read_to_end(&mut plain).is_err() || plain.len() != output_size {
        return -1;
    }
    unsafe { std::ptr::copy_nonoverlapping(plain.as_ptr(), output, output_size) };
    0
}

/// Whether fd becomes ready for events within timeout.
fn wait_for(fd: RawFd, events: libc::c_short, timeout: Duration) -> bool {
    let mut poll = libc::pollfd { fd, events, revents: 0 };
    unsafe { libc::poll(&mut poll, 1, timeout.as_millis().min(i32::MAX as u128) as c_int) > 0 }
}

// --- the connection ------------------------------------------------------------------------
fn tls(vpn: &Socks5, host: &str, port: u16) -> Result<Tls, String> {
    let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .map_err(|error| error.to_string())?
        .with_root_certificates(roots)
        .with_no_client_auth();
    let name = rustls::pki_types::ServerName::try_from(host.to_string()).map_err(|error| error.to_string())?;
    let connection = rustls::ClientConnection::new(Arc::new(config), name).map_err(|error| error.to_string())?;
    let raw = vpn.open(host, port, TIMEOUT).map_err(|error| format!("{host}:{port}: {error}"))?;
    Ok(rustls::StreamOwned::new(connection, raw))
}

fn open_websocket(vpn: &Socks5, endpoint: &str) -> Result<Socket, String> {
    let (host, port) = match endpoint.rsplit_once(':') {
        Some((host, port)) => (host, port.parse().map_err(|_| format!("bad endpoint {endpoint}"))?),
        None => (endpoint, 443),
    };
    let stream = tls(vpn, host, port)?;
    let fd = stream.sock.as_raw_fd();
    let (ws, _) = tungstenite::client::client(format!("wss://{endpoint}/cmsocket/"), stream)
        .map_err(|error| format!("{endpoint}: {error}"))?;
    ws.get_ref().sock.set_nonblocking(true).map_err(|error| error.to_string())?;
    Ok(Socket { ws, fd })
}

/// Steam's directory of websocket connection managers, fetched through the proxy as well.
fn endpoints(vpn: &Socks5) -> Result<Vec<String>, String> {
    let host = "api.steampowered.com";
    let mut stream = tls(vpn, host, 443)?;
    stream
        .write_all(
            b"GET /ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets HTTP/1.1\r\n\
              Host: api.steampowered.com\r\nConnection: close\r\n\r\n",
        )
        .map_err(|error| format!("Steam's directory: {error}"))?;
    let mut response = Vec::new();
    if let Err(error) = stream.read_to_end(&mut response) {
        // a server that closes without close_notify still sent the whole response
        if error.kind() != ErrorKind::UnexpectedEof || response.is_empty() {
            return Err(format!("Steam's directory: {error}"));
        }
    }
    parse_directory(&response)
}

fn parse_directory(response: &[u8]) -> Result<Vec<String>, String> {
    let split = response.windows(4).position(|w| w == b"\r\n\r\n").ok_or("Steam's directory sent no body")?;
    let mut body = response[split + 4..].to_vec();
    if body[..body.len().min(8)].windows(2).any(|w| w == b"\r\n") {
        // chunked
        let (mut out, mut rest) = (Vec::new(), body.as_slice());
        while !rest.is_empty() {
            let line = rest.windows(2).position(|w| w == b"\r\n").unwrap_or(rest.len());
            let size = std::str::from_utf8(&rest[..line])
                .ok()
                .and_then(|text| usize::from_str_radix(text.trim(), 16).ok())
                .ok_or("Steam's directory sent a bad chunk")?;
            rest = rest.get(line + 2..).unwrap_or_default();
            if size == 0 {
                break;
            }
            out.extend_from_slice(rest.get(..size).ok_or("Steam's directory sent a short chunk")?);
            rest = rest.get(size + 2..).unwrap_or_default();
        }
        body = out;
    }
    let json: serde_json::Value =
        serde_json::from_slice(&body).map_err(|error| format!("Steam's directory: {error}"))?;
    let servers: Vec<String> = json["response"]["serverlist"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|server| server["endpoint"].as_str())
        .filter(|endpoint| endpoint.split(':').next().unwrap_or("").ends_with(".steamserver.net"))
        .map(str::to_string)
        .collect();
    if servers.is_empty() {
        return Err("Steam's directory named no connection manager".into());
    }
    Ok(servers)
}

// --- the remembered login ------------------------------------------------------------------
/// DepotDownloader's remembered login: account.config is deflated protobuf-net, its field 4 the
/// LoginTokens map (account name -> refresh token). The newest file naming the account wins.
pub fn saved_refresh_token(account: &str) -> Result<String, String> {
    let home = std::env::var_os("HOME").ok_or("no HOME")?;
    let mut newest: Option<(std::time::SystemTime, String)> = None;
    for path in account_configs(&Path::new(&home).join(".local/share/IsolatedStorage")) {
        let (Ok(data), Ok(meta)) = (std::fs::read(&path), std::fs::metadata(&path)) else { continue };
        let Some(token) = token_in(&data, account) else { continue };
        let time = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
        if newest.as_ref().is_none_or(|(seen, _)| time > *seen) {
            newest = Some((time, token));
        }
    }
    newest.map(|(_, token)| token).ok_or_else(|| format!("DepotDownloader remembers no login for {account}"))
}

/// IsolatedStorage/*/*/*/AssemFiles/account.config.
fn account_configs(base: &Path) -> Vec<PathBuf> {
    let mut level = vec![base.to_path_buf()];
    for _ in 0..3 {
        level = level
            .iter()
            .filter_map(|dir| std::fs::read_dir(dir).ok())
            .flatten()
            .filter_map(|entry| entry.ok().map(|e| e.path()))
            .filter(|path| path.is_dir())
            .collect();
    }
    level.into_iter().map(|dir| dir.join("AssemFiles/account.config")).filter(|path| path.is_file()).collect()
}

fn token_in(config: &[u8], account: &str) -> Option<String> {
    let mut plain = Vec::new();
    flate2::read::DeflateDecoder::new(config).read_to_end(&mut plain).ok()?;
    let mut found = None;
    for (number, entry) in fields(&plain) {
        if number != 4 {
            continue;
        }
        let (mut name, mut token) = (None, None);
        for (number, value) in fields(entry) {
            match number {
                1 => name = Some(value),
                2 => token = Some(value),
                _ => {}
            }
        }
        if name == Some(account.as_bytes()) && token.is_some_and(|token| !token.is_empty()) {
            found = token.and_then(|token| String::from_utf8(token.to_vec()).ok());
        }
    }
    found
}

fn varint(data: &[u8], i: &mut usize) -> Option<u64> {
    let (mut value, mut shift) = (0u64, 0);
    loop {
        let byte = *data.get(*i)?;
        *i += 1;
        value |= u64::from(byte & 127).checked_shl(shift)?;
        shift += 7;
        if byte < 128 {
            return Some(value);
        }
    }
}

/// The length-delimited fields of a protobuf message, stopping at a wire type other than 0 or 2.
fn fields(data: &[u8]) -> Vec<(u64, &[u8])> {
    let (mut out, mut i) = (Vec::new(), 0);
    while i < data.len() {
        let Some(key) = varint(data, &mut i) else { break };
        match key & 7 {
            2 => {
                let Some(size) = varint(data, &mut i) else { break };
                let Some(value) = data.get(i..i.saturating_add(size as usize)) else { break };
                out.push((key >> 3, value));
                i += size as usize;
            }
            0 => {
                if varint(data, &mut i).is_none() {
                    break;
                }
            }
            _ => break,
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn bytes_field(number: u8, value: &[u8]) -> Vec<u8> {
        let mut out = vec![number << 3 | 2, value.len() as u8];
        out.extend_from_slice(value);
        out
    }

    fn pair(account: &str, token: &str) -> Vec<u8> {
        let mut entry = bytes_field(1, account.as_bytes());
        entry.extend(bytes_field(2, token.as_bytes()));
        bytes_field(4, &entry)
    }

    #[test]
    fn reads_the_remembered_token_from_a_deflated_config() {
        let mut message = vec![1 << 3, 150, 1]; // a varint field first
        message.extend(bytes_field(3, b"other"));
        message.extend(pair("someone", "their-token"));
        message.extend(pair("joenye", "synthetic.token.value"));
        let mut deflate = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
        deflate.write_all(&message).unwrap();
        let config = deflate.finish().unwrap();
        assert_eq!(token_in(&config, "joenye").as_deref(), Some("synthetic.token.value"));
        assert_eq!(token_in(&config, "someone").as_deref(), Some("their-token"));
        assert_eq!(token_in(&config, "nobody"), None);
        assert_eq!(token_in(b"not deflate at all", "joenye"), None);
    }

    #[test]
    fn reads_a_chunked_directory() {
        let body = br#"{"response":{"serverlist":[{"endpoint":"cmp1.steamserver.net:443"},{"endpoint":"x.example:443"}]}}"#;
        let mut response = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".to_vec();
        response.extend(format!("{:x}\r\n", body.len()).as_bytes());
        response.extend_from_slice(body);
        response.extend_from_slice(b"\r\n0\r\n\r\n");
        assert_eq!(parse_directory(&response).unwrap(), ["cmp1.steamserver.net:443"]);
    }

    /// By hand only: signs in to Steam as the account through the VPN (Steam allows one session).
    #[test]
    #[ignore]
    fn live_session_through_the_vpn() {
        let vpn = Socks5::from_settings().unwrap();
        let account = crate::settings::setting("STEAM_USER").unwrap_or_else(|| "joenye".into());
        let session = LiveSession::open(&vpn, &account, Box::new(|line| println!("[steam] {line}"))).unwrap();
        assert_ne!(session.steam_id(), 0);
        println!("persona name: {} characters", session.persona().chars().count());
        let ticket = session.web_ticket("brighter_shores");
        session.close();
        assert_eq!(ticket.map(|(ticket, _)| ticket.len()), Some(TICKET_SIZE));
        println!("live session: pass");
    }
}
