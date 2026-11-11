#!/usr/bin/env python3
"""Build the app on Linux: the unsigned .ipa for External JIT, as the platform's
tools/package_ipa.sh builds it on a Mac, from the prepared tree.

usage: tools/build_ios.py [--out build/BrighterPocket-unsigned.ipa] [--name "Brighter Pocket"]

Needs an iPhoneOS SDK (IOS_SDK in local.env), the LLVM toolchain and ldid that
tools/linux/setup_toolchain.sh installs under .toolchain/ (POCKET_LLVM, LDID override).
It follows the platform's TolkaraDiagnostics target (project.yml, AppBase): the launcher,
the runtime and the shader-container rewrap compiled for arm64 iOS 17 and linked with
LLVM's ld64.lld; the compatibility libraries built by the platform's own
tools/build_shims.py in its generic mode (one adapter per translation/<Framework>,
this layer's included), with tools/linux/xcrun standing in for Xcode's; every profile,
checked by the platform's tools/check_profile.py; Info.plist written from
launcher/Info.plist with the keys Xcode would generate; the app icon from the asset
catalog's PNGs (there is no actool on Linux). As package_ipa.sh does, everything is
signed ad hoc only to declare the two memory capabilities, the execution mode is preset
to External JIT, and the system root certificates are left out. A sideloading tool
(SideStore, AltStore, Sideloadly) signs it again with your Apple ID; open it with JIT
enabled (StikDebug or the sideloader) to run a game.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402
import prepare  # noqa: E402

TARGET = "arm64-apple-ios17.0"
MINIMUM_OS = "17.0"
# launcher/App.entitlements as project.yml generates it: the two memory capabilities.
ENTITLEMENTS = {"com.apple.developer.kernel.increased-memory-limit": True,
                "com.apple.developer.kernel.extended-virtual-addressing": True}


def toolchain() -> dict:
    sdk = common.setting("IOS_SDK")
    if not sdk or not (Path(sdk) / "SDKSettings.json").is_file():
        raise SystemExit("set IOS_SDK in local.env to an iPhoneOS SDK folder")
    llvm = Path(common.setting("POCKET_LLVM", str(common.ROOT / ".toolchain/llvm")))
    ldid = Path(common.setting("LDID", str(common.ROOT / ".toolchain/ldid")))
    for tool in (llvm / "bin/clang", llvm / "bin/ld64.lld", ldid):
        if not tool.is_file():
            raise SystemExit(f"{tool} is missing: run tools/linux/setup_toolchain.sh")
    if not list((llvm / "lib/clang").glob("*/lib/darwin/libclang_rt.ios.a")):
        raise SystemExit("the toolchain lacks libclang_rt.ios.a: run tools/linux/setup_toolchain.sh")
    return {"sdk": Path(sdk), "llvm": llvm, "ldid": ldid}


def run(command: list, **kwargs) -> None:
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise SystemExit(f"failed: {' '.join(map(str, command))}\n{result.stdout}{result.stderr}")


def sources(tree: Path) -> list[Path]:
    """The AppBase target's sources: launcher/ and runtime/ whole, and the shader-container rewrap."""
    found = []
    for folder in ("launcher", "runtime"):
        found += [p for p in sorted((tree / folder).rglob("*")) if p.suffix in (".c", ".m", ".S")]
    return found + [tree / "translation/Metal/LibraryContainer.m"]


def compile_app(tree: Path, tools: dict, objects: Path, executable: Path) -> None:
    clang = [str(tools["llvm"] / "bin/clang"), "-target", TARGET, "-isysroot", str(tools["sdk"]),
             "-O2", "-g", "-fmodules", "-fobjc-arc", "-Wno-deprecated-declarations", "-Wno-unused-command-line-argument",
             "-I", str(tree / "runtime"), "-I", str(tree / "translation/Metal")]
    objects.mkdir(parents=True, exist_ok=True)
    jobs = []
    for source in sources(tree):
        out = objects / (str(source.relative_to(tree)).replace("/", "_") + ".o")
        jobs.append([*clang, "-c", str(source), "-o", str(out)])
    with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        for job in pool.map(lambda j: subprocess.run(j, capture_output=True, text=True), jobs):
            if job.returncode:
                raise SystemExit(f"compile failed: {job.args[-3]}\n{job.stderr}")
    run([*clang, "-fuse-ld=lld", *[j[-1] for j in jobs], "-o", str(executable),
         "-Wl,-rpath,@executable_path/Frameworks", "-framework", "Security", "-lz"])


def info_plist(tree: Path, name: str, bundle_id: str, executable: str, icons: list[str]) -> dict:
    """launcher/Info.plist with its build settings filled in, and what Xcode generates beside it
    (project.yml: GENERATE_INFOPLIST_FILE and the INFOPLIST_KEY_ settings of AppBase)."""
    text = (tree / "launcher/Info.plist").read_text()
    for key, value in {"CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1", "GUEST_RUNTIME": "emulated",
                       "TOLKARA_MODE": "external-jit"}.items():
        text = text.replace(f"$({key})", value)
    plist = plistlib.loads(text.encode())
    if "$(" in text:
        raise SystemExit("launcher/Info.plist names a build setting this builder does not know")
    plist.update({
        "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": executable, "CFBundleIdentifier": bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": name, "CFBundleDisplayName": name,
        "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"], "MinimumOSVersion": MINIMUM_OS,
        "DTPlatformName": "iphoneos", "DTSDKName": "iphoneos" + json.loads((Path(common.setting("IOS_SDK")) / "SDKSettings.json").read_text())["Version"],
        "LSRequiresIPhoneOS": True, "UIDeviceFamily": [1, 2], "UIRequiredDeviceCapabilities": ["arm64"],
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        "UILaunchScreen": {}, "UIRequiresFullScreen": False, "LSSupportsOpeningDocumentsInPlace": True,
        "UISupportedInterfaceOrientations~iphone": ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
                                                 "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown"],
    })
    if icons:
        primary = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": icons, "CFBundleIconName": "AppIcon"}}
        plist["CFBundleIcons"] = primary
        plist["CFBundleIcons~ipad"] = primary
    return plist


