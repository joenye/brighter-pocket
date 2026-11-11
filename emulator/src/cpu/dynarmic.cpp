// A C interface to dynarmic's A64 JIT for the emulator's Rust (src/cpu.rs). Memory is fastmem:
// the guest's address space is one host reservation (src/memory.rs), so the JIT's loads and
// stores go straight to it; an access to an unmapped guest page faults into dynarmic, which
// recompiles that access through the callbacks below, and those report it to Rust.
#include <cstdint>
#include <cstring>
#include <optional>

#include <dynarmic/interface/A64/a64.h>
#include <dynarmic/interface/A64/config.h>
#include <dynarmic/interface/exclusive_monitor.h>

extern "C" {

// What Rust answers. `user` is the Rust side's thread state.
struct PocketCpuHooks {
    void *user;
    void (*svc)(void *user, uint32_t immediate);                        // an svc: an answered import
    void (*fallback)(void *user, uint64_t pc);                          // an instruction dynarmic does not decode
    void (*exception)(void *user, uint64_t pc, uint32_t kind);          // brk, udf, an unpredictable encoding
    bool (*mapped)(void *user, uint64_t address, uint64_t size);        // is the range mapped?
    void (*fault)(void *user, uint64_t address, uint64_t size, bool write);  // an access to unmapped memory
    uint64_t (*counter)(void *user);                                    // CNTPCT_EL0
};

struct PocketMonitor;
struct PocketCpu;

}  // extern "C"

namespace {

using Dynarmic::A64::Vector;

struct Callbacks final : Dynarmic::A64::UserCallbacks {
    PocketCpuHooks hooks{};
    uint8_t *base = nullptr;
    uint64_t ticks_left = 0;
    Dynarmic::A64::Jit *jit = nullptr;

