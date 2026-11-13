//! The machine: the guest's memory and heap, the answered imports' slots, the images loaded,
//! the report, and the stop every thread obeys.
//!
//! Guest memory map (fastmem, src/memory.rs):
//!   0x1_0000_0000  the client, at its own addresses
//!   0x2_0000_0000  this layer's adapters (libsteam_api, then libSystem.B at +0x1000_0000)
//!   0x3_0000_0000  the answered imports' slots (16 bytes each), then imported data
//!   0x4_0000_0000  the heap (4 GiB): the client's malloc, stacks, thread-local blocks, objects
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use crate::cpu::Monitor;
use crate::hle::{Registry, SLOT_SIZE, States, Stop};
use crate::memory::{Heap, Memory};
use crate::report::Report;

pub const CLIENT_BASE: u64 = 0x1_0000_0000;
pub const ADAPTER_BASE: u64 = 0x2_0000_0000;
pub const HLE_BASE: u64 = 0x3_0000_0000;
pub const HLE_SIZE: u64 = 0x10_0000;
pub const DATA_BASE: u64 = 0x3_1000_0000;
pub const DATA_SIZE: u64 = 0x100_0000;
pub const HEAP_BASE: u64 = 0x4_0000_0000;
pub const HEAP_SIZE: u64 = 0x1_0000_0000;
/// Guest threads the client may have at once (the exclusive monitor's processor count).
pub const MAX_THREADS: usize = 256;

pub struct LoadedImage {
    pub name: String,
    pub slide: u64,
    pub start: u64,
    pub end: u64,
}

pub struct Machine {
    pub memory: Memory,
    pub heap: Heap,
    pub hle: Registry,
    pub monitor: Monitor,
    pub report: Report,
    pub options: crate::Options,
    pub images: OnceLock<Vec<LoadedImage>>,
    pub zone: OnceLock<u64>,
    pub tls_template: OnceLock<crate::loader::TlsTemplate>,
    pub probes: OnceLock<crate::probe::Probes>,
    pub frames: AtomicU64,
    pub runtime: crate::runtime::Runtime,
    states: States,
    data: Mutex<(u64, HashMap<String, u64>)>,
    stopped: Mutex<Option<String>>,
    stopping: AtomicBool,
    this: OnceLock<Weak<Machine>>,
}

impl Machine {
    pub fn new(options: crate::Options) -> Arc<Machine> {
        let memory = Memory::new();
        memory.map(HLE_BASE, HLE_SIZE);
        memory.map(DATA_BASE, DATA_SIZE);
        let heap = Heap::new(&memory, HEAP_BASE, HEAP_SIZE);
        let machine = Arc::new(Machine {
            memory,
            heap,
            hle: Registry::new(),
            monitor: Monitor::new(MAX_THREADS),
            report: Report::default(),
            options,
            images: OnceLock::new(),
            zone: OnceLock::new(),
            tls_template: OnceLock::new(),
            probes: OnceLock::new(),
            frames: AtomicU64::new(0),
            runtime: crate::runtime::Runtime::default(),
            states: States::default(),
            data: Mutex::new((DATA_BASE, HashMap::new())),
            stopped: Mutex::new(None),
            stopping: AtomicBool::new(false),
            this: OnceLock::new(),
        });
        machine.this.set(Arc::downgrade(&machine)).ok();
        // The slot calls return to when they are done (src/runtime.rs, `call`).
        let exit = HLE_BASE + crate::hle::EXIT_ID as u64 * SLOT_SIZE;
        machine.memory.write(exit, &slot_code(crate::hle::EXIT_ID));
        machine
    }

    pub fn arc(&self) -> Arc<Machine> {
        self.this.get().and_then(Weak::upgrade).expect("the machine is alive")
    }

    pub fn state<T: Default + Send + 'static>(&self) -> Arc<Mutex<T>> {
        self.states.get::<T>()
    }

    /// A zeroed block of the heap. The heap holding 4 GiB, running out stops the run.
    pub fn alloc(&self, size: u64) -> u64 {
        match self.heap.alloc(&self.memory, size, true) {
            Some(block) => block,
            None => {
                self.stop(format!("the heap is full (asked for {size} bytes)"));
                0
            }
        }
    }

    pub fn new_cstring(&self, text: &str) -> u64 {
        let address = self.alloc(text.len() as u64 + 1);
        self.memory.write(address, text.as_bytes());
        address
    }

    /// The address of `name`'s slot, writing the slot's code when it is new.
    pub fn slot_address(&self, name: &str) -> u64 {
        let (id, new) = self.hle.slot(name);
        let address = HLE_BASE + id as u64 * SLOT_SIZE;
        if new {
            self.memory.write(address, &slot_code(id));
        }
        address
    }

    /// The address of an imported data symbol: 256 bytes, filled by its answer when it has one.
    pub fn data_symbol(&self, name: &str) -> u64 {
        let mut data = self.data.lock().unwrap();
        if let Some(&address) = data.1.get(name) {
            return address;
        }
        let address = data.0;
        data.0 += 256;
        assert!(data.0 <= DATA_BASE + DATA_SIZE, "imported data is full");
        data.1.insert(name.to_string(), address);
        drop(data);
        if let Some(init) = self.hle.data_init(name) {
            init(self, address);
        }
        address
    }

    pub fn data_symbols(&self) -> HashMap<String, u64> {
        self.data.lock().unwrap().1.clone()
    }

    pub fn where_(&self, address: u64) -> String {
        if (CLIENT_BASE..ADAPTER_BASE).contains(&address) {
            return format!("client+{:#x}", address - CLIENT_BASE);
        }
        if (HLE_BASE..HLE_BASE + HLE_SIZE).contains(&address) {
            let id = ((address - HLE_BASE) / SLOT_SIZE) as u32;
            if let Some((name, _)) = self.hle.lookup(id) {
                return format!("{name} (answered)");
            }
        }
        for image in self.images.get().into_iter().flatten() {
            if (image.start..image.end).contains(&address) {
                return format!("{}+{:#x}", image.name, address - image.slide);
            }
        }
        format!("{address:#x}")
    }

    /// End the run: the first reason wins, and every thread stops at its next instruction.
    pub fn stop(&self, reason: impl Into<String>) {
        {
            let mut stopped = self.stopped.lock().unwrap();
            if stopped.is_none() {
                *stopped = Some(reason.into());
            }
        }
        self.stopping.store(true, Ordering::SeqCst);
        self.runtime.halt_all();
    }

    pub fn is_stopping(&self) -> bool {
        self.stopping.load(Ordering::Relaxed)
    }

    pub fn stop_reason(&self) -> Option<String> {
        self.stopped.lock().unwrap().clone()
    }

    pub fn stop_with(&self, stop: Stop) {
        self.stop(stop.0)
    }
}

/// An answered import's slot: `svc #id; br x16` (x16 is the return address unless the answer
/// sets it), padded to 16 bytes.
pub fn slot_code(id: u32) -> [u8; 16] {
    let mut code = [0u8; 16];
    code[0..4].copy_from_slice(&(0xD400_0001u32 | (id << 5)).to_le_bytes());
    code[4..8].copy_from_slice(&0xD61F_0200u32.to_le_bytes()); // br x16
    code
}