def icons(tree: Path, app: Path) -> list[str]:
    """The asset catalog's light app icons as loose files (CFBundleIconFiles): each size as
    AppIcon<size>@<scale>.png, and again with ~ipad, the names iOS looks up without a catalog."""
    catalog = tree / "launcher/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((catalog / "Contents.json").read_text())
    names = []
    for image in contents.get("images", []):
        filename, size, scale = image.get("filename"), image.get("size", ""), image.get("scale")
        if not filename or not scale or image.get("appearances") or image.get("idiom") not in ("universal", "iphone", "ipad"):
            continue
        base = f"AppIcon{size}"
        for suffix in ("", "~ipad"):
            shutil.copy2(catalog / filename, app / f"{base}@{scale}{suffix}.png")
        if base not in names:
            names.append(base)
    return names


def sign(tools: dict, app: Path, executable: Path, build: Path) -> None:
    entitlements = build / "entitlements.plist"
    entitlements.write_bytes(plistlib.dumps(ENTITLEMENTS))
    for library in sorted((app / "Frameworks").glob("*.dylib")):
        run([str(tools["ldid"]), "-S", str(library)])
    run([str(tools["ldid"]), f"-S{entitlements}", str(executable)])


def compatibility_libraries(tree: Path, tools: dict, app: Path, executable: Path | None) -> None:
    """The platform's own builder, as tools/build_emulated_guest.sh runs it: generic (one adapter
    per translation/<Framework>, resolved by name on the device), or made for one executable
    (tools/classify.py plans each import; the library map goes to Guest/libraries.json, and an
    import nothing provides stops the launch instead of becoming a stub)."""
    env = dict(os.environ, IOS_SDK=str(tools["sdk"]), POCKET_LLVM=str(tools["llvm"]),
               PATH=f"{common.ROOT / 'tools/linux'}{os.pathsep}{os.environ['PATH']}")
    guest = app / "Guest"
    if executable is None:
        command = [sys.executable, "tools/build_shims.py", "ios", "generic", str(app / "Frameworks"), str(guest / "absent.json")]
    else:
        work = common.BUILD / "native-ios"
        work.mkdir(parents=True, exist_ok=True)
        run([sys.executable, "tools/classify.py", "--bundled", str(executable), "--sdk", str(tools["sdk"]),
             "--out", str(work / "SURFACE.md"), "--map", str(work / "map.json"), "--raw", str(work / "surface.json")],
            cwd=tree, env=env)
        shutil.copy2(work / "map.json", guest / "libraries.json")
        command = [sys.executable, "tools/build_shims.py", "ios", str(work / "surface.json"), str(app / "Frameworks")]
    result = subprocess.run(command, cwd=tree, env=env, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"tools/build_shims.py failed:\n{result.stdout}{result.stderr}")
    print(result.stdout.rstrip())


def build(out: Path, name: str, executable: Path | None) -> None:
    tools = toolchain()
    build_dir = common.BUILD / "ios"
    tree = common.BUILD / "platform"
    prepare.prepare(tree)
    if build_dir.exists():
        shutil.rmtree(build_dir)
    executable_name = name.replace(" ", "")
    app = build_dir / "Payload" / f"{executable_name}.app"
    (app / "Frameworks").mkdir(parents=True)
    guest = app / "Guest"
    (guest / "Profiles").mkdir(parents=True)

    print("compiling the launcher and runtime")
    compile_app(tree, tools, build_dir / "objects", app / executable_name)

    print("building the compatibility libraries (" + ("generic" if executable is None else f"for {executable.name}") + ")")
    compatibility_libraries(tree, tools, app, executable)

    for profile in sorted((tree / "profiles").glob("*/profile.json")):
        run([sys.executable, str(tree / "tools/check_profile.py"), str(profile)])
        shutil.copy2(profile, guest / "Profiles" / f"{profile.parent.name}.json")

    bundle_id = common.setting("TOLKARA_BUNDLE_ID", "local.tolkara.app")
    plist = info_plist(tree, name, bundle_id, executable_name, icons(tree, app))
    (app / "Info.plist").write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_BINARY))
    (app / "PkgInfo").write_text("APPL????")

    sign(tools, app, app / executable_name, build_dir)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    run(["zip", "-qry", str(out.resolve()), "Payload"], cwd=build_dir)
    print(f"unsigned build: {out} ({out.stat().st_size / 1e6:.1f} MB)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=common.BUILD / "BrighterPocket-unsigned.ipa")
    parser.add_argument("--name", default="Brighter Pocket", help="the app's name on the device")
    parser.add_argument("--for-client", nargs="?", const="newest", metavar="DIR",
                        help="make the compatibility libraries for the downloaded client (default: the newest) "
                             "instead of generic ones")
    args = parser.parse_args()
    executable = None
    if args.for_client:
        app = common.client_app(None if args.for_client == "newest" else Path(args.for_client))
        executable = app / common.BUNDLE_EXECUTABLE
    build(args.out, args.name, executable)


if __name__ == "__main__":
    main()