    template <typename T>
    T read(uint64_t address) {
        if (!hooks.mapped(hooks.user, address, sizeof(T))) {
            hooks.fault(hooks.user, address, sizeof(T), false);
            return T{};
        }
        T value;
        std::memcpy(&value, base + address, sizeof(T));
        return value;
    }
    template <typename T>
    void write(uint64_t address, T value) {
        if (!hooks.mapped(hooks.user, address, sizeof(T))) {
            hooks.fault(hooks.user, address, sizeof(T), true);
            return;
        }
        std::memcpy(base + address, &value, sizeof(T));
    }
    template <typename T>
    bool write_exclusive(uint64_t address, T value, T expected) {
        if (!hooks.mapped(hooks.user, address, sizeof(T))) {
            hooks.fault(hooks.user, address, sizeof(T), true);
            return false;
        }
        auto *target = reinterpret_cast<T *>(base + address);
        return __atomic_compare_exchange_n(target, &expected, value, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    }

    std::optional<uint32_t> MemoryReadCode(uint64_t address) override { return read<uint32_t>(address); }
    uint8_t MemoryRead8(uint64_t a) override { return read<uint8_t>(a); }
    uint16_t MemoryRead16(uint64_t a) override { return read<uint16_t>(a); }
    uint32_t MemoryRead32(uint64_t a) override { return read<uint32_t>(a); }
    uint64_t MemoryRead64(uint64_t a) override { return read<uint64_t>(a); }
    Vector MemoryRead128(uint64_t a) override { return {read<uint64_t>(a), read<uint64_t>(a + 8)}; }
    void MemoryWrite8(uint64_t a, uint8_t v) override { write(a, v); }
    void MemoryWrite16(uint64_t a, uint16_t v) override { write(a, v); }
    void MemoryWrite32(uint64_t a, uint32_t v) override { write(a, v); }
    void MemoryWrite64(uint64_t a, uint64_t v) override { write(a, v); }
    void MemoryWrite128(uint64_t a, Vector v) override { write(a, v[0]); write(a + 8, v[1]); }
    bool MemoryWriteExclusive8(uint64_t a, uint8_t v, uint8_t e) override { return write_exclusive(a, v, e); }
    bool MemoryWriteExclusive16(uint64_t a, uint16_t v, uint16_t e) override { return write_exclusive(a, v, e); }
    bool MemoryWriteExclusive32(uint64_t a, uint32_t v, uint32_t e) override { return write_exclusive(a, v, e); }
    bool MemoryWriteExclusive64(uint64_t a, uint64_t v, uint64_t e) override { return write_exclusive(a, v, e); }
    bool MemoryWriteExclusive128(uint64_t a, Vector v, Vector e) override {
        if (!hooks.mapped(hooks.user, a, 16)) {
            hooks.fault(hooks.user, a, 16, true);
            return false;
        }
        auto *target = reinterpret_cast<unsigned __int128 *>(base + a);
        unsigned __int128 expected = (static_cast<unsigned __int128>(e[1]) << 64) | e[0];
        unsigned __int128 value = (static_cast<unsigned __int128>(v[1]) << 64) | v[0];
        return __atomic_compare_exchange_n(target, &expected, value, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    }

    void InterpreterFallback(uint64_t pc, size_t) override { hooks.fallback(hooks.user, pc); }
    void CallSVC(uint32_t immediate) override { hooks.svc(hooks.user, immediate); }
    void ExceptionRaised(uint64_t pc, Dynarmic::A64::Exception kind) override {
        hooks.exception(hooks.user, pc, static_cast<uint32_t>(kind));
    }
    void AddTicks(uint64_t ticks) override { ticks_left = ticks >= ticks_left ? 0 : ticks_left - ticks; }
    uint64_t GetTicksRemaining() override { return ticks_left; }
    uint64_t GetCNTPCT() override { return hooks.counter(hooks.user); }
};

struct Cpu {
    Callbacks callbacks;
    uint64_t tpidr_el0 = 0;
    uint64_t tpidrro_el0 = 0;
    Dynarmic::A64::Jit *jit = nullptr;
};

}  // namespace

extern "C" {

PocketMonitor *pocket_monitor_new(size_t processors) {
    return reinterpret_cast<PocketMonitor *>(new Dynarmic::ExclusiveMonitor(processors));
}

void pocket_monitor_free(PocketMonitor *monitor) { delete reinterpret_cast<Dynarmic::ExclusiveMonitor *>(monitor); }

PocketCpu *pocket_cpu_new(const PocketCpuHooks *hooks, uint8_t *fastmem_base, uint32_t address_bits,
                          PocketMonitor *monitor, size_t processor_id) {
    auto *cpu = new Cpu;
    cpu->callbacks.hooks = *hooks;
    cpu->callbacks.base = fastmem_base;
    Dynarmic::A64::UserConfig config;
    config.callbacks = &cpu->callbacks;
    config.processor_id = processor_id;
    config.global_monitor = reinterpret_cast<Dynarmic::ExclusiveMonitor *>(monitor);
    config.fastmem_pointer = reinterpret_cast<uintptr_t>(fastmem_base);
    config.fastmem_address_space_bits = address_bits;
    config.silently_mirror_fastmem = false;
    config.recompile_on_fastmem_failure = true;
    config.fastmem_exclusive_access = true;
    config.recompile_on_exclusive_fastmem_failure = true;
    config.tpidr_el0 = &cpu->tpidr_el0;
    config.tpidrro_el0 = &cpu->tpidrro_el0;
    config.enable_cycle_counting = true;
    config.code_cache_size = 64 * 1024 * 1024;
    config.cntfrq_el0 = 24000000;   // Apple silicon's counter: 24 MHz
    config.ctr_el0 = 0x8444c004;
    config.dczid_el0 = 4;           // DC ZVA on 64-byte blocks
    cpu->jit = new Dynarmic::A64::Jit(config);
    cpu->callbacks.jit = cpu->jit;
    return reinterpret_cast<PocketCpu *>(cpu);
}

void pocket_cpu_free(PocketCpu *handle) {
    auto *cpu = reinterpret_cast<Cpu *>(handle);
    delete cpu->jit;
    delete cpu;
}

// Runs until halted, or until `ticks` instructions have run (the turn's share); returns the
// halt reasons (dynarmic's HaltReason bits).
uint32_t pocket_cpu_run(PocketCpu *handle, uint64_t ticks) {
    auto *cpu = reinterpret_cast<Cpu *>(handle);
    cpu->callbacks.ticks_left = ticks;
    return static_cast<uint32_t>(cpu->jit->Run());
}

// From any thread: stop the run at the next block boundary.
void pocket_cpu_halt(PocketCpu *handle) {
    reinterpret_cast<Cpu *>(handle)->jit->HaltExecution(Dynarmic::HaltReason::UserDefined1);
}

uint64_t pocket_cpu_reg(PocketCpu *h, uint32_t i) { return reinterpret_cast<Cpu *>(h)->jit->GetRegister(i); }
void pocket_cpu_set_reg(PocketCpu *h, uint32_t i, uint64_t v) { reinterpret_cast<Cpu *>(h)->jit->SetRegister(i, v); }
uint64_t pocket_cpu_sp(PocketCpu *h) { return reinterpret_cast<Cpu *>(h)->jit->GetSP(); }
void pocket_cpu_set_sp(PocketCpu *h, uint64_t v) { reinterpret_cast<Cpu *>(h)->jit->SetSP(v); }
uint64_t pocket_cpu_pc(PocketCpu *h) { return reinterpret_cast<Cpu *>(h)->jit->GetPC(); }
void pocket_cpu_set_pc(PocketCpu *h, uint64_t v) { reinterpret_cast<Cpu *>(h)->jit->SetPC(v); }
void pocket_cpu_vector(PocketCpu *h, uint32_t i, uint64_t out[2]) {
    auto v = reinterpret_cast<Cpu *>(h)->jit->GetVector(i);
    out[0] = v[0];
    out[1] = v[1];
}
void pocket_cpu_set_vector(PocketCpu *h, uint32_t i, uint64_t lo, uint64_t hi) {
    reinterpret_cast<Cpu *>(h)->jit->SetVector(i, {lo, hi});
}
uint64_t pocket_cpu_tpidr(PocketCpu *h) { return reinterpret_cast<Cpu *>(h)->tpidr_el0; }
void pocket_cpu_set_tpidr(PocketCpu *h, uint64_t v) { reinterpret_cast<Cpu *>(h)->tpidr_el0 = v; }

// From any thread: forget the translated code for a range (it is translated again from memory);
// the CPU halts if it is running and drops it before running on.
void pocket_cpu_invalidate(PocketCpu *h, uint64_t start, uint64_t length) {
    reinterpret_cast<Cpu *>(h)->jit->InvalidateCacheRange(start, length);
}

}  // extern "C"
