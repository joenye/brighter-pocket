//! The network: none, or the device's own, from this machine (--network).
//!
//! Without --network nothing leaves: every lookup of a name fails as on a phone with no network,
//! and every connect is unreachable. With it, the client's lookups are this machine's resolver's
//! (its IPv4 addresses, as AF_INET is all the client asks for) and its stream connects go
//! straight out from here, as a phone's do. Reads, writes, poll and the socket options the client
//! uses are the host socket's. --reach narrows the servers a connect may reach by the name the
//! client looked up; --record-network writes what crossed.
use std::collections::HashMap;
use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpStream, ToSocketAddrs};
use std::os::fd::AsRawFd;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::{Ctx, Registry, Stop, files, objc};
use crate::machine::Machine;

// Darwin's numbers, as the client sees them.
const EINPROGRESS: i32 = 36;
const EAGAIN: i32 = 35;
const ECONNREFUSED: i32 = 61;
const ETIMEDOUT: i32 = 60;
const ENETUNREACH: i32 = 51;
const ENOTSOCK: i32 = 38;
const EAI_NONAME: u64 = 8;
const EAI_FAMILY: u64 = 5;
const AF_INET: u32 = 2;
const AF_UNSPEC: u32 = 0;
const SOCK_STREAM: i32 = 1;
const O_NONBLOCK: u64 = 0x4;
const F_GETFL: u32 = 3;
const F_SETFL: u32 = 4;
const SOL_SOCKET: u32 = 0xFFFF;
const SO_ERROR: u32 = 0x1007;
const SO_TYPE: u32 = 0x1008;
const POLLIN: i16 = 0x1;
const POLLOUT: i16 = 0x4;
const POLLERR: i16 = 0x8;
const POLLHUP: i16 = 0x10;
const FAILED: u64 = u64::MAX;
const FAILED32: u64 = 0xFFFF_FFFF;

#[derive(Default)]
struct Network {
    names: HashMap<u32, String>, // looked-up address -> the name the client asked for
    sockets: HashMap<i32, Socket>,
    record: Option<std::fs::File>,
    received: u64,
    sent: u64,
    start: Option<Instant>,
}

#[derive(Default)]
struct Socket {
    kind: i32, // SOCK_STREAM, SOCK_DGRAM
    stream: Option<Arc<TcpStream>>,
    nonblocking: bool,
    error: i32,
    peer: Option<String>,
    received: u64,
    sent: u64,
    ended: Option<u64>,
}

fn frame(m: &Machine) -> u64 {
    m.frames.load(std::sync::atomic::Ordering::Relaxed)
}

fn log(m: &Machine, line: &str) {
    m.report.network(format!("frame {}: {line}", frame(m)));
}

pub fn prepare(m: &Machine, _app: &std::path::Path) -> Result<(), String> {
    let state = m.state::<Network>();
    let mut net = state.lock().unwrap();
    net.start = Some(Instant::now());
    if let Some(path) = &m.options.record_network {
        net.record = Some(std::fs::File::create(path).map_err(|e| format!("--record-network {}: {e}", path.display()))?);
    }
    Ok(())
}

pub fn finish(m: &Machine) {
    if let Some(mut file) = m.state::<Network>().lock().unwrap().record.take() {
        file.flush().ok();
    }
}

pub fn problems(_m: &Machine) -> Vec<String> {
    Vec::new()
}

/// The bytes the game's connections carried (boot.py prints them under the network log).
pub fn sections(m: &Machine) -> Vec<(String, Vec<String>)> {
    let state = m.state::<Network>();
    let net = state.lock().unwrap();
    vec![("network bytes".into(), vec![format!("received {}, sent {}", net.received, net.sent)])]
}

/// An answered call's caller, then theirs by the frame-pointer chain.
fn backtrace(c: &Ctx, depth: usize) -> Vec<String> {
    let mut chain = vec![c.where_(c.lr())];
    let mut fp = c.cpu.reg(29);
    while fp != 0 && chain.len() < depth {
        if !c.mem().is_mapped(fp, 16) {
            break;
        }
        let (next, lr) = (c.mem().u64(fp), c.mem().u64(fp + 8));
        if lr == 0 {
            break;
        }
        chain.push(c.where_(lr & 0x0000_FFFF_FFFF_FFFF));
        fp = next;
    }
    chain
}

