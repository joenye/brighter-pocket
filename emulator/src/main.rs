//! pocket-emulator: run the macOS Brighter Shores client's own startup on an Apple silicon Mac,
//! as iOS would run it with this layer, until it presents frames (docs/emulator.md).
//!
//! usage: emulator/target/release/pocket-emulator [--client DIR] [--frameworks DIR] [--frames N]
//!            [--pinned-appkit] [--check] [--click X,Y[@FRAME]]... [--offline]
//!            [--network [--steam-live] [--reach NAME:PORT]... [--record-network FILE]
//!                       [--probe-network HOST[:PORT]]]
//!
//! The executable's arm64 slice is mapped at its preferred addresses and fixed up, this layer's
//! adapters (the app's arm64 iOS builds from tools/build_ios.py) beside it, and dynarmic's JIT
//! runs them (src/cpu.rs). Each of the client's threads runs on a host thread of its own, all at
//! once, as on the device; clocks are the host's. Every import not bound to an adapter is
//! answered here (src/hle/) as the device would answer it, as far as the client asks; anything
//! else stops the run with its name. Nothing is written outside the emulator, and nothing
//! reaches a network but with --network, which lets the client's lookups and connections out
//! from this machine directly, as on a device.
//!
//! It stops after --frames presented frames, when the client exits, when it calls something not
//! answered here, or when no frame comes for --stall seconds, and reports what it saw. --check
//! prints only the verdict and fails unless the run presented its frames with every shader
//! accepted and nothing but harmless AppKit calls left unanswered.
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use clap::Parser;

mod cpu;
mod hle;
mod loader;
mod machine;
mod macho;
mod memory;
mod report;
mod runtime;
mod probe;
mod settings;
mod steam;

use machine::Machine;

#[derive(Parser, Debug, Clone, Default)]
#[command(about = "Run the macOS Brighter Shores client's startup as iOS would with this layer (docs/emulator.md)")]
pub struct Options {
    /// A downloaded client (default: the newest under client/).
    #[arg(long)]
    pub client: Option<PathBuf>,
    /// The app's Frameworks folder from tools/build_ios.py (its adapters run here).
    #[arg(long)]
    pub frameworks: Option<PathBuf>,
    /// Stop after this many presented frames.
    #[arg(long, default_value_t = 30)]
    pub frames: u64,
    /// Answer AppKit as the pinned Tolkara alone does, without pocket/translation/AppKit.
    #[arg(long)]
    pub pinned_appkit: bool,
    /// Print the verdict only; fail unless startup completed.
    #[arg(long)]
    pub check: bool,
    /// Click the window at X,Y points from its bottom left at FRAME (default 30); repeatable.
    #[arg(long = "click", value_name = "X,Y[@FRAME]")]
    pub clicks: Vec<String>,
    /// As when the player chose to play offline: the app's Steam session has no account.
    #[arg(long)]
    pub offline: bool,
    /// The device is online: the client's lookups use this machine's resolver and its
    /// connections go out from here directly. Without it nothing leaves: every lookup of a name
    /// fails as with no network.
    #[arg(long)]
    pub network: bool,
    /// With --network: the bridge's account and tickets come from a real Steam session
    /// (STEAM_USER's login as DepotDownloader remembers it).
    #[arg(long)]
    pub steam_live: bool,
    /// With --network: write every read and write on the game's connections to FILE (frame,
    /// peer, direction, hex), for study; it holds the Steam ticket: keep it under build/.
    #[arg(long, value_name = "FILE")]
    pub record_network: Option<PathBuf>,
    /// After the initializers, fetch http://HOST/ through the client's own getaddrinfo and
    /// connect, as it would reach a server, print what came back, and stop.
    #[arg(long, value_name = "HOST[:PORT]")]
    pub probe_network: Option<String>,
    /// Stop if no frame comes for this long on the host.
    #[arg(long, default_value_t = 900.0)]
    pub stall: f64,
    /// Log the first call of every client function (frame, thread, address) to FILE (under
    /// build/), for debugging the layer's answers.
    #[arg(long, value_name = "FILE")]
    pub coverage: Option<PathBuf>,
    /// Log each run of the instruction at client+ADDR with x0 to x7 and the memory DUMPs name
    /// (`xN+xM`, `xN:LEN`, `*xN+OFF:LEN`); repeatable; needs --probe-log (src/probe.rs).
    #[arg(long = "probe", value_name = "ADDR[:DUMP,...]")]
    pub probes: Vec<String>,
    /// Where --probe writes (it can hold a session's secrets: keep it under build/).
    #[arg(long, value_name = "FILE")]
    pub probe_log: Option<PathBuf>,
    /// With --network: connect only to these servers (NAME:PORT, repeatable); any other is refused.
    #[arg(long, value_name = "NAME:PORT")]
    pub reach: Vec<String>,
}

