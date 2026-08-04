#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AutoBuildInstall-FireStorm
==========================
Windows build helper for the Firestorm viewer.

Downloads the chosen Firestorm source, provisions an isolated Python
environment with the *correct* autobuild, detects CPU capabilities, runs
autobuild configure/build, and drops the finished viewer next to this script.

Design notes (why things are the way they are):

  * We never invoke PowerShell. Firestorm's own docs state that the build
    must not be driven from PowerShell or the VS toolchain is mis-detected.
    Python spawns processes directly with an explicit environment, which
    sidesteps the problem entirely.

  * autobuild must be >= 3.8. The `autobuild` package on PyPI is genuinely
    Linden Lab's, so plain `pip install autobuild` does work - but we install
    from the repo's requirements.txt so the versions match what Firestorm's
    official builds use, and we do it inside a venv so a stale global
    install can't shadow it.

  * AUTOBUILD_VARIABLES_FILE is mandatory. Without the fs-build-variables
    checkout, `autobuild configure` fails immediately.

  * CPU optimisation is expressed through autobuild's --avx / --avx2
    switches, not by overriding CMAKE_CXX_FLAGS. Overriding those flags
    discards the compiler settings autobuild loads from the variables file
    and reliably produces a broken viewer.

Requires: Python 3.8+, Windows 10/11 x64.
"""

from __future__ import annotations

import argparse
import collections
import ctypes
import hashlib
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import textwrap
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

APP_NAME = "AutoBuildInstall-FireStorm"
APP_VERSION = "2.0"

FS_REPO = "https://github.com/FirestormViewer/phoenix-firestorm.git"
FS_VARS_REPO = "https://github.com/FirestormViewer/fs-build-variables.git"
FS_API_TAGS = "https://api.github.com/repos/FirestormViewer/phoenix-firestorm/tags?per_page=100"
AUTOBUILD_PYPI = "autobuild>=3.8"
AUTOBUILD_GIT = "git+https://github.com/secondlife/autobuild.git#egg=autobuild"

# Visual Studio 2022 == toolset v143 == autobuild "170".
VSVER = "170"
VS_RANGE = "[17.0,18.0)"
VS_DISPLAY = "Visual Studio 2022"

# Firestorm builds generate deep paths; keep the root short or MAX_PATH bites.
DEFAULT_BUILD_ROOT = Path(r"C:\fsbuild")
MAX_SAFE_ROOT_LEN = 24

BUILD_CONFIG = "ReleaseFS_open"  # no KDU, no FMOD, no proprietary libs

# --------------------------------------------------------------------------
# Console
# --------------------------------------------------------------------------


class C:
    """ANSI colours. Disabled automatically when not a terminal."""

    enabled = True
    RESET = "\033[0m"
    BOLD = "\033[1m"
    DIM = "\033[2m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    MAGENTA = "\033[35m"
    CYAN = "\033[36m"
    GREY = "\033[90m"

    @classmethod
    def wrap(cls, text: str, colour: str) -> str:
        if not cls.enabled:
            return text
        return f"{colour}{text}{cls.RESET}"


def _init_console() -> None:
    """Turn on VT100 processing on Windows so ANSI colours actually render."""
    if not sys.stdout.isatty():
        C.enabled = False
        return
    if os.name == "nt":
        try:
            kernel32 = ctypes.windll.kernel32
            handle = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
            mode = ctypes.c_uint32()
            if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
                # ENABLE_VIRTUAL_TERMINAL_PROCESSING
                kernel32.SetConsoleMode(handle, mode.value | 0x0004)
            else:
                C.enabled = False
        except Exception:
            C.enabled = False


def say(msg: str = "", colour: str = "") -> None:
    print(C.wrap(msg, colour) if colour else msg, flush=True)


def ok(msg: str) -> None:
    say(f"  [ OK ] {msg}", C.GREEN)


def warn(msg: str) -> None:
    say(f"  [WARN] {msg}", C.YELLOW)


def fail(msg: str) -> None:
    say(f"  [FAIL] {msg}", C.RED)


def info(msg: str) -> None:
    say(f"  [ .. ] {msg}", C.GREY)


def rule(char: str = "=") -> None:
    say(char * 78, C.CYAN)


def header(title: str) -> None:
    say()
    rule()
    say(f"  {title}", C.BOLD + C.YELLOW if C.enabled else "")
    rule()


def box(title: str, lines: Sequence[str], colour: str = C.CYAN) -> None:
    width = 74
    say("+" + "-" * width + "+", colour)
    say("| " + title.ljust(width - 2) + " |", colour)
    say("+" + "-" * width + "+", colour)
    for line in lines:
        say("| " + line[: width - 2].ljust(width - 2) + " |")
    say("+" + "-" * width + "+", colour)


class Spinner:
    """Cheap progress indicator for long silent operations."""

    FRAMES = "|/-\\"

    def __init__(self, label: str):
        self.label = label
        self.i = 0
        self.last = ""
        self.start = time.time()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()

    WIDTH = 100

    def animate(self) -> None:
        """
        Repaint on a timer rather than on output.

        Some tools (git clone being the obvious one) emit nothing on stdout
        for minutes at a time, which previously left the console completely
        blank and indistinguishable from a hang.
        """
        if not sys.stdout.isatty() or self._thread:
            return

        def loop() -> None:
            while not self._stop.wait(0.15):
                with self._lock:
                    self.i += 1
                    self._render(self.last)

        self._thread = threading.Thread(target=loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=1.0)
            self._thread = None

    def _elapsed(self) -> str:
        mins, secs = divmod(int(time.time() - self.start), 60)
        hours, mins = divmod(mins, 60)
        return f"{hours:d}:{mins:02d}:{secs:02d}" if hours else f"{mins:02d}:{secs:02d}"

    def _render(self, detail: str = "") -> None:
        if not sys.stdout.isatty():
            return
        frame = self.FRAMES[self.i % len(self.FRAMES)]
        text = f"  {frame} {self.label} [{self._elapsed()}]"
        if detail:
            text += f"  {detail}"
        sys.stdout.write("\r" + text[: self.WIDTH].ljust(self.WIDTH))
        sys.stdout.flush()

    def tick(self) -> None:
        # The animation thread drives repainting; nothing to do here.
        pass

    def status(self, line: str) -> None:
        with self._lock:
            self.last = line.strip()[:70]
            self._render(self.last)

    def clear(self) -> None:
        if sys.stdout.isatty():
            sys.stdout.write("\r" + " " * self.WIDTH + "\r")
            sys.stdout.flush()

    def done(self, note: str = "done", success: bool = True) -> None:
        self.stop()
        self.clear()
        marker, colour = ("[ OK ]", C.GREEN) if success else ("[FAIL]", C.RED)
        say(f"  {marker} {self.label} - {note} ({self._elapsed()})", colour)


def confirm(prompt: str, default: bool = True) -> bool:
    """
    Strict yes/no. Anything unrecognised re-asks rather than being treated as
    consent - a typo should not silently start an hour-long build.
    """
    suffix = "[Y/n]" if default else "[y/N]"
    while True:
        answer = input(f"{prompt} {suffix} ").strip().lower()
        if not answer:
            return default
        if answer in ("y", "yes"):
            return True
        if answer in ("n", "no", "q", "quit"):
            return False
        say("  Please answer y or n.", C.YELLOW)


class BuildError(RuntimeError):
    """Fatal, user-facing build failure."""


# --------------------------------------------------------------------------
# Process execution
# --------------------------------------------------------------------------


class Logger:
    """Tees all subprocess output to a build log."""

    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fh = self.path.open("a", encoding="utf-8", errors="replace")

    def write(self, text: str) -> None:
        self.fh.write(text)
        self.fh.flush()

    def close(self) -> None:
        try:
            self.fh.close()
        except Exception:
            pass


# Lines worth surfacing during an otherwise-quiet compile.
STATUS_RE = re.compile(
    r"(?i)(building\s+|compiling\s+|creating library|installing package|"
    r"receiving objects|resolving deltas|counting objects|compressing objects|"
    r"updating files|remote:|cloning into|checking out|"
    r"downloading|fetching|-- Configuring|-- Generating|\.vcxproj\b|"
    r"^\s*\d+>-{3,})"
)
ERROR_RE = re.compile(
    r"(?i)(\berror\s+[A-Z]+\d+|fatal error|Build FAILED|^fatal:|^error:|"
    r"CMake Error|ERROR:|Traceback \(most recent)"
)


def run(
    args: Sequence[str],
    *,
    cwd: Path | None = None,
    env: dict | None = None,
    logger: Logger | None = None,
    echo: bool = True,
    check: bool = True,
    quiet_label: str | None = None,
    show_progress: bool = False,
    sink: list[str] | None = None,
) -> int:
    """
    Run a command, streaming output. Returns the exit code.

    When `quiet_label` is set the full output goes to the log only, and the
    console shows a spinner. With `show_progress` the most recent interesting
    line is also shown in place, and anything that looks like an error is
    printed permanently so failures are visible without opening the log.
    """
    pretty = " ".join(str(a) for a in args)
    if logger:
        logger.write(f"\n$ {pretty}\n  (cwd={cwd})\n")
    if echo:
        say(f"  $ {pretty}", C.GREY)

    spinner = Spinner(quiet_label) if quiet_label else None
    errors_seen: list[str] = []
    # Always retain recent output. Previously this was only kept when
    # show_progress was on, so a failure elsewhere reported nothing but an
    # exit code and the log had to be opened by hand.
    tail: collections.deque[str] = collections.deque(maxlen=40)

    proc = subprocess.Popen(
        [str(a) for a in args],
        cwd=str(cwd) if cwd else None,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )

    if spinner:
        spinner.animate()

    assert proc.stdout is not None
    try:
        for raw in proc.stdout:
            if logger:
                logger.write(raw)
            # Tools that draw progress bars (git, curl) separate updates with
            # carriage returns; keep only the newest segment of such a line.
            line = raw.replace("\r", "\n").rstrip().split("\n")[-1].strip()
            if not line:
                continue
            tail.append(line)
            if sink is not None:
                sink.append(line)

            if spinner:
                if ERROR_RE.search(line) and len(errors_seen) < 25:
                    errors_seen.append(line)
                    spinner.clear()
                    say(f"    {line[:110]}", C.RED)
                elif show_progress and STATUS_RE.search(line):
                    spinner.status(line)
                else:
                    spinner.status(line)
            elif echo:
                sys.stdout.write("    " + raw)
                sys.stdout.flush()
    finally:
        if spinner:
            spinner.stop()

    code = proc.wait()
    if spinner:
        spinner.done("ok" if code == 0 else f"exit {code}", success=(code == 0))

    if check and code != 0:
        chosen = errors_seen[:8] or list(tail)[-12:]
        detail = ""
        if chosen:
            heading = "First errors" if errors_seen else "Last output"
            detail = f"\n  {heading}:\n" + "\n".join(f"    {e[:120]}" for e in chosen)
        raise BuildError(f"Command failed (exit {code}): {pretty}{detail}")
    return code


def capture(args: Sequence[str], *, cwd: Path | None = None, env: dict | None = None) -> str:
    """Run a command and return stdout, or '' on failure."""
    try:
        res = subprocess.run(
            [str(a) for a in args],
            cwd=str(cwd) if cwd else None,
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
        return res.stdout.strip()
    except Exception:
        return ""


# --------------------------------------------------------------------------
# Hardware detection
# --------------------------------------------------------------------------

# IsProcessorFeaturePresent constants (winnt.h)
PF_XMMI64_INSTRUCTIONS_AVAILABLE = 10  # SSE2
PF_SSE3_INSTRUCTIONS_AVAILABLE = 13
PF_SSSE3_INSTRUCTIONS_AVAILABLE = 36
PF_SSE4_1_INSTRUCTIONS_AVAILABLE = 37
PF_SSE4_2_INSTRUCTIONS_AVAILABLE = 38
PF_AVX_INSTRUCTIONS_AVAILABLE = 39
PF_AVX2_INSTRUCTIONS_AVAILABLE = 40
PF_AVX512F_INSTRUCTIONS_AVAILABLE = 41

_FEATURE_MAP = [
    ("SSE2", PF_XMMI64_INSTRUCTIONS_AVAILABLE),
    ("SSE3", PF_SSE3_INSTRUCTIONS_AVAILABLE),
    ("SSSE3", PF_SSSE3_INSTRUCTIONS_AVAILABLE),
    ("SSE4.1", PF_SSE4_1_INSTRUCTIONS_AVAILABLE),
    ("SSE4.2", PF_SSE4_2_INSTRUCTIONS_AVAILABLE),
    ("AVX", PF_AVX_INSTRUCTIONS_AVAILABLE),
    ("AVX2", PF_AVX2_INSTRUCTIONS_AVAILABLE),
    ("AVX-512F", PF_AVX512F_INSTRUCTIONS_AVAILABLE),
]


@dataclass
class Hardware:
    cpu_name: str = "Unknown"
    vendor: str = "Unknown"
    cores: int = 0
    threads: int = 0
    ram_gb: float = 0.0
    os_name: str = ""
    features: list[str] = field(default_factory=list)
    gpus: list[str] = field(default_factory=list)

    @property
    def isa(self) -> str:
        for name in ("AVX-512F", "AVX2", "AVX", "SSE4.2", "SSE2"):
            if name in self.features:
                return name
        return "baseline"

    def autobuild_switch(self) -> str | None:
        """
        Return the autobuild optimisation switch this CPU supports.

        The chain, verified against Firestorm 7.2.4:
            --avx2  -> scripts/configure_firestorm.sh
                    -> -DUSE_AVX2_OPTIMIZATION:BOOL=ON
                    -> indra/cmake/00-Common.cmake adds /arch:AVX2

        AVX2 is the ceiling: Firestorm exposes no AVX-512 option, and the
        two switches are mutually exclusive, so we pick the highest one.
        """
        if "AVX2" in self.features:
            return "--avx2"
        if "AVX" in self.features:
            return "--avx"
        return None

    def build_jobs(self) -> int:
        """
        85% of logical processors, rounded up, leaving headroom so the
        machine stays usable. 24 threads -> ceil(20.4) -> 21.
        """
        t = self.threads or os.cpu_count() or 4
        return max(1, math.ceil(t * 0.85))


def detect_cpu_features() -> list[str]:
    """
    Ask Windows directly. This is the only reliable method - guessing from
    the CPU model string (as the original script did) produces wrong answers
    on rebranded, OEM, virtualised and Xeon parts.
    """
    features: list[str] = []
    if os.name != "nt":
        return features
    try:
        kernel32 = ctypes.windll.kernel32
        for name, code in _FEATURE_MAP:
            if kernel32.IsProcessorFeaturePresent(code):
                features.append(name)
    except Exception:
        pass
    return features


class MEMORYSTATUSEX(ctypes.Structure):
    _fields_ = [
        ("dwLength", ctypes.c_ulong),
        ("dwMemoryLoad", ctypes.c_ulong),
        ("ullTotalPhys", ctypes.c_ulonglong),
        ("ullAvailPhys", ctypes.c_ulonglong),
        ("ullTotalPageFile", ctypes.c_ulonglong),
        ("ullAvailPageFile", ctypes.c_ulonglong),
        ("ullTotalVirtual", ctypes.c_ulonglong),
        ("ullAvailVirtual", ctypes.c_ulonglong),
        ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
    ]


def _total_ram_gb() -> float:
    """GlobalMemoryStatusEx - accurate and always available."""
    try:
        status = MEMORYSTATUSEX()
        status.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
            return round(status.ullTotalPhys / (1024**3), 1)
    except Exception:
        pass
    return 0.0


def _physical_core_count() -> int:
    """
    Walk GetLogicalProcessorInformationEx and count RelationProcessorCore
    records. Unlike Win32_Processor this is correct on hybrid (P/E core)
    and multi-socket systems.
    """
    RELATION_PROCESSOR_CORE = 0
    try:
        k32 = ctypes.windll.kernel32
        length = ctypes.c_ulong(0)
        k32.GetLogicalProcessorInformationEx(RELATION_PROCESSOR_CORE, None, ctypes.byref(length))
        if length.value == 0:
            return 0
        buf = (ctypes.c_byte * length.value)()
        if not k32.GetLogicalProcessorInformationEx(RELATION_PROCESSOR_CORE, buf, ctypes.byref(length)):
            return 0
        count = 0
        offset = 0
        while offset + 8 <= length.value:
            relationship = ctypes.c_ulong.from_buffer(buf, offset).value
            size = ctypes.c_ulong.from_buffer(buf, offset + 4).value
            if size == 0:
                break
            if relationship == RELATION_PROCESSOR_CORE:
                count += 1
            offset += size
        return count
    except Exception:
        return 0


def _cpu_name_from_registry() -> str:
    try:
        import winreg

        key = winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE,
            r"HARDWARE\DESCRIPTION\System\CentralProcessor\0",
        )
        with key:
            value, _ = winreg.QueryValueEx(key, "ProcessorNameString")
            return str(value).strip()
    except Exception:
        return ""


def _gpu_names_from_registry() -> list[str]:
    """
    Read display adapter names from the Display class key. Informational only:
    the GPU has no bearing on how the viewer is compiled.
    """
    names: list[str] = []
    try:
        import winreg

        class_key = r"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
        root = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, class_key)
        with root:
            index = 0
            while True:
                try:
                    sub = winreg.EnumKey(root, index)
                except OSError:
                    break
                index += 1
                if not sub.isdigit():
                    continue
                try:
                    with winreg.OpenKey(root, sub) as adapter:
                        desc, _ = winreg.QueryValueEx(adapter, "DriverDesc")
                        desc = str(desc).strip()
                        if desc and desc not in names and "Basic Display" not in desc:
                            names.append(desc)
                except OSError:
                    continue
    except Exception:
        pass
    return names


def detect_hardware() -> Hardware:
    """
    All detection uses native Win32 APIs and the registry. We deliberately
    avoid `wmic` (removed in current Windows 11) and PowerShell, and we never
    infer instruction-set support from the CPU model string.
    """
    hw = Hardware()
    hw.os_name = f"{platform.system()} {platform.release()} (build {platform.version()})"

    if os.name != "nt":
        hw.threads = os.cpu_count() or 0
        return hw

    hw.features = detect_cpu_features()
    hw.threads = os.cpu_count() or 0
    hw.cores = _physical_core_count()
    hw.ram_gb = _total_ram_gb()
    hw.cpu_name = _cpu_name_from_registry() or platform.processor() or "Unknown"
    hw.gpus = _gpu_names_from_registry()

    upper = hw.cpu_name.upper()
    if "INTEL" in upper:
        hw.vendor = "Intel"
    elif "AMD" in upper:
        hw.vendor = "AMD"

    return hw


# --------------------------------------------------------------------------
# Toolchain discovery
# --------------------------------------------------------------------------


@dataclass
class Toolchain:
    git: Path | None = None
    cmake: Path | None = None
    cmake_version: str = ""
    vs_path: Path | None = None
    msbuild: Path | None = None
    cygwin_bin: Path | None = None
    nsis: Path | None = None
    python: Path = field(default_factory=lambda: Path(sys.executable))


def _which(name: str) -> Path | None:
    found = shutil.which(name)
    return Path(found) if found else None


def find_visual_studio() -> tuple[Path | None, Path | None]:
    """Locate VS2022 + MSBuild using vswhere."""
    pf86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
    vswhere = Path(pf86) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
    if not vswhere.exists():
        return None, None

    out = capture(
        [
            vswhere,
            "-latest",
            "-products", "*",
            "-version", VS_RANGE,
            "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
            "-property", "installationPath",
            "-format", "value",
        ]
    )
    line = next((ln.strip() for ln in out.splitlines() if ln.strip()), "")
    if not line:
        return None, None
    vs_path = Path(line)
    if not vs_path.exists():
        return None, None

    msbuild = vs_path / "MSBuild" / "Current" / "Bin" / "MSBuild.exe"
    return vs_path, (msbuild if msbuild.exists() else None)


def _read_registry_value(hive_name: str, subkey: str, value: str) -> str | None:
    try:
        import winreg
    except ImportError:
        return None
    hive = {"HKLM": winreg.HKEY_LOCAL_MACHINE, "HKCU": winreg.HKEY_CURRENT_USER}[hive_name]
    for access in (winreg.KEY_READ, winreg.KEY_READ | winreg.KEY_WOW64_64KEY,
                   winreg.KEY_READ | winreg.KEY_WOW64_32KEY):
        try:
            with winreg.OpenKey(hive, subkey, 0, access) as key:
                data, _ = winreg.QueryValueEx(key, value)
                if data:
                    return str(data)
        except OSError:
            continue
    return None


def _bash_flavour(bash: Path) -> str:
    """
    Ask a bash binary what it actually is.

    configure_firestorm.sh branches on `[ "$OSTYPE" = "cygwin" ]` to call
    cygpath, so the only test that matters is what OSTYPE that specific bash
    reports. Judging by install path is unreliable: people install Cygwin
    anywhere, and Git for Windows ships an MSYS bash that looks similar.
    """
    out = capture([bash, "-c", "echo $OSTYPE"]).strip().lower()
    if not out:
        return "unknown"
    if "cygwin" in out:
        return "cygwin"
    if "msys" in out or "mingw" in out:
        return "msys"
    return out


def _cygwin_candidates() -> list[Path]:
    """Every plausible Cygwin bin directory, best guesses first."""
    seen: set[str] = set()
    out: list[Path] = []

    def add(p: Path | None) -> None:
        if p is None:
            return
        key = str(p).lower().rstrip("\\/")
        if key not in seen:
            seen.add(key)
            out.append(p)

    # 1. Authoritative: Cygwin's setup.exe records where it installed.
    for hive in ("HKLM", "HKCU"):
        for subkey in (r"SOFTWARE\Cygwin\setup", r"SOFTWARE\WOW6432Node\Cygwin\setup"):
            root = _read_registry_value(hive, subkey, "rootdir")
            if root:
                add(Path(root) / "bin")

    # 2. Anything already on PATH that looks like a Cygwin bin directory.
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        entry = entry.strip().strip('"')
        if not entry:
            continue
        try:
            p = Path(entry)
        except (ValueError, OSError):
            continue
        add(p)
        add(p / "bin")  # in case someone added the root instead of bin

    # 3. Common install roots on every fixed drive, plus Program Files variants.
    roots: list[Path] = []
    for drive, _free in _drive_report() or [("C:\\", 0.0)]:
        roots.append(Path(drive))
    for var in ("ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "LOCALAPPDATA"):
        base = os.environ.get(var)
        if base:
            roots.append(Path(base))
    # Non-standard but common hand-made folders.
    for drive, _free in _drive_report() or [("C:\\", 0.0)]:
        roots.append(Path(drive) / "Program_Files")
        roots.append(Path(drive) / "Programs")
        roots.append(Path(drive) / "tools")

    for root in roots:
        for name in ("cygwin64", "cygwin", "Cygwin64", "Cygwin"):
            add(root / name / "bin")

    # 4. Whatever bash resolves to right now.
    bash = _which("bash")
    if bash:
        add(bash.parent)

    return out


def find_cygwin() -> tuple[Path | None, list[str]]:
    """
    Locate a genuine Cygwin bin directory.

    Returns (path, notes). `notes` explains near-misses so a failure can be
    acted on instead of guessed at.
    """
    notes: list[str] = []
    rejected: list[tuple[Path, str]] = []

    for candidate in _cygwin_candidates():
        try:
            bash = candidate / "bash.exe"
            if not bash.exists():
                continue
        except OSError:
            continue

        has_cygpath = (candidate / "cygpath.exe").exists()
        flavour = _bash_flavour(bash)

        if flavour == "cygwin" and has_cygpath:
            return candidate, notes
        if flavour == "cygwin" and not has_cygpath:
            rejected.append((candidate, "Cygwin bash but cygpath.exe is missing"))
        elif flavour == "msys":
            rejected.append((candidate, "MSYS/Git bash, not Cygwin"))
        elif flavour == "unknown":
            rejected.append((candidate, "bash.exe did not run or reported nothing"))
        else:
            rejected.append((candidate, f"bash reports OSTYPE={flavour}"))

    for path, why in rejected[:4]:
        notes.append(f"{path} - {why}")
    return None, notes


def find_nsis() -> Path | None:
    for base in (os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles")):
        if not base:
            continue
        exe = Path(base) / "NSIS" / "makensis.exe"
        if exe.exists():
            return exe
    return _which("makensis")


def discover_toolchain() -> tuple[Toolchain, list[str]]:
    """Find every external tool. Returns (toolchain, list of blocking issues)."""
    tc = Toolchain()
    issues: list[str] = []

    tc.git = _which("git")
    if tc.git:
        ok(f"git          {capture([tc.git, '--version']) or tc.git}")
    else:
        fail("git not found")
        issues.append("Install Git for Windows: https://git-scm.com/downloads/win")

    tc.cmake = _which("cmake")
    if tc.cmake:
        ver = capture([tc.cmake, "--version"]).splitlines()
        tc.cmake_version = ver[0] if ver else ""
        ok(f"cmake        {tc.cmake_version}")
        m = re.search(r"(\d+)\.(\d+)", tc.cmake_version)
        if m:
            version = (int(m.group(1)), int(m.group(2)))
            # indra/CMakeLists.txt declares cmake_minimum_required(3.16.0) and
            # has explicit policy handling for 3.29 and 3.31, so anything from
            # 3.16 up is genuinely supported.
            if version < (3, 16):
                fail(f"CMake {m.group(1)}.{m.group(2)} is too old (3.16 minimum)")
                issues.append("Install CMake 3.16 or newer: https://cmake.org/download")
    else:
        fail("cmake not found")
        issues.append("Install CMake and tick 'Add to system PATH': https://cmake.org/download")

    tc.vs_path, tc.msbuild = find_visual_studio()
    if tc.vs_path and tc.msbuild:
        ok(f"{VS_DISPLAY}  {tc.vs_path}")
    elif tc.vs_path:
        fail(f"{VS_DISPLAY} found but MSBuild is missing")
        issues.append(f"Repair {VS_DISPLAY} and ensure 'Desktop development with C++' is installed")
    else:
        fail(f"{VS_DISPLAY} not found")
        issues.append(
            f"Install {VS_DISPLAY} with the 'Desktop development with C++' workload: "
            "https://visualstudio.microsoft.com/free-developer-offers"
        )

    tc.cygwin_bin, cyg_notes = find_cygwin()
    if tc.cygwin_bin:
        ok(f"cygwin       {tc.cygwin_bin}")
        if not (tc.cygwin_bin / "patch.exe").exists():
            warn("Cygwin is missing the 'patch' package (Devel/patch).")
            warn("Re-run Cygwin's setup and add it, or some 3p packages will fail.")
    else:
        fail("Cygwin not found")
        for note in cyg_notes:
            say(f"         checked: {note}", C.GREY)
        issues.append(
            "Install Cygwin 64-bit from https://cygwin.com/install.html, including the\n"
            "       'Devel/patch' package. Any install location is fine - detection reads\n"
            "       Cygwin's own registry entry, so it does not need to be on PATH.\n"
            "       This is NOT optional: Firestorm's autobuild.xml runs configure and build\n"
            "       via 'bash ../scripts/configure_firestorm.sh', which calls cygpath, so\n"
            "       Cygwin's bash specifically is required (Git-bash will not work)."
        )

    tc.nsis = find_nsis()
    if tc.nsis:
        ok(f"NSIS         {tc.nsis}")
    else:
        warn("NSIS not found - the viewer will still be assembled, but no installer is produced")

    py = sys.version_info
    if py < (3, 8):
        fail(f"Python {py.major}.{py.minor} is too old")
        issues.append("Install Python 3.8 or newer: https://www.python.org/downloads/windows")
    else:
        ok(f"python       {py.major}.{py.minor}.{py.micro} ({sys.executable})")

    return tc, issues


# --------------------------------------------------------------------------
# Environment construction
# --------------------------------------------------------------------------


def build_environment(tc: Toolchain, venv_dir: Path, vars_file: Path, build_root: Path) -> dict:
    """
    Construct the exact environment autobuild will run under.

    PATH order matters. Firestorm's build.cmd.sh translates every PATH entry
    into a Cygwin path; a bad order produces the classic
    'SystemRootsystem32: unbound variable' failure. We build PATH from
    scratch with fully expanded, ordered entries.
    """
    env = dict(os.environ)

    system_root = os.environ.get("SystemRoot", r"C:\Windows")
    parts: list[str] = [
        str(venv_dir / "Scripts"),
    ]
    if tc.cmake:
        parts.append(str(tc.cmake.parent))
    if tc.cygwin_bin:
        parts.append(str(tc.cygwin_bin))
    if tc.git:
        parts.append(str(tc.git.parent))
    parts.append(str(Path(sys.executable).parent))
    if tc.nsis:
        parts.append(str(tc.nsis.parent))
    parts += [
        system_root,
        str(Path(system_root) / "system32"),
        str(Path(system_root) / "System32" / "Wbem"),
        str(Path(system_root) / "System32" / "WindowsPowerShell" / "v1.0"),
    ]

    # Preserve anything else the user had, minus duplicates.
    seen = {p.lower().rstrip("\\") for p in parts}
    for p in os.environ.get("PATH", "").split(os.pathsep):
        key = p.lower().rstrip("\\")
        if p and key not in seen:
            parts.append(p)
            seen.add(key)

    env["PATH"] = os.pathsep.join(parts)

    # Autobuild configuration.
    env["AUTOBUILD_VSVER"] = VSVER
    env["AUTOBUILD_ADDRSIZE"] = "64"
    env["AUTOBUILD_PLATFORM"] = "windows64"
    env["AUTOBUILD_CONFIGURATION"] = BUILD_CONFIG
    env["AUTOBUILD_VARIABLES_FILE"] = str(vars_file)
    env["AUTOBUILD_INSTALLABLE_CACHE"] = str(build_root / "cache")
    env["VIRTUAL_ENV"] = str(venv_dir)

    # Don't let an inherited value from a previous manual attempt confuse us.
    env.pop("AUTOBUILD_CONFIG_FILE", None)
    env.pop("PYTHONHOME", None)

    (build_root / "cache").mkdir(parents=True, exist_ok=True)
    return env


# --------------------------------------------------------------------------
# Source acquisition
# --------------------------------------------------------------------------


# Firestorm's own release tags. Everything else in the tag namespace is
# inherited from the upstream Linden Lab repo and is not buildable here.
TAG_MODERN = re.compile(r"^Firestorm_(Release|Beta)_(\d+)\.(\d+)\.(\d+)\.(\d+)$")
TAG_LEGACY = re.compile(r"^Firestorm_(\d+)\.(\d+)\.(\d+)_(Release|Beta)$")

BRANCHES = [
    ("master", "master", "bleeding edge, may not compile"),
]


@dataclass(frozen=True)
class FSTag:
    name: str          # full git tag, e.g. Firestorm_Release_7.2.4.80712
    kind: str          # "Release" or "Beta"
    version: tuple     # (7, 2, 4, 80712) for sorting
    legacy: bool = False

    @property
    def pretty(self) -> str:
        return ".".join(str(p) for p in self.version if not (self.legacy and p == 0))


def parse_tag(name: str) -> FSTag | None:
    m = TAG_MODERN.match(name)
    if m:
        return FSTag(name, m.group(1), tuple(int(x) for x in m.groups()[1:]))
    m = TAG_LEGACY.match(name)
    if m:
        return FSTag(name, m.group(4), tuple(int(x) for x in m.groups()[:3]) + (0,), legacy=True)
    return None


def _tags_via_git(git: Path | None) -> list[str]:
    """
    Preferred source: one call, no API rate limit, no auth.
    Output lines look like '<sha>\\trefs/tags/<name>'.
    """
    if not git:
        return []
    out = capture([git, "ls-remote", "--tags", "--refs", FS_REPO])
    names = []
    for line in out.splitlines():
        _, _, ref = line.partition("refs/tags/")
        if ref:
            names.append(ref.strip())
    return names


def _tags_via_api() -> list[str]:
    """
    Fallback when git isn't usable. Must page: the API returns tags in an
    arbitrary order, so the first page is mostly inherited upstream tags and
    contains no Firestorm releases at all.
    """
    names: list[str] = []
    for page in range(1, 9):
        url = f"{FS_API_TAGS}&page={page}"
        req = urllib.request.Request(
            url, headers={"Accept": "application/vnd.github+json", "User-Agent": APP_NAME}
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                batch = json.load(resp)
        except (urllib.error.URLError, ValueError, TimeoutError):
            break
        if not batch:
            break
        names += [t["name"] for t in batch if isinstance(t, dict) and "name" in t]
        if len(batch) < 100:
            break
    return names


def fetch_firestorm_tags(git: Path | None) -> list[FSTag]:
    """Return every Firestorm release/beta tag, newest first."""
    names = _tags_via_git(git)
    if not names:
        info("git ls-remote unavailable, falling back to the GitHub API")
        names = _tags_via_api()

    tags = [t for t in (parse_tag(n) for n in set(names)) if t]
    tags.sort(key=lambda t: (t.version, t.kind == "Release"), reverse=True)
    return tags


def resolve_ref(user_input: str, tags: list[FSTag]) -> str:
    """
    Turn whatever the user typed into a real git ref.

    Accepts: 'latest', a branch name, a full tag, or a partial version like
    '7.2.4' or '7.2.4.80712'.
    """
    text = user_input.strip()
    releases = [t for t in tags if t.kind == "Release"]

    if text.lower() in ("latest", "release", "stable"):
        if not releases:
            raise BuildError("Could not determine the latest release tag.")
        return releases[0].name

    known_branches = {b[0] for b in BRANCHES}
    if text in known_branches:
        return text

    by_name = {t.name: t for t in tags}
    if text in by_name:
        return text

    # Partial version match: prefer a Release over a Beta.
    digits = text.lstrip("vV")
    if re.fullmatch(r"\d+(\.\d+)*", digits):
        prefix = tuple(int(p) for p in digits.split("."))
        matches = [t for t in tags if t.version[: len(prefix)] == prefix]
        rel = [t for t in matches if t.kind == "Release"]
        chosen = (rel or matches)
        if chosen:
            pick = chosen[0]
            say(f"  '{text}' resolved to {pick.name}", C.CYAN)
            return pick.name
        raise BuildError(
            f"No Firestorm tag matches '{text}'.\n"
            f"  Latest release is {releases[0].pretty} ({releases[0].name})"
            if releases else f"No Firestorm tag matches '{text}'."
        )

    # Anything else: assume the user knows what branch they want.
    return text


def choose_version(preselected: str | None, git: Path | None) -> str:
    header("CHOOSE FIRESTORM VERSION")
    info("Fetching available versions...")
    tags = fetch_firestorm_tags(git)

    if not tags:
        warn("Could not retrieve the tag list.")
        if preselected:
            return preselected
        manual = input("  Enter a tag or branch name: ").strip()
        if not manual:
            raise SystemExit("Abandoned by user.")
        return manual

    releases = [t for t in tags if t.kind == "Release"]
    betas = [t for t in tags if t.kind == "Beta"]

    if preselected:
        return resolve_ref(preselected, tags)

    shown: list[tuple[str, str]] = []  # (ref, label)

    say()
    say("  RELEASES  (recommended - what most people want)", C.GREEN)
    for i, t in enumerate(releases[:6]):
        shown.append((t.name, t.pretty))
        line = f"   {len(shown):>2}. {t.pretty}"
        if i == 0:
            line = f"   {len(shown):>2}. {t.pretty:<16}" + C.wrap("<-- current release", C.GREEN)
        say(line)

    say()
    say("  BETAS  (newer, less tested)", C.YELLOW)
    for t in betas[:4]:
        shown.append((t.name, t.pretty))
        say(f"   {len(shown):>2}. {t.pretty}")

    say()
    say("  OTHER", C.CYAN)
    for ref, label, note in BRANCHES:
        shown.append((ref, label))
        say(f"   {len(shown):>2}. {label:<16}({note})")

    manual_opt = len(shown) + 1
    all_opt = len(shown) + 2
    say(f"   {manual_opt:>2}. Enter a tag, branch or version manually")
    say(f"   {all_opt:>2}. Show all {len(tags)} Firestorm tags")

    default_ref = releases[0].name if releases else shown[0][0]
    default_label = releases[0].pretty if releases else shown[0][1]

    say()
    while True:
        choice = input(
            f"  Selection [Enter = {default_label}, q = quit]: "
        ).strip()

        if choice == "":
            say(f"  Using {default_ref}", C.GREEN)
            return default_ref
        if choice.lower() in ("q", "quit", "a", "abandon"):
            raise SystemExit("Abandoned by user.")

        if choice.isdigit():
            n = int(choice)
            if 1 <= n <= len(shown):
                ref = shown[n - 1][0]
                say(f"  Using {ref}", C.GREEN)
                return ref
            if n == manual_opt:
                manual = input("  Tag, branch or version (e.g. 7.2.4): ").strip()
                if manual:
                    try:
                        return resolve_ref(manual, tags)
                    except BuildError as exc:
                        fail(str(exc))
                continue
            if n == all_opt:
                say()
                for t in tags:
                    say(f"    {t.kind:<8} {t.pretty:<18} {t.name}", C.GREY)
                say()
                continue
            continue

        # Treat free text as a version or ref directly.
        try:
            ref = resolve_ref(choice, tags)
        except BuildError as exc:
            fail(str(exc))
            continue

        known = {t.name for t in tags} | {b[0] for b in BRANCHES}
        if ref not in known:
            warn(f"'{ref}' is not a known Firestorm tag.")
            if not confirm("  Try it as a branch name anyway?", default=False):
                continue
        return ref


def git_clone(git: Path, url: str, dest: Path, ref: str, logger: Logger, label: str) -> None:
    """
    Shallow-clone a ref, with retries.

    phoenix-firestorm is a large repository and GitHub's HTTP/2 transport
    drops big clones fairly often, surfacing as 'RPC failed' / 'early EOF' and
    a bare exit 128. Retrying over HTTP/1.1 with a larger post buffer clears
    most of these. Each attempt starts from a clean directory, because a
    half-written clone will fail differently and more confusingly next time.
    """
    # Persisted into the new repo's config:
    #  * autocrlf=false matches Firestorm's documented "checkout as-is,
    #    commit as-is" requirement. A global autocrlf=true rewrites line
    #    endings in shell scripts and breaks the build in obscure ways.
    #  * longpaths=true keeps git working once the build tree pushes paths
    #    past the 260-character MAX_PATH limit.
    repo_config = [
        "--config", "core.autocrlf=false",
        "--config", "core.longpaths=true",
    ]

    attempts = [
        ["-c", "core.longpaths=true"],
        ["-c", "core.longpaths=true", "-c", "http.version=HTTP/1.1",
         "-c", "http.postBuffer=524288000"],
        ["-c", "core.longpaths=true", "-c", "http.version=HTTP/1.1",
         "-c", "http.postBuffer=524288000", "-c", "core.compression=0"],
    ]

    last_error: BuildError | None = None
    for index, extra in enumerate(attempts, start=1):
        if dest.exists():
            shutil.rmtree(dest, ignore_errors=True)
        dest.parent.mkdir(parents=True, exist_ok=True)

        suffix = "" if index == 1 else f" (attempt {index}/{len(attempts)}, HTTP/1.1)"
        try:
            run(
                [git, *extra, "clone", "--depth", "1", "--branch", ref,
                 "--progress", *repo_config, url, str(dest)],
                logger=logger,
                echo=False,
                quiet_label=f"Cloning {label} ({ref}){suffix}",
                show_progress=True,
            )
            return
        except BuildError as exc:
            last_error = exc
            if index < len(attempts):
                warn(f"Clone attempt {index} failed; retrying with a more conservative transport")
                time.sleep(3)

    shutil.rmtree(dest, ignore_errors=True)
    raise BuildError(
        f"Could not clone {label} after {len(attempts)} attempts.\n"
        f"  {last_error}\n"
        "  This is usually a network or proxy problem rather than a bug.\n"
        "  If it persists, try: git clone --depth 1 --branch "
        f"{ref} {url}\n"
        "  manually to see the raw error."
    )


def sync_repo(git: Path, url: str, dest: Path, ref: str, logger: Logger, label: str,
              force_fresh: bool = False) -> None:
    """
    Clone or update a repo to a specific ref. Idempotent and resumable.

    If the checkout was last built at a different ref we re-clone rather than
    switching in place. A shallow tree that has been dragged between wildly
    different revisions accumulates stale generated files, and a stale build
    tree is far more confusing to debug than a two-minute re-clone.
    """
    marker = dest / ".autobuild-fs-ref"

    if force_fresh and dest.exists():
        info(f"{label}: --fresh requested, removing {dest}")
        shutil.rmtree(dest, ignore_errors=True)

    if (dest / ".git").is_dir():
        previous = marker.read_text(encoding="utf-8").strip() if marker.exists() else None

        if previous is not None and previous != ref:
            warn(f"{label}: checkout is at '{previous}' but you asked for '{ref}'")
            info("Removing it and cloning fresh to avoid a stale build tree")
            shutil.rmtree(dest, ignore_errors=True)
        elif previous is None:
            warn(f"{label}: existing checkout of unknown revision found")
            info("Removing it and cloning fresh")
            shutil.rmtree(dest, ignore_errors=True)
        else:
            info(f"{label}: existing checkout at {ref}, updating")
            run([git, "fetch", "--depth", "1", "--progress", "origin", ref], cwd=dest,
                logger=logger, echo=False, check=False,
                quiet_label=f"Fetching {label}", show_progress=True)
            code = run([git, "checkout", "--force", "FETCH_HEAD"], cwd=dest, logger=logger,
                       echo=False, check=False)
            if code == 0:
                run([git, "clean", "-fdx", "-e", "build-vc*", "-e", ".autobuild-fs-ref"],
                    cwd=dest, logger=logger, echo=False, check=False)
                ok(f"{label} up to date at {ref}")
                return
            warn(f"{label}: could not fast-update; re-cloning")
            shutil.rmtree(dest, ignore_errors=True)

    git_clone(git, url, dest, ref, logger, label)
    if not (dest / ".git").is_dir():
        raise BuildError(f"{label}: clone did not produce a repository at {dest}")
    marker.write_text(ref, encoding="utf-8")
    ok(f"{label} cloned at {ref}")


# --------------------------------------------------------------------------
# Python environment / autobuild
# --------------------------------------------------------------------------


def provision_venv(venv_dir: Path, src_dir: Path, logger: Logger) -> Path:
    """
    Create an isolated venv and install autobuild into it.

    The venv matters less for correctness than for repeatability: it pins the
    build to the versions in the repo's requirements.txt and stops an old
    global autobuild (or a half-broken --user install) from shadowing it.
    """
    py_exe = venv_dir / "Scripts" / "python.exe"

    if not py_exe.exists():
        info(f"Creating virtual environment at {venv_dir}")
        run([sys.executable, "-m", "venv", str(venv_dir)], logger=logger, echo=False,
            quiet_label="Creating virtual environment")
    else:
        ok(f"Reusing virtual environment at {venv_dir}")

    if not py_exe.exists():
        raise BuildError(f"venv creation failed - {py_exe} does not exist")

    run([py_exe, "-m", "pip", "install", "--upgrade", "pip", "wheel"], logger=logger,
        echo=False, check=False, quiet_label="Upgrading pip")

    requirements = src_dir / "requirements.txt"
    installed = False
    if requirements.exists():
        info("Installing autobuild from the repo's requirements.txt")
        code = run([py_exe, "-m", "pip", "install", "-r", str(requirements)], logger=logger,
                   echo=False, check=False, quiet_label="Installing build requirements")
        installed = code == 0
        if not installed:
            warn("requirements.txt install failed; falling back to installing autobuild from git")
    else:
        warn("requirements.txt not present in this revision; installing autobuild from git")

    if not installed:
        # PyPI 'autobuild' is Linden Lab's official package - prefer the
        # stable release over the git tip, which is a dev build.
        code = run([py_exe, "-m", "pip", "install", AUTOBUILD_PYPI, "llbase", "llsd"],
                   logger=logger, echo=False, check=False,
                   quiet_label="Installing autobuild from PyPI")
        if code != 0:
            warn("PyPI install failed; trying the git tip as a last resort")
            run([py_exe, "-m", "pip", "install", AUTOBUILD_GIT], logger=logger, echo=False,
                quiet_label="Installing autobuild from git")

    autobuild = venv_dir / "Scripts" / "autobuild.exe"
    if not autobuild.exists():
        raise BuildError(
            "autobuild.exe was not installed into the virtual environment.\n"
            f"  Check the log at {logger.path} for pip errors."
        )

    version = capture([autobuild, "--version"])
    m = re.search(r"(\d+)\.(\d+)", version)
    if m:
        major, minor = int(m.group(1)), int(m.group(2))
        if (major, minor) < (3, 8):
            raise BuildError(
                f"autobuild {major}.{minor} is too old - Firestorm needs 3.8 or newer.\n"
                "  Try: pip install --upgrade autobuild"
            )
        ok(f"autobuild    {version}")
    else:
        warn(f"Could not parse autobuild version from: {version!r}")

    return autobuild


# --------------------------------------------------------------------------
# Configure / build / deploy
# --------------------------------------------------------------------------


# A corrupt entry in the dependency cache surfaces like this. The path is
# what we need, so we can delete exactly the bad file and try again.
SHA_MISMATCH_RE = re.compile(
    r"(?:sha1|sha256|md5)\s+mismatch\s+for\s+(.+?\.(?:tar\.zst|tar\.bz2|tar\.gz|tgz|zip))",
    re.IGNORECASE,
)
CMAKE_FATAL_RE = re.compile(r"(?i)(CMake Error|Failed to download package|Configure failed)")


def find_solution(build_dir: Path) -> Path | None:
    """VS2022 emits Firestorm.sln; newer toolchains emit Firestorm.slnx."""
    for name in ("Firestorm.sln", "Firestorm.slnx"):
        candidate = build_dir / name
        if candidate.exists():
            return candidate
    return None


def purge_bad_cache(lines: list[str], cache_dir: Path) -> list[Path]:
    """
    Delete dependency archives that failed their checksum.

    autobuild will happily keep re-reading a truncated archive from the cache,
    so the same mismatch repeats forever until the file is removed.
    """
    removed: list[Path] = []
    seen: set[str] = set()

    for line in lines:
        m = SHA_MISMATCH_RE.search(line)
        if not m:
            continue
        raw = m.group(1).strip().strip('"\'')
        if raw in seen:
            continue
        seen.add(raw)

        # Split on both separators: the log may contain Windows paths even
        # when this parses them somewhere else.
        basename = re.split(r"[\\/]", raw)[-1]

        candidates = [Path(raw), cache_dir / basename]
        for candidate in candidates:
            try:
                if candidate.is_file():
                    size = candidate.stat().st_size
                    candidate.unlink()
                    removed.append(candidate)
                    info(f"Removed corrupt cache file: {candidate.name} ({size / 1024 / 1024:.1f} MB)")
                    break
            except OSError as exc:
                warn(f"Could not delete {candidate}: {exc}")
    return removed


# --------------------------------------------------------------------------
# Dependency pre-seeding
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Archive:
    name: str
    url: str
    digest: str
    algorithm: str

    @property
    def filename(self) -> str:
        return self.url.rsplit("/", 1)[-1]


def parse_llsd(path: Path):
    """
    Minimal LLSD-XML reader, enough for autobuild.xml.

    autobuild.xml is plist-shaped but wrapped in <llsd>, so plistlib cannot
    read it directly and pulling in the llsd package just to read one file
    would be overkill.
    """
    import xml.etree.ElementTree as ET

    def convert(el):
        tag = el.tag
        if tag == "llsd":
            children = list(el)
            return convert(children[0]) if children else None
        if tag == "map":
            out = {}
            kids = list(el)
            i = 0
            while i < len(kids) - 1:
                if kids[i].tag == "key":
                    out[kids[i].text] = convert(kids[i + 1])
                    i += 2
                else:
                    i += 1
            return out
        if tag == "array":
            return [convert(c) for c in el]
        if tag in ("string", "uri"):
            return el.text or ""
        if tag == "integer":
            return int(el.text or 0)
        if tag == "real":
            return float(el.text or 0)
        if tag == "boolean":
            return (el.text or "").strip().lower() in ("1", "true")
        return el.text

    return convert(ET.parse(path).getroot())


def windows_archives(src_dir: Path) -> list[Archive]:
    """Every prebuilt archive this platform needs, from autobuild.xml."""
    manifest = src_dir / "autobuild.xml"
    if not manifest.exists():
        return []
    try:
        data = parse_llsd(manifest)
    except Exception as exc:
        warn(f"Could not parse autobuild.xml ({exc}); leaving downloads to autobuild")
        return []

    out: list[Archive] = []
    for name, package in sorted((data or {}).get("installables", {}).items()):
        if not isinstance(package, dict):
            continue
        platforms = package.get("platforms") or {}
        entry = platforms.get("windows64") or platforms.get("common")
        if not isinstance(entry, dict):
            continue
        archive = entry.get("archive") or {}
        url = archive.get("url")
        digest = archive.get("hash")
        if url and digest:
            out.append(Archive(name, url, digest.strip().lower(),
                               (archive.get("hash_algorithm") or "sha1").lower()))
    return out


def file_digest(path: Path, algorithm: str) -> str | None:
    try:
        h = hashlib.new(algorithm)
    except ValueError:
        return None
    try:
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest().lower()


# 4xx codes where retrying cannot possibly help.
PERMANENT_HTTP = {400, 401, 403, 404, 410, 451}


def _human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}GB"


def _fetch_range(url: str, part: Path, offset: int, spinner: Spinner | None,
                 label: str, read_timeout: int = 45) -> tuple[int, int]:
    """
    Fetch from `offset` onwards, appending to `part`.

    Returns (total_size, bytes_on_disk). A server that ignores the Range
    request answers 200 instead of 206, in which case we start over rather
    than silently appending a second copy of the file to the first.
    """
    headers = {
        "User-Agent": f"{APP_NAME}/{APP_VERSION}",
        # GitHub's API asset endpoint returns JSON metadata unless the client
        # explicitly asks for the binary.
        "Accept": "application/octet-stream" if "api.github.com" in url else "*/*",
        "Accept-Encoding": "identity",
    }
    if offset > 0:
        headers["Range"] = f"bytes={offset}-"

    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=read_timeout) as response:
        status = getattr(response, "status", response.getcode())

        if offset > 0 and status == 200:
            offset = 0  # Range ignored; truncate and restart the transfer.

        mode = "ab" if offset > 0 else "wb"

        content_range = response.headers.get("Content-Range")
        if content_range and "/" in content_range:
            tail = content_range.rsplit("/", 1)[-1].strip()
            total = int(tail) if tail.isdigit() else 0
        else:
            length = response.headers.get("Content-Length")
            total = (int(length) + offset) if (length and length.isdigit()) else 0

        got = offset
        started = time.time()
        with part.open(mode) as fh:
            while True:
                chunk = response.read(512 * 1024)
                if not chunk:
                    break
                fh.write(chunk)
                got += len(chunk)
                if spinner:
                    elapsed = max(time.time() - started, 0.001)
                    rate = (got - offset) / elapsed
                    resumed = " resumed" if offset else ""
                    if total:
                        spinner.status(
                            f"{label}{resumed} {got * 100 // total}% "
                            f"({_human(got)}/{_human(total)}) {_human(rate)}/s")
                    else:
                        spinner.status(f"{label}{resumed} {_human(got)} {_human(rate)}/s")

    return total, got


def download_verified(archive: Archive, dest: Path, spinner: Spinner | None,
                      logger: Logger, max_attempts: int = 20,
                      max_restarts: int = 3) -> bool:
    """
    Download one archive, resuming after every interruption.

    Large transfers from these hosts drop regularly on some connections. The
    important property is that a dropped connection costs only the remaining
    bytes, never the ones already on disk: progress is kept in a .part file
    and continued with a Range request. An attempt that moved any data at all
    does not count against the retry budget, so a slow or flaky link makes
    steady forward progress instead of restarting forever.

    The file is only renamed into the cache once its checksum matches, so a
    corrupt transfer can never be mistaken for a valid dependency.
    """
    part = dest.with_suffix(dest.suffix + ".part")
    restarts = 0
    attempt = 0
    stalled = 0

    while attempt < max_attempts:
        attempt += 1
        before = part.stat().st_size if part.exists() else 0

        try:
            total, got = _fetch_range(archive.url, part, before, spinner, archive.name)

        except urllib.error.HTTPError as exc:
            if exc.code == 416:
                # Already have at least the whole file; fall through to verify.
                total, got = before, before
            elif exc.code in PERMANENT_HTTP:
                logger.write(f"\n[preseed] {archive.name}: HTTP {exc.code} {exc.reason} "
                             f"for {archive.url} - not retryable\n")
                return False
            else:
                logger.write(f"\n[preseed] {archive.name}: HTTP {exc.code} on attempt {attempt}\n")
                stalled += 1
                time.sleep(min(2 * stalled, 20))
                continue

        except (urllib.error.URLError, OSError, ValueError, TimeoutError) as exc:
            after = part.stat().st_size if part.exists() else 0
            progressed = after > before
            logger.write(
                f"\n[preseed] {archive.name}: attempt {attempt} interrupted after "
                f"{after - before} new bytes ({after} total): {exc}\n")
            if progressed:
                # Forward progress was made - don't spend the retry budget.
                attempt -= 1
                stalled = 0
            else:
                stalled += 1
            if spinner:
                spinner.status(f"{archive.name} reconnecting ({_human(after)} kept)")
            time.sleep(min(2 * max(stalled, 1), 20))
            continue

        on_disk = part.stat().st_size if part.exists() else 0
        if total and on_disk < total:
            # Server closed early. Resume from where we stopped.
            logger.write(f"\n[preseed] {archive.name}: short read {on_disk}/{total}, resuming\n")
            stalled = 0
            attempt -= 1 if on_disk > before else 0
            continue

        actual = file_digest(part, archive.algorithm)
        if actual == archive.digest:
            part.replace(dest)
            return True

        restarts += 1
        logger.write(
            f"\n[preseed] {archive.name}: checksum mismatch after full transfer\n"
            f"  expected {archive.digest}\n  actual   {actual}\n"
            f"  size     {on_disk}\n  restart  {restarts}/{max_restarts}\n")
        part.unlink(missing_ok=True)
        if restarts > max_restarts:
            return False
        if spinner:
            spinner.status(f"{archive.name} corrupt, restarting from scratch")
        time.sleep(2)

    return False


def preseed_cache(src_dir: Path, cache_dir: Path, logger: Logger,
                  passes: int = 3) -> None:
    """
    Fetch and verify every prebuilt dependency before configure runs.

    Anything still missing after a pass is retried in the next one. Partial
    downloads survive between passes, so each pass resumes rather than starts
    over, and a package that failed early gets more chances once the rest of
    the queue has drained.
    """
    archives = windows_archives(src_dir)
    if not archives:
        info("No dependency manifest found; autobuild will fetch its own downloads")
        return

    cache_dir.mkdir(parents=True, exist_ok=True)

    pending: list[Archive] = []
    for archive in archives:
        target = cache_dir / archive.filename
        if target.exists():
            if file_digest(target, archive.algorithm) == archive.digest:
                continue
            warn(f"Cached {archive.filename} is corrupt; it will be re-fetched")
            target.unlink(missing_ok=True)
        pending.append(archive)

    cached = len(archives) - len(pending)
    if not pending:
        ok(f"All {len(archives)} dependencies already cached and verified")
        return

    say(f"  {len(archives)} dependencies required, {cached} already valid, "
        f"{len(pending)} to fetch", C.CYAN)
    info("Interrupted transfers resume automatically; it is safe to stop and re-run.")
    say()

    for attempt in range(1, passes + 1):
        if attempt > 1:
            say()
            warn(f"{len(pending)} package(s) still incomplete - pass {attempt} of {passes}")
            info("Partial downloads are kept, so these resume where they stopped")
            say()
            time.sleep(3)

        failed: list[Archive] = []
        for index, archive in enumerate(pending, start=1):
            spinner = Spinner(f"[{index}/{len(pending)}] {archive.name}")
            spinner.animate()
            target = cache_dir / archive.filename
            succeeded = download_verified(archive, target, spinner, logger)
            spinner.done("verified" if succeeded else "incomplete", success=succeeded)
            if not succeeded:
                failed.append(archive)

        pending = failed
        if not pending:
            break

    if pending:
        names = ", ".join(a.name for a in pending)
        detail = []
        for archive in pending:
            part = cache_dir / (archive.filename + ".part")
            if part.exists():
                detail.append(f"    {archive.name}: {_human(part.stat().st_size)} downloaded so far")
            else:
                detail.append(f"    {archive.name}: nothing downloaded - check the URL is reachable")
        raise BuildError(
            f"Could not download {len(pending)} dependency archive(s) after {passes} passes:\n"
            f"  {names}\n" + "\n".join(detail) + "\n"
            "  Partial downloads have been kept, so re-running will resume them.\n"
            f"  Details are in {logger.path}"
        )

    ok(f"All {len(archives)} dependencies cached and verified")


def configure(autobuild: Path, src_dir: Path, env: dict, hw: Hardware,
              logger: Logger, channel: str, want_package: bool) -> None:
    header("CONFIGURING")

    args: list[str] = [str(autobuild), "configure", "-A", "64", "-c", BUILD_CONFIG, "--"]

    switch = hw.autobuild_switch()
    if switch:
        args.append(switch)
        say(f"  Optimisation: {switch}  (CPU reports {hw.isa})", C.GREEN)
    else:
        say(f"  Optimisation: baseline  (CPU reports {hw.isa})", C.YELLOW)

    if want_package:
        args.append("--package")
        say("  Packaging:    enabled (required for a runnable viewer)", C.GREEN)
    else:
        warn("Packaging disabled - the built viewer will not be directly runnable")

    args += ["--chan", channel, "-DLL_TESTS:BOOL=FALSE"]

    build_dir = src_dir / f"build-vc{VSVER}-64"
    cache_dir = Path(env.get("AUTOBUILD_INSTALLABLE_CACHE", "")) if env.get(
        "AUTOBUILD_INSTALLABLE_CACHE") else src_dir / "cache"

    say()
    info("First configure downloads several GB of prebuilt libraries. Be patient.")
    say()

    attempts = 3
    for attempt in range(1, attempts + 1):
        lines: list[str] = []
        label = "autobuild configure" if attempt == 1 else f"autobuild configure (retry {attempt - 1})"
        code = run(args, cwd=src_dir, env=env, logger=logger, echo=False,
                   check=False, quiet_label=label, show_progress=True, sink=lines)

        solution = find_solution(build_dir)
        fatal = [ln for ln in lines if CMAKE_FATAL_RE.search(ln)]

        # The exit code alone is not trustworthy: autobuild has been observed
        # returning 0 after CMake aborted, which then fails much later with a
        # confusing "no solution file" error at build time. The generated
        # solution is the real proof that configure succeeded.
        if code == 0 and solution and not fatal:
            ok(f"Build tree ready: {build_dir}")
            ok(f"Solution generated: {solution.name}")
            verify_optimisation(build_dir, hw)
            return

        removed = purge_bad_cache(lines, cache_dir)
        if removed and attempt < attempts:
            say()
            warn(f"{len(removed)} cached dependency archive(s) were corrupt and have been deleted.")
            info("Retrying configure so they download again...")
            say()
            time.sleep(2)
            continue

        # Out of retries, or failed for a reason retrying will not fix.
        detail = "\n".join(f"    {ln[:120]}" for ln in fatal[:10])
        hint = ""
        if removed or any(SHA_MISMATCH_RE.search(ln) for ln in lines):
            hint = (
                "\n  Dependency downloads keep arriving corrupt. The upstream files are\n"
                "  fine, so something local is damaging them - most often antivirus or a\n"
                "  proxy inspecting the transfer. Try excluding the build root from your\n"
                f"  antivirus, then re-run with --clear-cache.\n"
                f"  Cache directory: {cache_dir}"
            )
        elif not solution:
            hint = (
                f"\n  No Firestorm.sln or Firestorm.slnx was generated in {build_dir},\n"
                "  so CMake did not finish. The errors above are the reason."
            )
        raise BuildError(
            f"Configure failed after {attempt} attempt(s) (exit {code}).\n"
            f"{detail}{hint}\n  Full log: {logger.path}"
        )


def verify_optimisation(build_dir: Path, hw: Hardware) -> None:
    """
    Read back CMakeCache.txt and confirm the optimisation flags actually took
    effect. Passing a switch is not the same as it being applied, and a silent
    downgrade to a baseline build is exactly the kind of thing that goes
    unnoticed until someone benchmarks it months later.
    """
    cache = build_dir / "CMakeCache.txt"
    if not cache.exists():
        warn(f"CMakeCache.txt not found at {cache}; cannot verify optimisation flags")
        return

    try:
        text = cache.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        warn(f"Could not read CMakeCache.txt: {exc}")
        return

    def cached(name: str) -> str | None:
        m = re.search(rf"^{re.escape(name)}:BOOL=(\w+)", text, re.MULTILINE)
        return m.group(1).upper() if m else None

    avx = cached("USE_AVX_OPTIMIZATION")
    avx2 = cached("USE_AVX2_OPTIMIZATION")
    wanted = hw.autobuild_switch()

    expected = {"--avx2": ("AVX2", avx2), "--avx": ("AVX", avx)}.get(wanted or "", (None, None))
    label, actual = expected

    if label is None:
        info("Baseline build requested (CPU reports no AVX support)")
        return

    if actual in ("ON", "TRUE", "1", "YES"):
        ok(f"Verified: USE_{label}_OPTIMIZATION=ON  ->  /arch:{label}")
    else:
        warn(f"USE_{label}_OPTIMIZATION is '{actual}' in CMakeCache, expected ON.")
        warn("The viewer will still build, but without the optimisation you asked for.")
        warn(f"Check {cache} and the configure section of the log.")


def build(autobuild: Path, src_dir: Path, env: dict, hw: Hardware, logger: Logger) -> None:
    header("BUILDING")

    build_dir = src_dir / f"build-vc{VSVER}-64"
    if not find_solution(build_dir):
        raise BuildError(
            f"No Firestorm.sln or Firestorm.slnx in {build_dir}.\n"
            "  Configure did not complete, so there is nothing to build.\n"
            "  Re-run with --clear-cache to force dependencies to download again."
        )

    jobs = hw.build_jobs()
    total = hw.threads or 0
    pct = f"{jobs / total * 100:.0f}%" if total else "?"
    say(f"  Compiler processes: {jobs} of {total or '?'} logical processors ({pct})", C.CYAN)
    say("  This typically takes 30-90 minutes. Full output goes to the log.", C.YELLOW)
    say()

    env = dict(env)
    # Firestorm's CMake adds a bare /MP, which means "use every logical
    # processor". MSVC reads two environment variables: CL is prepended to the
    # command line, _CL_ is appended. Appending wins when an option is
    # repeated, so _CL_=/MP<n> is what actually caps the process count.
    existing = env.get("_CL_", "").strip()
    env["_CL_"] = f"{existing} /MP{jobs}".strip()
    # Belt and braces for the MSBuild VC targets.
    env["CL_MPCount"] = str(jobs)

    run(
        [str(autobuild), "build", "-A", "64", "-c", BUILD_CONFIG, "--no-configure"],
        cwd=src_dir,
        env=env,
        logger=logger,
        echo=False,
        quiet_label="Compiling Firestorm",
        show_progress=True,
    )


def locate_viewer(src_dir: Path) -> Path:
    """
    Find the assembled viewer directory. We look for the folder that contains
    both the executable and the app resources, rather than guessing a path.
    """
    build_dir = src_dir / f"build-vc{VSVER}-64"
    candidates: list[tuple[Path, int, Path]] = []

    for exe in build_dir.rglob("*.exe"):
        name = exe.name.lower()
        if not (name.startswith("firestorm") or name.startswith("secondlife")):
            continue
        folder = exe.parent
        markers = sum(
            1 for m in ("app_settings", "skins", "llplugin", "character")
            if (folder / m).exists()
        )
        candidates.append((folder, markers, exe))

    if not candidates:
        raise BuildError(
            f"No viewer executable found under {build_dir}.\n"
            "  The compile may have produced object files but never linked/packaged."
        )

    # Prefer the folder with the most resource markers - that's the packaged one.
    candidates.sort(key=lambda t: t[1], reverse=True)
    best_folder, markers, exe = candidates[0]
    if markers == 0:
        warn(f"Found {exe.name} but no packaged resources next to it.")
        warn("Re-run with packaging enabled, or the viewer will not start.")
    return best_folder


def deploy(src_dir: Path, dest_root: Path, ref: str) -> Path:
    header("DEPLOYING")
    source = locate_viewer(src_dir)
    ok(f"Viewer built at: {source}")

    safe_ref = re.sub(r"[^A-Za-z0-9._-]", "_", ref)
    dest = dest_root / f"Firestorm-{safe_ref}"
    if dest.exists():
        info(f"Removing previous deployment at {dest}")
        shutil.rmtree(dest, ignore_errors=True)

    info(f"Copying to {dest}")
    shutil.copytree(source, dest)
    ok("Deployment complete")
    return dest


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def show_banner() -> None:
    rule()
    say(f"  {APP_NAME}  v{APP_VERSION}", C.BOLD + C.YELLOW if C.enabled else "")
    say("  Builds the Firestorm viewer from source, optimised for this machine.", C.GREY)
    rule()


def show_hardware(hw: Hardware) -> None:
    header("HARDWARE")
    box(
        "SYSTEM",
        [
            f"Processor    : {hw.cpu_name}",
            f"Vendor       : {hw.vendor}",
            f"Cores        : {hw.cores or '?'} physical / {hw.threads or '?'} logical "
            f"(building with {hw.build_jobs()})",
            f"Instruction  : {hw.isa}",
            f"Features     : {', '.join(hw.features) or 'none detected'}",
            f"Memory       : {hw.ram_gb or '?'} GB",
            f"OS           : {hw.os_name}",
        ]
        + [f"GPU          : {g}" for g in hw.gpus[:3]],
    )
    if hw.ram_gb and hw.ram_gb < 12:
        warn(f"Only {hw.ram_gb} GB RAM detected. Linking the viewer may fail below ~16 GB.")


def preflight(build_root: Path, explicit_root: bool = False) -> None:
    if os.name != "nt":
        raise BuildError("This script builds the Windows viewer and must run on Windows.")

    if platform.machine().lower() not in ("amd64", "x86_64"):
        raise BuildError("A 64-bit Windows installation is required (32-bit builds are not supported).")

    try:
        is_admin = ctypes.windll.shell32.IsUserAnAdmin() != 0
    except Exception:
        is_admin = False
    if is_admin:
        warn("Running as Administrator. This is not required and can cause")
        warn("permission problems in the pip cache. Consider running as a normal user.")

    if len(str(build_root)) > MAX_SAFE_ROOT_LEN:
        warn(f"Build root '{build_root}' is long ({len(str(build_root))} chars).")
        warn("Firestorm generates very deep paths; a short root like C:\\fsbuild is safer.")

    check_disk_space(build_root, explicit_root=explicit_root)


DISK_REQUIRED_GB = 60
DISK_ABSOLUTE_MIN_GB = 40


def _drive_report() -> list[tuple[str, float]]:
    """Free space on every fixed drive, largest first."""
    drives: list[tuple[str, float]] = []
    if os.name != "nt":
        return drives
    try:
        mask = ctypes.windll.kernel32.GetLogicalDrives()
    except Exception:
        return drives
    for i in range(26):
        if not (mask >> i) & 1:
            continue
        root = f"{chr(ord('A') + i)}:\\"
        try:
            # 3 == DRIVE_FIXED. Skip optical, network and removable media.
            if ctypes.windll.kernel32.GetDriveTypeW(root) != 3:
                continue
            drives.append((root, shutil.disk_usage(root).free / (1024**3)))
        except Exception:
            continue
    drives.sort(key=lambda d: d[1], reverse=True)
    return drives


def check_disk_space(build_root: Path, explicit_root: bool = False) -> None:
    """
    A full Firestorm build needs a lot of room: the source tree, several GB of
    prebuilt dependencies, and a very large set of object files. Running out
    part-way through wastes an hour, so this refuses to start rather than
    letting the build die at link time.
    """
    try:
        free = shutil.disk_usage(build_root.anchor).free / (1024**3)
    except Exception:
        return

    if free >= DISK_REQUIRED_GB:
        ok(f"Disk space   {free:.0f} GB free on {build_root.anchor}")
        return

    say()
    fail(f"Only {free:.0f} GB free on {build_root.anchor}. A full build needs about {DISK_REQUIRED_GB} GB.")

    alternatives = [(root, gb) for root, gb in _drive_report()
                    if gb >= DISK_REQUIRED_GB and root.upper() != build_root.anchor.upper()]
    if alternatives:
        say()
        say("  These drives have enough room:", C.CYAN)
        for root, gb in alternatives:
            say(f"     {root}  {gb:.0f} GB free", C.CYAN)
        best = alternatives[0][0]
        say()
        if explicit_root:
            say("  You chose this root explicitly. Drop --build-root to let the", C.YELLOW)
            say("  script pick automatically, or point it at one of the above:", C.YELLOW)
            say(f"     AutoBuildInstall-FireStorm.bat --build-root {best}fsbuild", C.YELLOW)
        else:
            say("  Re-run pointing the build somewhere with space, for example:", C.YELLOW)
            say(f"     AutoBuildInstall-FireStorm.bat --build-root {best}fsbuild", C.YELLOW)
    else:
        say()
        say("  No fixed drive on this machine has enough free space.", C.YELLOW)
        say("  Free up space, or point --build-root at an external drive.", C.YELLOW)

    if free < DISK_ABSOLUTE_MIN_GB:
        raise BuildError(
            f"Refusing to start with {free:.0f} GB free - the build would fail part-way through.\n"
            "  Use --build-root to choose a drive with more space."
        )

    say()
    warn(f"You have {free:.0f} GB. The build may still fail when linking.")
    if not confirm("  Continue anyway?", default=False):
        raise SystemExit("Stopped so you can free up space.")


def select_build_root(explicit: Path | None, script_dir: Path) -> Path:
    """
    Decide where to build.

    If the user named a root, that is final. Otherwise choose automatically:
    prefer the drive this script is sitting on (if you put the tool on your
    fast M.2, you almost certainly want to build there), and otherwise the
    fixed drive with the most free space. Detecting that C: is full and then
    refusing to do anything is not helpful when three other drives have room.
    """
    if explicit is not None:
        return explicit.resolve()

    drives = _drive_report()
    if not drives:
        return DEFAULT_BUILD_ROOT

    free_by_root = {root.upper(): gb for root, gb in drives}

    # 1. The drive the script lives on, if it has room.
    script_anchor = script_dir.anchor.upper()
    script_free = free_by_root.get(script_anchor)
    if script_free is not None and script_free >= DISK_REQUIRED_GB:
        chosen = Path(script_dir.anchor) / "fsbuild"
        ok(f"Build root   {chosen}  ({script_free:.0f} GB free, same drive as this script)")
        return chosen

    # 2. Otherwise whichever fixed drive has the most space.
    best_root, best_free = drives[0]
    chosen = Path(best_root) / "fsbuild"
    if best_free >= DISK_REQUIRED_GB:
        if script_free is not None and script_free < DISK_REQUIRED_GB:
            info(f"{script_anchor} has only {script_free:.0f} GB free; looking elsewhere")
        ok(f"Build root   {chosen}  ({best_free:.0f} GB free, most space available)")
        say("  Override with --build-root if you want it somewhere else.", C.GREY)
        return chosen

    # 3. Nothing has enough. Pick the best and let check_disk_space decide.
    warn(f"No drive has {DISK_REQUIRED_GB} GB free; the roomiest is {best_root} at {best_free:.0f} GB")
    return chosen


def main(argv: Sequence[str] | None = None) -> int:
    _init_console()

    parser = argparse.ArgumentParser(
        prog="autobuild_firestorm",
        description="Build the Firestorm viewer on Windows.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent(
            """\
            examples:
              autobuild_firestorm.py
              autobuild_firestorm.py --ref master --yes
              autobuild_firestorm.py --ref Firestorm_Release_7.2.2.79439 --build-root D:\\fs
              autobuild_firestorm.py --check-only
            """
        ),
    )
    parser.add_argument("--ref", metavar="REF",
                        help="Version, tag or branch (skips the menu). Accepts 'latest', '7.2.4', a full tag name, or a branch.")
    parser.add_argument("--build-root", type=Path, default=None,
                        help="Working directory for source and build tree "
                             "(default: auto-selected drive with enough free space)")
    parser.add_argument("--output", type=Path, default=None,
                        help="Where to place the finished viewer (default: alongside this script)")
    parser.add_argument("--channel", default="SelfBuild", help="Viewer channel name suffix")
    parser.add_argument("--no-package", action="store_true",
                        help="Skip --package (faster, but the result will not run)")
    parser.add_argument("--no-preseed", action="store_true",
                        help="Skip the verified dependency pre-download and let autobuild fetch them")
    parser.add_argument("--clear-cache", action="store_true",
                        help="Delete the downloaded dependency cache before configuring")
    parser.add_argument("--fresh", action="store_true",
                        help="Delete the existing source tree and clone again")
    parser.add_argument("--check-only", action="store_true",
                        help="Run detection and prerequisite checks, then stop")
    parser.add_argument("--yes", action="store_true", help="Do not pause for confirmation")
    args = parser.parse_args(argv)

    script_dir = Path(__file__).resolve().parent
    show_banner()

    try:
        build_root = select_build_root(args.build_root, script_dir)
    except Exception:
        build_root = DEFAULT_BUILD_ROOT

    log_path = build_root / "logs" / f"build-{time.strftime('%Y%m%d-%H%M%S')}.log"
    try:
        build_root.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        fail(f"Cannot create build root {build_root}: {exc}")
        return 2
    logger = Logger(log_path)

    try:
        preflight(build_root, explicit_root=args.build_root is not None)

        hw = detect_hardware()
        show_hardware(hw)

        header("PREREQUISITES")
        tc, issues = discover_toolchain()
        if issues:
            say()
            fail("Cannot continue until these are resolved:")
            for i in issues:
                say(f"     - {i}", C.RED)
            return 2
        say()
        ok("All required tools present")

        if args.check_only:
            say()
            say(f"  Check complete. Log: {log_path}", C.CYAN)
            return 0

        ref = choose_version(args.ref, tc.git)

        header("SOURCE")
        src_dir = build_root / "phoenix-firestorm"
        vars_dir = build_root / "fs-build-variables"
        assert tc.git is not None
        sync_repo(tc.git, FS_REPO, src_dir, ref, logger, "Firestorm source",
              force_fresh=args.fresh)
        sync_repo(tc.git, FS_VARS_REPO, vars_dir, "master", logger, "build variables")

        vars_file = vars_dir / "variables"
        if not vars_file.exists():
            raise BuildError(f"Build variables file missing at {vars_file}")
        ok(f"AUTOBUILD_VARIABLES_FILE = {vars_file}")

        header("PYTHON BUILD ENVIRONMENT")
        venv_dir = build_root / "venv"
        autobuild = provision_venv(venv_dir, src_dir, logger)

        env = build_environment(tc, venv_dir, vars_file, build_root)

        if not args.yes:
            say()
            say(f"  Ready to build {ref} into {build_root}", C.CYAN)
            say("  This will take a long time and use a lot of disk.", C.YELLOW)
            if not confirm("  Continue?", default=True):
                return 0

        if args.clear_cache:
            cache_dir = Path(env["AUTOBUILD_INSTALLABLE_CACHE"])
            if cache_dir.is_dir():
                info(f"Clearing dependency cache at {cache_dir}")
                shutil.rmtree(cache_dir, ignore_errors=True)
            cache_dir.mkdir(parents=True, exist_ok=True)
            ok("Dependency cache cleared")

        started = time.time()

        if not args.no_preseed:
            header("DEPENDENCIES")
            preseed_cache(src_dir, Path(env["AUTOBUILD_INSTALLABLE_CACHE"]), logger)

        configure(autobuild, src_dir, env, hw, logger, args.channel, not args.no_package)
        build(autobuild, src_dir, env, hw, logger)
        out_root = args.output.resolve() if args.output else script_dir
        dest = deploy(src_dir, out_root, ref)

        mins = int((time.time() - started) / 60)
        header("BUILD COMPLETE")
        box(
            "RESULT",
            [
                f"Version      : {ref}",
                f"Optimisation : {hw.autobuild_switch() or 'baseline'} ({hw.isa})",
                f"Elapsed      : {mins} minutes",
                f"Installed to : {dest}",
                f"Build log    : {log_path}",
            ],
            C.GREEN,
        )
        return 0

    except KeyboardInterrupt:
        say()
        warn("Interrupted. Re-run to resume - the source tree and cache are preserved.")
        return 130
    except BuildError as exc:
        say()
        rule("!")
        say(f"  BUILD FAILED", C.RED + C.BOLD if C.enabled else "")
        rule("!")
        for line in str(exc).splitlines():
            say(f"  {line}", C.RED)
        say()
        say(f"  Full log: {log_path}", C.YELLOW)
        return 1
    except SystemExit as exc:
        if exc.code not in (0, None):
            say(f"  {exc}", C.YELLOW)
        return int(exc.code or 0)
    finally:
        logger.close()


if __name__ == "__main__":
    sys.exit(main())