/// sockaddr_in: sin_len, sin_family, the port and the address in network order, 8 bytes of zero.
fn sockaddr_in(port: u16, address: u32) -> [u8; 16] {
    let mut out = [0u8; 16];
    out[0] = 16;
    out[1] = AF_INET as u8;
    out[2..4].copy_from_slice(&port.to_be_bytes());
    out[4..8].copy_from_slice(&address.to_be_bytes());
    out
}

/// Darwin's addrinfo: flags, family, socktype, protocol (TCP), addrlen, padding, then
/// canonname, addr and next.
fn addrinfo(socktype: i32, sockaddr: u64, next: u64) -> [u8; 48] {
    let mut out = [0u8; 48];
    for (i, v) in [0, AF_INET as i32, if socktype == 0 { SOCK_STREAM } else { socktype }, 6, 16].iter().enumerate() {
        out[4 * i..4 * i + 4].copy_from_slice(&v.to_le_bytes());
    }
    out[32..40].copy_from_slice(&sockaddr.to_le_bytes());
    out[40..48].copy_from_slice(&next.to_le_bytes());
    out
}

/// `name`'s IPv4 addresses by this machine's resolver, each once, in its order.
fn lookup(name: &str) -> std::io::Result<Vec<Ipv4Addr>> {
    let mut found = Vec::new();
    for address in (name, 0).to_socket_addrs()? {
        if let SocketAddr::V4(v4) = address {
            if !found.contains(v4.ip()) {
                found.push(*v4.ip());
            }
        }
    }
    Ok(found)
}

/// The host socket's readiness for `events` now (the guest's POLLIN and POLLOUT are Darwin's, as the host's).
fn readiness(fd: i32, events: i16) -> i16 {
    let mut entry = libc::pollfd { fd, events: libc::POLLIN | libc::POLLOUT, revents: 0 };
    // SAFETY: one valid pollfd, no wait.
    let n = unsafe { libc::poll(&mut entry, 1, 0) };
    if n <= 0 {
        return 0;
    }
    (if entry.revents & libc::POLLIN != 0 { POLLIN } else { 0 }) & events
        | (if entry.revents & libc::POLLOUT != 0 { POLLOUT } else { 0 }) & events
}

/// Wait up to `ms` for the host socket to become ready for `events` (libc's numbers).
fn wait_for(fd: i32, events: i16, ms: i32) {
    let mut entry = libc::pollfd { fd, events, revents: 0 };
    // SAFETY: one valid pollfd.
    unsafe { libc::poll(&mut entry, 1, ms) };
}

fn record(m: &Machine, net: &mut Network, fd: i32, direction: &str, data: &[u8]) {
    let Some(entry) = net.sockets.get_mut(&fd) else { return };
    if direction == "received" {
        entry.received += data.len() as u64;
        net.received += data.len() as u64;
    } else {
        entry.sent += data.len() as u64;
        net.sent += data.len() as u64;
    }
    let peer = entry.peer.clone().unwrap_or_default();
    if let Some(file) = net.record.as_mut() {
        // --record-network: every read and write, for study (it holds the ticket).
        let hex: String = data.iter().map(|b| format!("{b:02x}")).collect();
        writeln!(file, "{} {peer} {direction} {hex}", frame(m)).ok();
    }
}

fn io_errno(error: &std::io::Error) -> i32 {
    match error.kind() {
        ErrorKind::ConnectionReset | ErrorKind::ConnectionRefused => ECONNREFUSED,
        ErrorKind::TimedOut => ETIMEDOUT,
        ErrorKind::NetworkUnreachable | ErrorKind::HostUnreachable => ENETUNREACH,
        _ => ETIMEDOUT,
    }
}