fn main() {
    let options = Options::parse();
    std::process::exit(match run(options) {
        Ok(code) => code,
        Err(message) => {
            eprintln!("{message}");
            2
        }
    });
}

fn run(options: Options) -> Result<i32, String> {
    let app = settings::client_app(options.client.as_deref())?;
    let frameworks = options.frameworks.clone().unwrap_or_else(|| settings::build_dir().join("ios/Payload/BrighterPocket.app/Frameworks"));
    if !frameworks.join("aklibsteam_api.dylib").is_file() {
        return Err(format!("no adapters in {}: build the app with tools/build_ios.py", frameworks.display()));
    }
    let check = options.check;
    let m = Machine::new(options);
    m.report.set_progress(!check);
    hle::prepare(&m, &app)?;
    let loaded = loader::load(&m, &app, &frameworks)?;
    probe::install(&m, &loaded.client)?;
    if !check {
        println!(
            "client fixed up: {} rebases, {} binds; adapters: {} rebases, {} binds",
            loaded.client_fixups.0, loaded.client_fixups.1, loaded.adapter_fixups.0, loaded.adapter_fixups.1
        );
    }
    watch(&m);
    let started = Instant::now();
    let outcome = run_main(&m, &loaded.client, &app);
    let outcome = m.stop_reason().unwrap_or(outcome);
    m.stop(outcome.clone());
    m.runtime.join_all();
    hle::finish(&m);
    probe::finish(&m);
    let seconds = started.elapsed().as_secs_f64();
    if check {
        return Ok(verdict(&m, &outcome));
    }
    report(&m, &outcome, seconds);
    Ok(0)
}

/// The main thread: the client's initializers, then main(1, argv).
fn run_main(m: &Arc<Machine>, client: &macho::Image, app: &std::path::Path) -> String {
    let thread = runtime::new_thread(m);
    let (mut cpu, _context) = runtime::new_cpu(m, &thread);
    let outcome = run_main_on(m, &mut cpu, &thread, client, app);
    runtime::retire(&thread);
    outcome
}

fn run_main_on(m: &Arc<Machine>, cpu: &mut cpu::Cpu, thread: &Arc<runtime::GuestThread>, client: &macho::Image, app: &std::path::Path) -> String {
    let stack = m.alloc(runtime::MAIN_STACK);
    let top = stack + runtime::MAIN_STACK - 0x1000;
    let Some(section) = client.section("__TEXT", "__init_offsets") else { return "the client has no initializers".into() };
    let offsets: Vec<u64> = (0..section.size / 4).map(|i| m.memory.u32(section.addr + 4 * i) as u64 + client.base()).collect();
    for init in &offsets {
        cpu.set_sp(top);
        if let Err(stop) = runtime::call(m, cpu, thread, *init, &[0, 0, 0, 0]) {
            return stop.0;
        }
    }
    if !m.options.check {
        println!("{} initializers ran", offsets.len());
    }
    if let Some(target) = m.options.probe_network.clone() {
        return hle::network::probe(m, cpu, thread, &target);
    }
    let path = m.new_cstring(&app.join(settings::BUNDLE_EXECUTABLE).to_string_lossy());
    let argv = m.alloc(32);
    m.memory.set_u64(argv, path);
    let Some(entry) = client.entry() else { return "the client has no entry point".into() };
    cpu.set_sp(top);
    match runtime::call(m, cpu, thread, client.base() + entry, &[1, argv, 0, 0]) {
        Ok(code) => format!("returned from the entry point ({})", code as i32),
        Err(stop) => stop.0,
    }
}

