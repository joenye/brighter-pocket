#!/usr/bin/env python3
"""Run Brighter Pocket in the iOS Simulator with the client, signed in to Steam.

usage: tools/run_simulator.py [--no-build] [--simulator NAME] [--seconds N] [--no-steam | --offline] [--local-signing]
                              [--launcher-arg ARG]... [--env NAME=VALUE]...

Builds the app for the simulator (tools/build_ios.py --simulator --for-client), boots the
simulator (SIMULATOR in local.env, default an iPad Pro 13-inch (M5)) and opens Simulator.app,
installs the app, copies the staged client into its Documents (Valve's libsteam_api.dylib
left out, as on a device), and starts Brighter Shores with --native-startup (External JIT:
the simulator is a Mac process, so the memory it maps executes without a JIT enabler). The
console goes to build/simulator/<time>/console.log and to this terminal; Ctrl-C (or
--seconds) ends the run, with a screenshot and the runtime's own log beside it.

Steam: the app signs in with the refresh token DepotDownloader remembers for STEAM_USER (its
account.config under ~/Library/Application Support/IsolatedStorage), passed in the app's
environment for this run only, never printed; --no-steam leaves the app's own sign-in
screens to ask; --offline plays offline at once (no Steam session: one that would sign the
account out of a game played elsewhere).

Shaders: the simulator's Metal runs no desktop AIR, so the client's shader libraries are
translated for the simulator once (tools/translate_shaders.py --simulator) and copied to the
app's Documents/TranslatedShaders (pocket/patches/0008).

Metal: the app runs with Metal's validation layer (MTL_DEBUG_LAYER=1). Without it the
simulator's Metal fails the game's first command buffer (an internal error) and the screen
stays black; through the layer the same frames draw. --env MTL_DEBUG_LAYER=0 turns it off.

--local-signing runs the game's code as Local signing does on a device: from a page container,
a copy of the client's own __TEXT pages (built for the simulator, signed ad hoc), which the
runtime matches to the executable before it maps those pages. The executable is unchanged.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import zlib
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_ios  # noqa: E402
import common  # noqa: E402
import stage_client  # noqa: E402
import translate_shaders  # noqa: E402

DEFAULT_SIMULATOR = "iPad Pro 13-inch (M5)"
PROFILE = "brighter-shores"
ISOLATED_STORAGE = Path.home() / "Library/Application Support/IsolatedStorage"


def simctl(*args: str, check: bool = True, capture: bool = True, timeout: float = 300) -> str:
    try:
        result = subprocess.run(["xcrun", "simctl", *args], env=common.xcode_env(), capture_output=capture, text=True,
                                timeout=timeout)
    except subprocess.TimeoutExpired:
        raise SystemExit(f"simctl {' '.join(args)} did not finish in {timeout:.0f} s")
    if check and result.returncode:
        raise SystemExit(f"simctl {' '.join(args)} failed:\n{result.stderr if capture else ''}")
    return result.stdout if capture else ""


def stop_app(udid: str, bundle: str) -> None:
    """Ends the app; a simulator that does not answer (an app left stuck by a crash can wedge it)
    is shut down and booted again."""
    try:
        subprocess.run(["xcrun", "simctl", "terminate", udid, bundle], env=common.xcode_env(), capture_output=True,
                       timeout=30)
    except subprocess.TimeoutExpired:
        print("the simulator did not answer; restarting it")
        simctl("shutdown", udid, check=False, timeout=120)
        simctl("boot", udid, check=False)
        simctl("bootstatus", udid, "-b")


# --- DepotDownloader's remembered login -------------------------------------------------------
def fields(data: bytes) -> list[tuple[int, bytes]]:
    """The length-delimited fields of a protobuf message, stopping at a wire type other than 0 or 2."""
    out, i = [], 0

    def varint() -> int:
        nonlocal i
        value, shift = 0, 0
        while True:
            byte = data[i]
            i += 1
            value |= (byte & 127) << shift
            shift += 7
            if byte < 128:
                return value
    try:
        while i < len(data):
            key = varint()
            if key & 7 == 2:
                size = varint()
                out.append((key >> 3, data[i:i + size]))
                i += size
            elif key & 7 == 0:
                varint()
            else:
                break
    except IndexError:
        pass
    return out


def saved_refresh_token(account: str) -> str:
    """account.config is deflated protobuf-net; its field 4 is the LoginTokens map (account name
    -> refresh token). The newest file naming the account wins (as emulator/src/steam.rs reads it)."""
    newest: tuple[float, str] | None = None
    for path in ISOLATED_STORAGE.glob("*/*/*/AssemFiles/account.config"):
        try:
            plain = zlib.decompress(path.read_bytes(), -15)
        except (OSError, zlib.error):
            continue
        for number, entry in fields(plain):
            pair = dict(fields(entry)) if number == 4 else {}
            if pair.get(1) == account.encode() and pair.get(2):
                modified = path.stat().st_mtime
                if newest is None or modified > newest[0]:
                    newest = (modified, pair[2].decode())
    if newest is None:
        raise SystemExit(f"DepotDownloader remembers no login for {account} under {ISOLATED_STORAGE} "
                         "(or run with --no-steam and sign in on the app's screens)")
    return newest[1]


# --- the simulator ------------------------------------------------------------------------------
def simulator_id(name: str) -> str:
    devices = json.loads(simctl("list", "devices", "available", "-j"))["devices"]
    found = [d for group in devices.values() for d in group if name in (d["name"], d["udid"])]
    if not found:
        raise SystemExit(f"no available simulator named {name} (set SIMULATOR in local.env; xcrun simctl list devices)")
    found.sort(key=lambda d: d["state"] != "Booted")
    return found[0]["udid"]


def boot(udid: str) -> None:
    simctl("boot", udid, check=False)
    simctl("bootstatus", udid, "-b")
    # Xcode 27 has no Simulator.app: its Device Hub shows the screen. Older Xcodes open it here.
    shown = subprocess.run(["open", "-b", "com.apple.iphonesimulator", "--args", "-CurrentDeviceUDID", udid],
                           capture_output=True).returncode == 0
    if not shown:
        print("the simulator runs without a window here: watch it in Xcode's Device Hub (screenshots are saved)")


def screenshots(udid: str, run: Path) -> None:
    """screen.png, or screen-<n>.png for each display of a simulator with several (like the iPhone Duo)."""
    def shoot(*extra: str, name: str) -> bool:
        try:
            return subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", *extra, str(run / name)],
                                  env=common.xcode_env(), capture_output=True, timeout=30).returncode == 0
        except subprocess.TimeoutExpired:
            return False
    if not shoot(name="screen.png"):
        for display in ("1", "2", "3"):
            shoot(f"--display={display}", name=f"screen-{display}.png")


def copy_client(container: Path) -> None:
    stage = common.BUILD / "stage"
    install = stage_client.installer()
    app = common.client_app()
    stage_client.check_executable(app / common.BUNDLE_EXECUTABLE)
    install.stage(app, stage)
    documents = container / "Documents"
    documents.mkdir(parents=True, exist_ok=True)
    subprocess.run(["rsync", "-a", "--delete", f"{stage / install.FOLDER}/", f"{documents / install.FOLDER}/"], check=True)
    print(f"client copied to {documents / install.FOLDER}")


def copy_shaders(container: Path) -> None:
    """The client's shader libraries translated for the simulator (whose Metal runs no desktop
    AIR, pocket/patches/0008), made where missing, into Documents/TranslatedShaders."""
    out = common.BUILD / "translated-shaders-simulator"
    libraries = translate_shaders.distinct_libraries(common.client_app())
    failed = translate_shaders.translate_all(libraries, out, common.BUILD / "platform", simulator=True)
    if failed:
        raise SystemExit(f"{len(failed)} shader libraries did not translate; their reasons are in {out}/<key>.error")
    destination = container / translate_shaders.DESTINATION
    subprocess.run(["rsync", "-a", "--delete", "--exclude", "*.error", f"{out}/", f"{destination}/"], check=True)
    print(f"{len(libraries)} shader libraries, translated for the simulator, copied to {destination}")


def copy_page_container(container: Path) -> None:
    """Local signing as on a device: the page container (a signed copy of the client's own
    __TEXT, pocket/patches/0009), here for the simulator and signed ad hoc, in
    Documents/LocalSigning/<SHA-256 of the executable>.dylib."""
    executable = common.client_app() / common.BUNDLE_EXECUTABLE
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    output = common.BUILD / "signed-image-simulator" / f"{digest}.dylib"
    tree = common.BUILD / "platform"
    result = subprocess.run([sys.executable, "tools/build_signed_container.py", "--guest", str(executable),
                             "--platform", "iossimulator", "--sign", "adhoc", "--output", str(output)],
                            cwd=tree, env=common.xcode_env(), capture_output=True, text=True, timeout=600)
    if result.returncode:
        raise SystemExit(f"the page container was not built:\n{result.stdout}{result.stderr}")
    print(result.stdout.strip().splitlines()[-1])
    destination = container / "Documents/LocalSigning"
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(output, destination / output.name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--no-build", action="store_true", help="install the last simulator build as it is")
    parser.add_argument("--simulator", default=common.setting("SIMULATOR", DEFAULT_SIMULATOR), help="a simulator's name or UDID")
    parser.add_argument("--seconds", type=float, help="end the run after this long (default: at Ctrl-C)")
    parser.add_argument("--no-steam", action="store_true", help="name no Steam login: the app's sign-in screens ask")
    parser.add_argument("--offline", action="store_true", help="play offline at once, with no Steam session")
    parser.add_argument("--launcher-arg", action="append", default=[], metavar="ARG",
                        help="one more argument for the launcher (e.g. --measure-native, --sample-native)")
    parser.add_argument("--env", action="append", default=[], metavar="NAME=VALUE",
                        help="one more variable in the app's environment (e.g. MTL_SHADER_VALIDATION=1)")
    parser.add_argument("--local-signing", action="store_true",
                        help="run the game's code from a page container, as Local signing does on a device")
    args = parser.parse_args()

    environment: dict[str, str] = {"MTL_DEBUG_LAYER": "1", **dict(item.split("=", 1) for item in args.env)}
    if args.offline:
        environment["POCKET_STEAM_OFFLINE"] = "1"
    elif not args.no_steam:
        account = common.setting("STEAM_USER")
        if not account:
            raise SystemExit("set STEAM_USER in local.env, or run with --no-steam")
        environment.update({"POCKET_STEAM_ACCOUNT": account, "POCKET_STEAM_REFRESH_TOKEN": saved_refresh_token(account)})

    app = common.BUILD / "ios-simulator/Payload/BrighterPocket.app"
    if not args.no_build:
        client = common.client_app() / common.BUNDLE_EXECUTABLE
        app = build_ios.build(None, common.setting("TOLKARA_DISPLAY_NAME", "Pocket"), client, simulator=True)
    elif not app.is_dir():
        raise SystemExit(f"no {app}: run without --no-build")
    bundle = common.setting("TOLKARA_BUNDLE_ID", "local.tolkara.app")

    udid = simulator_id(args.simulator)
    print(f"simulator {args.simulator} ({udid})")
    boot(udid)
    stop_app(udid, bundle)
    simctl("install", udid, str(app))
    container = Path(simctl("get_app_container", udid, bundle, "data").strip())
    copy_client(container)
    copy_shaders(container)
    if args.local_signing:
        copy_page_container(container)
    (container / "Documents/native-guest.log").unlink(missing_ok=True)

    run = common.BUILD / "simulator" / datetime.now().strftime("%Y%m%d-%H%M%S")
    run.mkdir(parents=True)
    env = common.xcode_env()
    env.update({f"SIMCTL_CHILD_{key}": value for key, value in environment.items()})
    mode = "local-signing" if args.local_signing else "external-jit"
    command = ["xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", udid, bundle,
               f"--app={PROFILE}", "--native-startup", f"--execution-mode={mode}", *args.launcher_arg]
    print(f"starting Brighter Shores; console in {run / 'console.log'}"
          + ("" if args.seconds else " (Ctrl-C ends the run)"))
    with (run / "console.log").open("wb") as log:
        process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        start = time.monotonic()
        stopped = False

        def stop(*_: object) -> None:
            nonlocal stopped
            stopped = True
        signal.signal(signal.SIGINT, stop)
        os.set_blocking(process.stdout.fileno(), False)
        while process.poll() is None and not stopped and (args.seconds is None or time.monotonic() - start < args.seconds):
            chunk = process.stdout.read()
            if chunk:
                log.write(chunk)
                sys.stdout.buffer.write(chunk)
                sys.stdout.flush()
            else:
                time.sleep(0.1)
        screenshots(udid, run)
        if process.poll() is None:
            process.terminate()
        stop_app(udid, bundle)
        rest = process.stdout.read()
        if rest:
            log.write(rest)
    guest_log = container / "Documents/native-guest.log"
    if guest_log.is_file():
        shutil.copy2(guest_log, run / "native-guest.log")
    print(f"\nrun ended: {run} (console.log, screen.png" + (", native-guest.log)" if guest_log.is_file() else ")"))


if __name__ == "__main__":
    main()