pub fn register(r: &mut Registry) {
    r.answer(&["_freeaddrinfo"], |_| Ok(None));

    // --- the system's lookups and sockets -----------------------------------------------------
    r.answer(&["_getaddrinfo"], getaddrinfo);
    r.answer(&["_socket"], |c| {
        let fd = files::new_fd(c);
        let entry = Socket { kind: c.arg32(1) as i32, ..Socket::default() };
        c.state::<Network>().lock().unwrap().sockets.insert(fd, entry);
        Ok(Some(fd as u32 as u64))
    });
    r.answer(&["_connect"], connect);
    r.answer(&["_getsockopt"], |c| {
        let fd = c.arg32(0) as i32;
        let state = c.state::<Network>();
        let mut net = state.lock().unwrap();
        if let Some(entry) = net.sockets.get_mut(&fd) {
            match (c.arg32(1), c.arg32(2)) {
                (SOL_SOCKET, SO_ERROR) => {
                    c.mem().set_i32(c.arg(3), entry.error);
                    entry.error = 0;
                }
                (SOL_SOCKET, SO_TYPE) => {
                    c.mem().set_i32(c.arg(3), entry.kind);
                    c.mem().set_u32(c.arg(4), 4);
                }
                _ => {}
            }
        }
        Ok(Some(0))
    });
    r.answer(&["_setsockopt"], |_| Ok(Some(0)));
    r.answer(&["_poll"], poll);
    r.answer(&["_read"], read);
    r.answer(&["_write"], write);
    r.answer(&["_close"], close);
    r.answer(&["_fcntl"], |c| {
        let fd = c.arg32(0) as i32;
        let state = c.state::<Network>();
        let mut net = state.lock().unwrap();
        let Some(entry) = net.sockets.get_mut(&fd) else {
            drop(net);
            return files::fcntl(c);
        };
        match c.arg32(1) {
            F_GETFL => return Ok(Some(if entry.nonblocking { O_NONBLOCK } else { 0 })),
            F_SETFL => entry.nonblocking = c.stack(0) & O_NONBLOCK != 0,
            _ => {}
        }
        Ok(Some(0))
    });
}

fn getaddrinfo(c: &mut Ctx) -> Result<Option<u64>, Stop> {
    let (node, service, hints, result) = (c.cstring(c.arg(0)), c.arg(1), c.arg(2), c.arg(3));
    if !c.m.options.network {
        log(c.m, &format!("lookup of {node}: no network here"));
        return Ok(Some(EAI_NONAME));
    }
    let family = if hints != 0 { c.mem().u32(hints + 4) } else { AF_UNSPEC };
    if family != AF_UNSPEC && family != AF_INET {
        return Ok(Some(EAI_FAMILY));
    }
    let service = if service != 0 { Some(c.cstring(service)) } else { None };
    let port = service.as_deref().filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())).and_then(|s| s.parse().ok()).unwrap_or(0);
    let addresses = match lookup(&node) {
        Ok(found) if !found.is_empty() => found,
        Ok(_) => {
            log(c.m, &format!("lookup of {node}: no IPv4 address"));
            return Ok(Some(EAI_NONAME));
        }
        Err(error) => {
            log(c.m, &format!("lookup of {node} failed: {error}"));
            return Ok(Some(EAI_NONAME));
        }
    };
    {
        let state = c.state::<Network>();
        let mut net = state.lock().unwrap();
        for address in &addresses {
            net.names.insert(u32::from(*address), node.clone());
        }
    }
    let listed: Vec<String> = addresses.iter().map(|a| a.to_string()).collect();
    log(c.m, &format!("lookup of {node} (service {}): {}", service.as_deref().unwrap_or("-"), listed.join(", ")));
    let socktype = if hints != 0 { c.mem().i32(hints + 8) } else { SOCK_STREAM };
    // The list from its end, so each entry points at the one after it.
    let mut next = 0;
    for address in addresses.iter().rev() {
        let (info, sockaddr) = (c.alloc(48), c.alloc(16));
        c.mem().write(sockaddr, &sockaddr_in(port, u32::from(*address)));
        c.mem().write(info, &addrinfo(socktype, sockaddr, next));
        next = info;
    }
    c.mem().set_u64(result, next);
    Ok(Some(0))
}

