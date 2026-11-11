//! What the emulator answers for the client's and the adapters' imports.
//!
//! Each answered import has a slot in the HLE region: `svc #id; br x16`. A call to it traps
//! into `dispatch` with the slot's id; the answer reads its arguments from the registers (the
//! Apple arm64 calling convention: integers in x0 to x7, floating point in v0 to v7, variadic
//! arguments on the stack in 8-byte slots) and returns the value for x0, or None to leave x0
//! alone. x16 holds the return address when the answer starts; an answer that continues in the
//! client's own code (an Objective-C message to one of the client's classes) sets it with
//! `Ctx::jump`. Only what the client really needs is modelled; anything else stops the run with
//! the import's name, so the model grows only where the client goes.
//!
//! Answers live in the modules below; each registers its own with `register`. State an answer
//! keeps between calls lives in its module's own type, reached with `Ctx::state::<T>()`.
use std::any::{Any, TypeId};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};

use crate::cpu::Cpu;
use crate::machine::Machine;
use crate::runtime::GuestThread;

pub mod files;
pub mod libsystem;
pub mod memory;
pub mod metal;
pub mod network;
pub mod objc;

/// Before loading: what the answers read from the app and the repository once.
pub fn prepare(m: &Machine, app: &std::path::Path) -> Result<(), String> {
    for prepare in [libsystem::prepare, files::prepare, objc::prepare, metal::prepare, network::prepare] {
        prepare(m, app)?;
    }
    Ok(())
}

/// After the run: close what the answers opened (a Steam session, a network record).
pub fn finish(m: &Machine) {
    for finish in [libsystem::finish, files::finish, objc::finish, metal::finish, network::finish] {
        finish(m);
    }
}

/// What the verdict (--check) counts against the run.
pub fn problems(m: &Machine) -> Vec<String> {
    [libsystem::problems, files::problems, objc::problems, metal::problems, network::problems].iter().flat_map(|p| p(m)).collect()
}

/// The verdict's line: Steam's state and the shader libraries accepted.
pub fn summary(m: &Machine) -> String {
    format!("Steam {}, {}", libsystem::steam_summary(m), metal::summary(m))
}

/// The report's sections from the answers.
pub fn sections(m: &Machine) -> Vec<(String, Vec<String>)> {
    [libsystem::sections, files::sections, objc::sections, metal::sections, network::sections].iter().flat_map(|s| s(m)).collect()
}

/// Why a run stopped: a message for the report.
#[derive(Debug, Clone)]
pub struct Stop(pub String);

impl<T: Into<String>> From<T> for Stop {
    fn from(text: T) -> Stop {
        Stop(text.into())
    }
}

pub type Answer = fn(&mut Ctx) -> Result<Option<u64>, Stop>;

pub const SLOT_SIZE: u64 = 16;
/// The slot `call` returns to: reaching it ends the call.
pub const EXIT_ID: u32 = 0xFFFF;

pub struct Slot {
    pub name: String,
    pub answer: Option<Answer>,
}

/// Every import's slot, by id and by name; slots are added as the loader binds imports and as
/// answers hand out function pointers of their own (a zone's functions, the Steam bridge's).
pub struct Registry {
    answers: HashMap<String, Answer>,
    data: HashMap<String, DataInit>,
    slots: RwLock<(Vec<Slot>, HashMap<String, u32>)>,
}

/// An imported data symbol's contents, written once into its 256 bytes when first bound.
pub type DataInit = fn(&Machine, u64);

impl Registry {
    pub fn new() -> Registry {
        let mut registry =
            Registry { answers: HashMap::new(), data: HashMap::new(), slots: RwLock::new((Vec::new(), HashMap::new())) };
        memory::register(&mut registry);
        crate::runtime::register(&mut registry);
        libsystem::register(&mut registry);
        files::register(&mut registry);
        objc::register(&mut registry);
        metal::register(&mut registry);
        network::register(&mut registry);
        registry
    }

    pub fn answer(&mut self, names: &[&str], answer: Answer) {
        for name in names {
            assert!(self.answers.insert(name.to_string(), answer).is_none(), "{name} answered twice");
        }
    }

    pub fn data(&mut self, name: &str, init: DataInit) {
        self.data.insert(name.to_string(), init);
    }

    pub fn has_data(&self, name: &str) -> bool {
        self.data.contains_key(name)
    }

