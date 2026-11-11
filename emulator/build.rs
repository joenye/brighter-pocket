// Builds the C and C++ the emulator links: the dynarmic shim (src/cpu/dynarmic.cpp) against the
// dynarmic that tools/linux/setup_emulator.sh builds into .toolchain/emulator/, and the app's
// Steam session core (pocket/launcher/Pocket/PocketSteam.c), which src/steam.rs drives.
use std::path::PathBuf;

fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    let toolchain = root.join(".toolchain/emulator");
    let dynarmic = toolchain.join("dynarmic");
    if !dynarmic.join("lib/libdynarmic.a").is_file() {
        panic!("no dynarmic in {}: run tools/linux/setup_emulator.sh", dynarmic.display());
    }
    cc::Build::new()
        .cpp(true)
        .std("c++20")
        .opt_level(2)
        .include(dynarmic.join("include"))
        .include(toolchain.join("boost"))
        .file("src/cpu/dynarmic.cpp")
        .compile("pocketcpu");
    println!("cargo:rerun-if-changed=src/cpu/dynarmic.cpp");
    println!("cargo:rustc-link-search=native={}", dynarmic.join("lib").display());
    for library in ["dynarmic", "Zydis", "fmt", "mcl"] {
        println!("cargo:rustc-link-lib=static={library}");
    }
    println!("cargo:rustc-link-lib=dylib=stdc++");
    println!("cargo:rustc-link-lib=dylib=atomic"); // the 16-byte compare-and-swap of stxp

    let steam = root.join("pocket/launcher/Pocket/PocketSteam.c");
    cc::Build::new().std("c11").opt_level(1).warnings_into_errors(true).file(&steam).compile("pocketsteam");
    println!("cargo:rerun-if-changed={}", steam.display());
    println!("cargo:rerun-if-changed={}", root.join("pocket/launcher/Pocket/PocketSteam.h").display());
}