fn connect(c: &mut Ctx) -> Result<Option<u64>, Stop> {
    let fd = c.arg32(0) as i32;
    let raw = c.mem().read(c.arg(1), 8);
    let family = raw[1] as u32;
    let port = u16::from_be_bytes([raw[2], raw[3]]);
    let address = u32::from_be_bytes([raw[4], raw[5], raw[6], raw[7]]);
    let state = c.state::<Network>();
    let mut net = state.lock().unwrap();
    let Some(entry) = net.sockets.get(&fd) else {
        drop(net);
        c.set_errno(ENOTSOCK);
        return Ok(Some(FAILED32));
    };
    if !c.m.options.network || family != AF_INET {
        drop(net);
        c.set_errno(ENETUNREACH);
        return Ok(Some(FAILED32));
    }
    if entry.kind != SOCK_STREAM {
        return Err(Stop(format!("connect of a socket of type {}: only stream sockets are answered", entry.kind)));
    }
    let name = net.names.get(&address).cloned().unwrap_or_else(|| Ipv4Addr::from(address).to_string());
    let peer = format!("{name}:{port}");
    // --reach: only the servers named; any other connect is refused as with no network (a study
    // of the roster exchange must not go on to the login server).
    if !c.m.options.reach.is_empty() && !c.m.options.reach.iter().any(|allowed| *allowed == peer) {
        drop(net);
        log(c.m, &format!("connect to {peer} refused: not in --reach"));
        c.set_errno(ENETUNREACH);
        return Ok(Some(FAILED32));
    }
    let entry = net.sockets.get_mut(&fd).unwrap();
    entry.peer = Some(peer.clone());
    let nonblocking = entry.nonblocking;
    drop(net);
    let target = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::from(address), port));
    let opened = TcpStream::connect_timeout(&target, Duration::from_secs(30))
        .and_then(|s| s.set_nodelay(true).and_then(|_| s.set_nonblocking(true)).map(|_| s));
    let mut net = state.lock().unwrap();
    let Some(entry) = net.sockets.get_mut(&fd) else {
        drop(net);
        c.set_errno(ENETUNREACH);
        return Ok(Some(FAILED32));
    };
    match opened {
        Ok(stream) => {
            entry.stream = Some(Arc::new(stream));
            drop(net);
            log(c.m, &format!("connected to {peer}"));
            // Signed in to a real game from here on: no scripted click may land on its screens.
            if objc::stop_clicks(c.m) {
                log(c.m, "scripted clicks stopped: the game reached a server");
            }
        }
        Err(error) => {
            let errno = io_errno(&error);
            entry.error = errno;
            drop(net);
            log(c.m, &format!("connect to {peer} failed: {error}"));
            if !nonblocking {
                c.set_errno(errno);
                return Ok(Some(FAILED32));
            }
        }
    }
    if nonblocking {
        // As a non-blocking connect reports: in progress, then poll says done.
        c.set_errno(EINPROGRESS);
        return Ok(Some(FAILED32));
    }
    Ok(Some(0))
}

