#!/usr/bin/env python3
"""Build the app with Xcode's toolchain: the unsigned .ipa for External JIT, as the
platform's tools/package_ipa.sh builds it, named Brighter Pocket; or, with --simulator,
the same app for the iOS Simulator (tools/run_simulator.py runs it).

usage: tools/build_ios.py [--simulator] [--for-client [DIR]] [--out PATH] [--name "Pocket"]

Needs Xcode (DEVELOPER_DIR in local.env when xcode-select names another developer
folder). It follows the platform's TolkaraDiagnostics target (project.yml, AppBase): the
launcher, the runtime and the shader-container rewrap compiled for arm64 iOS 17; the
compatibility libraries built by the platform's own tools/build_shims.py, generic (one
adapter per translation/<Framework>, this layer's included) or, with --for-client, made
for the client (tools/classify.py plans each import); every profile, checked by the
platform's tools/check_profile.py; Info.plist written from launcher/Info.plist with the
keys Xcode would generate; the app icon from the asset catalog's PNGs as loose files. As
package_ipa.sh does, everything is signed ad hoc (codesign -s -) only to declare the two
memory capabilities, the execution mode is preset to External JIT, and the system root
certificates are left out. A sideloading tool (SideStore, AltStore, Sideloadly) signs the
.ipa again with your Apple ID; open it with JIT enabled (StikDebug or the sideloader) to
run a game. The simulator needs no JIT: memory it maps executes.

The device build lands in build/ios/Payload (the emulator loads the adapters from there)
and is zipped to build/BrighterPocket-unsigned.ipa; the simulator build is the app folder
build/ios-simulator/Payload/BrighterPocket.app.
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

MINIMUM_OS = "17.0"
# The app's full name, which its own text uses (pocket/patches/0035), and its executable and
# folder (build/ios*/Payload/BrighterPocket.app), whatever its Home Screen name (--name).
APP_NAME = common.setting("TOLKARA_APP_NAME", "Brighter Pocket")
EXECUTABLE = "BrighterPocket"
# launcher/App.entitlements as project.yml generates it: the two memory capabilities.
ENTITLEMENTS = {"com.apple.developer.kernel.increased-memory-limit": True,
                "com.apple.developer.kernel.extended-virtual-addressing": True}
DEVICE = {"sdk": "iphoneos", "target": f"arm64-apple-ios{MINIMUM_OS}", "shims": "ios",
          "platform": "iPhoneOS", "build": "ios"}
SIMULATOR = {"sdk": "iphonesimulator", "target": f"arm64-apple-ios{MINIMUM_OS}-simulator", "shims": "iossim",
             "platform": "iPhoneSimulator", "build": "ios-simulator"}


def toolchain(simulator: bool) -> dict:
    tools = dict(SIMULATOR if simulator else DEVICE)
    tools["sdk_path"] = common.sdk_path(tools["sdk"])
    tools["sdk_version"] = common.xcrun("--sdk", tools["sdk"], "--show-sdk-version")
    tools["env"] = common.xcode_env()
    return tools


def run(command: list, **kwargs) -> None:
    kwargs.setdefault("env", common.xcode_env())
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
    clang = ["xcrun", "--sdk", tools["sdk"], "clang", "-target", tools["target"], "-isysroot", str(tools["sdk_path"]),
             "-O2", "-g", "-fmodules", "-fobjc-arc", "-Wno-deprecated-declarations",
             "-I", str(tree / "runtime"), "-I", str(tree / "translation/Metal")]
    objects.mkdir(parents=True, exist_ok=True)
    jobs = []
    for source in sources(tree):
        out = objects / (str(source.relative_to(tree)).replace("/", "_") + ".o")
        jobs.append([*clang, "-c", str(source), "-o", str(out)])
    with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        for job in pool.map(lambda j: subprocess.run(j, env=tools["env"], capture_output=True, text=True), jobs):
            if job.returncode:
                raise SystemExit(f"compile failed: {job.args[-3]}\n{job.stderr}")
    run([*clang, *[j[-1] for j in jobs], "-o", str(executable),
         "-Wl,-rpath,@executable_path/Frameworks", "-framework", "Security", "-lz"])


def info_plist(tree: Path, tools: dict, name: str, bundle_id: str, executable: str, icons: list[str]) -> dict:
    """launcher/Info.plist with its build settings filled in, and what Xcode generates beside it
    (project.yml: GENERATE_INFOPLIST_FILE and the INFOPLIST_KEY_ settings of AppBase)."""
    text = (tree / "launcher/Info.plist").read_text()
    for key, value in {"CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1", "GUEST_RUNTIME": "emulated",
                       "TOLKARA_MODE": "external-jit", "TOLKARA_APP_NAME": APP_NAME}.items():
        text = text.replace(f"$({key})", value)
    plist = plistlib.loads(text.encode())
    if "$(" in text:
        raise SystemExit("launcher/Info.plist names a build setting this builder does not know")
    plist.update({
        "CFBundleDevelopmentRegion": "en", "CFBundleExecutable": executable, "CFBundleIdentifier": bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleName": APP_NAME, "CFBundleDisplayName": name,
        "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": [tools["platform"]], "MinimumOSVersion": MINIMUM_OS,
        "DTPlatformName": tools["sdk"], "DTSDKName": tools["sdk"] + tools["sdk_version"],
        "LSRequiresIPhoneOS": True, "UIDeviceFamily": [1, 2], "UIRequiredDeviceCapabilities": ["arm64"],
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        "UILaunchScreen": {}, "UIRequiresFullScreen": False, "LSSupportsOpeningDocumentsInPlace": True,
        "UISupportedInterfaceOrientations~iphone": ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
                                                   "UIInterfaceOrientationPortrait"],
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


def asset_images(tree: Path, tools: dict, build: Path, app: Path) -> None:
    """The asset catalog's images (the loading screen's lockup) compiled into Assets.car, as
    Xcode's build does, for UIImage imageNamed:. The app icon stays loose files (icons above),
    so its set is left out here."""
    catalog = build / "Assets.xcassets"
    shutil.copytree(tree / "launcher/Assets.xcassets", catalog, ignore=shutil.ignore_patterns("*.appiconset"))
    if not any(catalog.glob("*.imageset")):
        return
    run(["xcrun", "--sdk", tools["sdk"], "actool", "--compile", str(app), "--platform", tools["sdk"],
         "--minimum-deployment-target", MINIMUM_OS, "--target-device", "iphone", "--target-device", "ipad",
         "--output-partial-info-plist", str(build / "assets-info.plist"), "--errors", "--warnings", str(catalog)])
    if not (app / "Assets.car").exists():
        raise SystemExit("actool made no Assets.car from launcher/Assets.xcassets")


def sign(app: Path, build: Path, simulator: bool) -> None:
    """Ad hoc. A device build declares the two memory capabilities; the simulator's taskgated
    kills an ad hoc app that claims them (and the simulator needs neither)."""
    entitlements = build / "entitlements.plist"
    entitlements.write_bytes(plistlib.dumps(ENTITLEMENTS))
    for library in sorted((app / "Frameworks").glob("*.dylib")):
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(library)])
    claims = [] if simulator else ["--entitlements", str(entitlements)]
    run(["codesign", "--force", "--sign", "-", "--timestamp=none", *claims, str(app)])


def compatibility_libraries(tree: Path, tools: dict, app: Path, executable: Path | None) -> None:
    """The platform's own builder, as tools/build_emulated_guest.sh runs it: generic (one adapter
    per translation/<Framework>, resolved by name on the device), or made for one executable
    (tools/classify.py plans each import; the library map goes to Guest/libraries.json, and an
    import nothing provides stops the launch instead of becoming a stub)."""
    guest = app / "Guest"
    if executable is None:
        command = [sys.executable, "tools/build_shims.py", tools["shims"], "generic", str(app / "Frameworks"),
                   str(guest / "absent.json")]
    else:
        work = common.BUILD / f"native-{tools['build']}"
        work.mkdir(parents=True, exist_ok=True)
        # classify.py plans against the iOS SDK whichever platform the adapters are for, as
        # build_emulated_guest.sh does.
        run([sys.executable, "tools/classify.py", "--bundled", str(executable), "--sdk", str(common.sdk_path("iphoneos")),
             "--out", str(work / "SURFACE.md"), "--map", str(work / "map.json"), "--raw", str(work / "surface.json")],
            cwd=tree)
        shutil.copy2(work / "map.json", guest / "libraries.json")
        command = [sys.executable, "tools/build_shims.py", tools["shims"], str(work / "surface.json"), str(app / "Frameworks")]
    result = subprocess.run(command, cwd=tree, env=tools["env"], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"tools/build_shims.py failed:\n{result.stdout}{result.stderr}")
    print(result.stdout.rstrip())


def build(out: Path | None, name: str, executable: Path | None, simulator: bool) -> Path:
    """Builds the app; returns the .ipa (device) or the .app (simulator)."""
    tools = toolchain(simulator)
    build_dir = common.BUILD / tools["build"]
    tree = common.BUILD / "platform"
    prepare.prepare(tree)
    if build_dir.exists():
        shutil.rmtree(build_dir)
    executable_name = EXECUTABLE   # the same whatever the Home Screen name
    app = build_dir / "Payload" / f"{executable_name}.app"
    (app / "Frameworks").mkdir(parents=True)
    guest = app / "Guest"
    (guest / "Profiles").mkdir(parents=True)

    print(f"compiling the launcher and runtime ({tools['target']})")
    compile_app(tree, tools, build_dir / "objects", app / executable_name)

    print("building the compatibility libraries (" + ("generic" if executable is None else f"for {executable.name}") + ")")
    compatibility_libraries(tree, tools, app, executable)

    # TOLKARA_PROFILES (pocket/layer.env: brighter-shores) names the profiles the app carries,
    # as the platform's own build does with pocket/patches/0022; empty means all.
    wanted = [name for name in common.setting("TOLKARA_PROFILES", "").split(":") if name]
    for profile in sorted((tree / "profiles").glob("*/profile.json")):
        if wanted and profile.parent.name not in wanted:
            continue
        run([sys.executable, str(tree / "tools/check_profile.py"), str(profile)])
        shutil.copy2(profile, guest / "Profiles" / f"{profile.parent.name}.json")

    asset_images(tree, tools, build_dir, app)
    bundle_id = common.setting("TOLKARA_BUNDLE_ID", "local.tolkara.app")
    plist = info_plist(tree, tools, name, bundle_id, executable_name, icons(tree, app))
    (app / "Info.plist").write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_BINARY))
    (app / "PkgInfo").write_text("APPL????")

    sign(app, build_dir, simulator)
    if simulator:
        if out is not None:
            raise SystemExit("--out names the .ipa; the simulator build stays in " + str(app.parent))
        print(f"simulator build: {app}")
        return app
    out = out or common.BUILD / "BrighterPocket-unsigned.ipa"
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    run(["zip", "-qry", str(out.resolve()), "Payload"], cwd=build_dir)
    print(f"unsigned build: {out} ({out.stat().st_size / 1e6:.1f} MB)")
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, help="the .ipa (default: build/BrighterPocket-unsigned.ipa)")
    parser.add_argument("--name", default=common.setting("TOLKARA_DISPLAY_NAME", "Pocket"),
                        help="the app's name on the device (default: TOLKARA_DISPLAY_NAME, pocket/layer.env)")
    parser.add_argument("--simulator", action="store_true", help="build for the iOS Simulator instead of a device")
    parser.add_argument("--for-client", nargs="?", const="newest", metavar="DIR",
                        help="make the compatibility libraries for the downloaded client (default: the newest) "
                             "instead of generic ones")
    args = parser.parse_args()
    executable = None
    if args.for_client:
        app = common.client_app(None if args.for_client == "newest" else Path(args.for_client))
        executable = app / common.BUNDLE_EXECUTABLE
    build(args.out, args.name, executable, args.simulator)


if __name__ == "__main__":
    main()