    pub fn data_init(&self, name: &str) -> Option<DataInit> {
        self.data.get(name).copied()
    }

    /// The slot id for `name`, made if new (an unanswered import still gets one: calling it
    /// stops the run with its name).
    pub fn slot(&self, name: &str) -> (u32, bool) {
        if let Some(&id) = self.slots.read().unwrap().1.get(name) {
            return (id, false);
        }
        let mut slots = self.slots.write().unwrap();
        if let Some(&id) = slots.1.get(name) {
            return (id, false);
        }
        let id = slots.0.len() as u32;
        assert!(id < EXIT_ID, "too many answered imports");
        slots.0.push(Slot { name: name.to_string(), answer: self.answers.get(name).copied() });
        slots.1.insert(name.to_string(), id);
        (id, true)
    }

    pub fn lookup(&self, id: u32) -> Option<(String, Option<Answer>)> {
        self.slots.read().unwrap().0.get(id as usize).map(|slot| (slot.name.clone(), slot.answer))
    }
}

/// A call being answered: the calling thread's CPU, the machine, and helpers.
pub struct Ctx<'a> {
    pub m: &'a Machine,
    pub cpu: &'a mut Cpu,
    pub thread: &'a GuestThread,
    pub name: &'a str,
}

impl<'a> Ctx<'a> {
    pub fn arg(&self, n: u32) -> u64 {
        self.cpu.reg(n)
    }
    pub fn arg32(&self, n: u32) -> u32 {
        self.cpu.reg(n) as u32
    }
    pub fn set(&mut self, n: u32, value: u64) {
        self.cpu.set_reg(n, value)
    }
    /// The i-th 8-byte slot of the caller's stack arguments (variadic arguments start at 0).
    pub fn stack(&self, i: u64) -> u64 {
        self.m.memory.u64(self.cpu.sp() + 8 * i)
    }
    pub fn d(&self, n: u32) -> f64 {
        f64::from_bits(self.cpu.vector(n)[0])
    }
    pub fn s(&self, n: u32) -> f32 {
        f32::from_bits(self.cpu.vector(n)[0] as u32)
    }
    pub fn set_d(&mut self, n: u32, value: f64) {
        self.cpu.set_vector(n, value.to_bits(), 0)
    }
    pub fn set_s(&mut self, n: u32, value: f32) {
        self.cpu.set_vector(n, value.to_bits() as u64, 0)
    }
    /// Continue in `target` instead of returning to the caller (it returns to the caller itself).
    pub fn jump(&mut self, target: u64) {
        self.cpu.set_reg(16, target)
    }
    pub fn lr(&self) -> u64 {
        self.cpu.reg(30)
    }
    pub fn mem(&self) -> &crate::memory::Memory {
        &self.m.memory
    }
    pub fn cstring(&self, address: u64) -> String {
        self.m.memory.cstring(address)
    }
    /// A block of the heap (zeroed); the harness's own or one handed to the client.
    pub fn alloc(&self, size: u64) -> u64 {
        self.m.alloc(size)
    }
    /// A NUL-terminated copy of `text` on the heap.
    pub fn new_cstring(&self, text: &str) -> u64 {
        self.m.new_cstring(text)
    }
    pub fn set_errno(&self, value: i32) {
        self.m.memory.set_i32(self.thread.errno, value)
    }
    /// A line for the report's console section (what the client would have printed or logged).
    pub fn console(&self, line: impl Into<String>) {
        self.m.report.console(line)
    }
    pub fn state<T: Default + Send + 'static>(&self) -> Arc<Mutex<T>> {
        self.m.state::<T>()
    }
    /// Where an address is, for messages: client+offset, an adapter's name+offset, or hex.
    pub fn where_(&self, address: u64) -> String {
        self.m.where_(address)
    }
}

/// Per-type state of the answers: one value of each type, made on first use.
#[derive(Default)]
pub struct States {
    values: Mutex<HashMap<TypeId, Arc<dyn Any + Send + Sync>>>,
}

impl States {
    pub fn get<T: Default + Send + 'static>(&self) -> Arc<Mutex<T>> {
        let mut values = self.values.lock().unwrap();
        let value = values.entry(TypeId::of::<T>()).or_insert_with(|| Arc::new(Mutex::new(T::default())));
        value.clone().downcast::<Mutex<T>>().expect("one type, one state")
    }
}