/// A socket's readiness is the host socket's; any other descriptor is ready for what it asks.
/// A wait lasts at most 50 ms of the host's time, then the thread lets the others run.
fn poll(c: &mut Ctx) -> Result<Option<u64>, Stop> {
    let (fds, count, timeout) = (c.arg(0), c.arg32(1) as u64, c.arg32(2) as i32);
    let wait = if timeout >= 0 { timeout.min(50) } else { 50 };
    let deadline = Instant::now() + Duration::from_millis(wait as u64);
    let state = c.state::<Network>();
    loop {
        let mut ready = 0;
        {
            let net = state.lock().unwrap();
            for i in 0..count {
                let at = fds + 8 * i;
                let (fd, events) = (c.mem().i32(at), c.mem().u16(at + 4) as i16);
                let revents = match net.sockets.get(&fd) {
                    None => events & (POLLIN | POLLOUT),
                    Some(Socket { stream: Some(stream), .. }) => readiness(stream.as_raw_fd(), events),
                    Some(entry) if entry.error != 0 || entry.peer.is_some() => POLLERR | POLLHUP,
                    Some(_) => 0,
                };
                c.mem().set_u16(at + 6, revents as u16);
                ready += (revents != 0) as u64;
            }
        }
        if ready != 0 || Instant::now() >= deadline {
            if ready == 0 {
                std::thread::yield_now();
            }
            return Ok(Some(ready));
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn read(c: &mut Ctx) -> Result<Option<u64>, Stop> {
    let fd = c.arg32(0) as i32;
    let state = c.state::<Network>();
    let net = state.lock().unwrap();
    let Some(entry) = net.sockets.get(&fd) else {
        drop(net);
        return files::read(c);
    };
    let Some(stream) = entry.stream.clone() else {
        drop(net);
        c.set_errno(ENETUNREACH);
        return Ok(Some(FAILED));
    };
    let deadline = Instant::now() + if entry.nonblocking { Duration::ZERO } else { Duration::from_secs(30) };
    drop(net);
    let mut buffer = vec![0u8; c.arg(2) as usize];
    let n = loop {
        match (&*stream).read(&mut buffer) {
            Ok(n) => break n,
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(e) if e.kind() == ErrorKind::WouldBlock => {
                if Instant::now() >= deadline {
                    c.set_errno(EAGAIN);
                    return Ok(Some(FAILED));
                }
                wait_for(stream.as_raw_fd(), libc::POLLIN, 50);
            }
            Err(e) => {
                c.set_errno(io_errno(&e));
                return Ok(Some(FAILED));
            }
        }
    };
    c.mem().write(c.arg(1), &buffer[..n]);
    let mut net = state.lock().unwrap();
    record(c.m, &mut net, fd, "received", &buffer[..n]);
    if let Some(entry) = net.sockets.get_mut(&fd) {
        if n == 0 && entry.ended.is_none() {
            entry.ended = Some(frame(c.m));
        }
    }
    Ok(Some(n as u64))
}

fn write(c: &mut Ctx) -> Result<Option<u64>, Stop> {
    let fd = c.arg32(0) as i32;
    let state = c.state::<Network>();
    let net = state.lock().unwrap();
    let Some(entry) = net.sockets.get(&fd) else {
        drop(net);
        return files::write(c);
    };
    let Some(stream) = entry.stream.clone() else {
        drop(net);
        c.set_errno(ENETUNREACH);
        return Ok(Some(FAILED));
    };
    drop(net);
    // All of it, as a blocking send would.
    let data = c.mem().read(c.arg(1), c.arg(2) as usize);
    let mut done = 0;
    while done < data.len() {
        match (&*stream).write(&data[done..]) {
            Ok(n) => done += n,
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(e) if e.kind() == ErrorKind::WouldBlock => wait_for(stream.as_raw_fd(), libc::POLLOUT, 50),
            Err(e) => {
                c.set_errno(io_errno(&e));
                return Ok(Some(FAILED));
            }
        }
    }
    record(c.m, &mut state.lock().unwrap(), fd, "sent", &data);
    Ok(Some(data.len() as u64))
}

fn close(c: &mut Ctx) -> Result<Option<u64>, Stop> {
    let fd = c.arg32(0) as i32;
    let state = c.state::<Network>();
    let mut net = state.lock().unwrap();
    let Some(entry) = net.sockets.remove(&fd) else {
        drop(net);
        return files::close(c);
    };
    let start = net.start.unwrap_or_else(Instant::now);
    drop(net);
    if entry.stream.is_some() {
        let ended = entry.ended.map_or(String::new(), |f| format!(", the server closed it at frame {f}"));
        let peer = entry.peer.clone().unwrap_or_default();
        log(c.m, &format!("closed {peer}: {} bytes sent, {} received{ended}", entry.sent, entry.received));
        // Who let go, for when the game hangs up itself.
        log(
            c.m,
            &format!(
                "  by thread {} at {:.1} s of the host clock, from {}",
                c.thread.id,
                start.elapsed().as_secs_f64(),
                backtrace(c, 12).join(" < ")
            ),
        );
    }
    Ok(Some(0))
}

/// --probe-network: fetch http://HOST[:PORT]/ through the client's own getaddrinfo and connect
/// (the answers above) and the system's socket calls, as the client would reach a server; the
/// outcome for the report.
pub fn probe(m: &Arc<Machine>, cpu: &mut crate::cpu::Cpu, thread: &crate::runtime::GuestThread, target: &str) -> String {
    match probe_on(m, cpu, thread, target) {
        Ok(outcome) | Err(Stop(outcome)) => outcome,
    }
}

fn probe_on(m: &Arc<Machine>, cpu: &mut crate::cpu::Cpu, thread: &crate::runtime::GuestThread, target: &str) -> Result<String, Stop> {
    let (host, port) = match target.split_once(':') {
        Some((host, port)) => (host, port.parse::<u16>().map_err(|_| Stop(format!("--probe-network: no port number in {target}")))?),
        None => (target, 80),
    };
    let (getaddrinfo, connect) = (m.slot_address("_getaddrinfo"), m.slot_address("_connect"));
    let mut call = |function: u64, args: &[u64]| crate::runtime::call(m, cpu, thread, function, args);

    let result = m.alloc(8);
    let found = call(getaddrinfo, &[m.new_cstring(host), m.new_cstring(&port.to_string()), 0, result])? & 0xFFFF_FFFF;
    if found != 0 {
        return Ok(format!("getaddrinfo({host}) = {found} (no address)"));
    }
    let sockaddr = m.memory.u64(m.memory.u64(result) + 32);
    let fd = call(m.slot_address("_socket"), &[AF_INET as u64, SOCK_STREAM as u64, 0])? & 0xFFFF_FFFF;
    if call(connect, &[fd, sockaddr, 16])? & 0xFFFF_FFFF != 0 {
        return Ok("connect = -1 (failed)".into());
    }
    let request = format!("GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n");
    let buffer = m.alloc(4096);
    m.memory.write(buffer, request.as_bytes());
    call(m.slot_address("_write"), &[fd, buffer, request.len() as u64])?;
    let mut response = Vec::new();
    loop {
        let n = call(m.slot_address("_read"), &[fd, buffer, 4096])?;
        if n == 0 || n == FAILED {
            break;
        }
        response.extend_from_slice(&m.memory.read(buffer, n as usize));
    }
    call(m.slot_address("_close"), &[fd])?;
    Ok(describe(&response))
}

/// A response's status line and the start of its body.
fn describe(response: &[u8]) -> String {
    let text = String::from_utf8_lossy(response);
    let status = text.split("\r\n").next().unwrap_or("");
    let body = text.split_once("\r\n\r\n").map_or(&*text, |(_, b)| b).trim();
    format!("{status}; body: {}", body.chars().take(80).collect::<String>())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addrinfo_and_sockaddr_layout() {
        let address = sockaddr_in(443, 0xC612_0001);
        assert_eq!(address, [16, 2, 0x01, 0xBB, 198, 18, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]);
        let info = addrinfo(0, 0x4_0000_1000, 0x4_0000_2000);
        assert_eq!(i32::from_le_bytes(info[4..8].try_into().unwrap()), 2); // family
        assert_eq!(i32::from_le_bytes(info[8..12].try_into().unwrap()), 1); // SOCK_STREAM by default
        assert_eq!(i32::from_le_bytes(info[12..16].try_into().unwrap()), 6); // TCP
        assert_eq!(u32::from_le_bytes(info[16..20].try_into().unwrap()), 16);
        assert_eq!(u64::from_le_bytes(info[24..32].try_into().unwrap()), 0); // canonname
        assert_eq!(u64::from_le_bytes(info[32..40].try_into().unwrap()), 0x4_0000_1000);
        assert_eq!(u64::from_le_bytes(info[40..48].try_into().unwrap()), 0x4_0000_2000); // next
        assert_eq!(i32::from_le_bytes(addrinfo(2, 0, 0)[8..12].try_into().unwrap()), 2);
    }

    /// The host's resolver answers a name from its hosts file without the network.
    #[test]
    fn looks_up_localhost_by_the_host_resolver() {
        assert!(lookup("localhost").unwrap().contains(&Ipv4Addr::LOCALHOST));
        assert_eq!(lookup("127.0.0.1").unwrap(), [Ipv4Addr::LOCALHOST]);
    }

    #[test]
    fn connect_errors_are_darwins() {
        let error = |kind| io_errno(&std::io::Error::from(kind));
        assert_eq!(error(ErrorKind::ConnectionRefused), ECONNREFUSED);
        assert_eq!(error(ErrorKind::TimedOut), ETIMEDOUT);
        assert_eq!(error(ErrorKind::NetworkUnreachable), ENETUNREACH);
    }

    #[test]
    fn poll_sees_a_socket_pair_as_the_host_does() {
        let (mut a, b) = std::os::unix::net::UnixStream::pair().unwrap();
        assert_eq!(readiness(b.as_raw_fd(), POLLIN), 0);
        assert_eq!(readiness(b.as_raw_fd(), POLLOUT), POLLOUT);
        a.write_all(b"x").unwrap();
        assert_eq!(readiness(b.as_raw_fd(), POLLIN | POLLOUT), POLLIN | POLLOUT);
    }

    #[test]
    fn describes_a_response() {
        assert_eq!(describe(b"HTTP/1.1 200 OK\r\nA: b\r\n\r\n 1.2.3.4\n"), "HTTP/1.1 200 OK; body: 1.2.3.4");
    }
}