/// Stop the run when no frame comes for --stall seconds, or on SIGTERM or SIGINT.
fn watch(m: &Arc<Machine>) {
    let machine = m.clone();
    unsafe {
        let handler = on_signal as extern "C" fn(libc::c_int) as libc::sighandler_t;
        libc::signal(libc::SIGTERM, handler);
        libc::signal(libc::SIGINT, handler);
    }
    std::thread::spawn(move || {
        let stall = Duration::from_secs_f64(machine.options.stall);
        let (mut frames, mut since) = (machine.frames.load(Ordering::Relaxed), Instant::now());
        loop {
            std::thread::sleep(Duration::from_millis(200));
            if machine.is_stopping() {
                return;
            }
            if SIGNALLED.load(Ordering::Relaxed) {
                machine.stop(format!("interrupted after {} frames", machine.frames.load(Ordering::Relaxed)));
                return;
            }
            let now = machine.frames.load(Ordering::Relaxed);
            if now != frames {
                (frames, since) = (now, Instant::now());
            } else if since.elapsed() > stall {
                machine.stop(format!("no frame for {:.0} s after frame {frames}", stall.as_secs_f64()));
                return;
            }
        }
    });
}

static SIGNALLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

extern "C" fn on_signal(_: libc::c_int) {
    SIGNALLED.store(true, Ordering::Relaxed);
}

fn verdict(m: &Machine, outcome: &str) -> i32 {
    let mut problems = Vec::new();
    let frames = m.options.frames;
    if outcome != format!("presented {frames} frames") {
        problems.push(format!("stopped before presenting {frames} frames: {outcome}"));
    }
    problems.extend(hle::problems(m));
    if m.report.console_lines().iter().any(|line| line.contains("exception:")) {
        problems.push("the client reported an exception".into());
    }
    println!(
        "startup: {}, {} frames presented, {} threads started",
        hle::summary(m),
        m.frames.load(Ordering::Relaxed),
        m.runtime.started.lock().unwrap().len()
    );
    for problem in &problems {
        println!("  problem: {problem}");
    }
    if problems.is_empty() { 0 } else { 1 }
}

fn report(m: &Machine, outcome: &str, seconds: f64) {
    let list = |title: &str, lines: Vec<String>| {
        println!("{title}:");
        if lines.is_empty() {
            println!("  nothing");
        }
        for line in lines {
            println!("  {line}");
        }
    };
    println!("stopped: {outcome}");
    println!("console:");
    for line in m.report.console_lines() {
        println!("  | {line}");
    }
    list("steam", m.report.steam_lines());
    list("network", m.report.network_lines());
    list("files opened", m.report.files_opened());
    for (title, lines) in hle::sections(m) {
        list(&title, lines);
    }
    let mappings = m.report.mappings();
    println!(
        "frames presented: {} in {seconds:.1} s; memory: {} MB allocated, {} mmap calls, largest {:.1} MB",
        m.frames.load(Ordering::Relaxed),
        m.heap.used() >> 20,
        mappings.len(),
        mappings.iter().max().copied().unwrap_or(0) as f64 / 1e6
    );
    println!("threads started: {}", m.runtime.started.lock().unwrap().len());
    let at_stop = m.runtime.at_stop.lock().unwrap().clone().unwrap_or_default();
    list(
        "threads at the stop",
        at_stop
            .into_iter()
            .map(|(id, entry, state)| match state {
                Some((name, caller)) => format!("thread {id} at {}: in {name} from {}", m.where_(entry), m.where_(caller)),
                None => format!("thread {id} at {}: running", m.where_(entry)),
            })
            .collect(),
    );
    list("busiest answered imports", m.report.busiest(15).into_iter().map(|(name, n)| format!("{n:9} {name}")).collect());
}
