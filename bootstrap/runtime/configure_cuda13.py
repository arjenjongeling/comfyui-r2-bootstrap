#!/usr/bin/env python3
"""Safely select and validate the CUDA 13 PyTorch runtime for ComfyUI."""

import csv
import json
import os
import re
import subprocess
import sys
from importlib import metadata
from pathlib import Path


TORCH_PACKAGES = (
    "torch==2.9.1",
    "torchvision==0.24.1",
    "torchaudio==2.9.1",
)
CUDA_INDEX = "https://download.pytorch.org/whl/cu130"


class SetupError(Exception):
    pass


def log(message):
    print(f"[runtime] {message}", file=sys.stderr, flush=True)


def version_tuple(value):
    numbers = re.findall(r"\d+", value)
    return tuple(int(number) for number in numbers[:3])


def cuda_variant(torch_version):
    match = re.search(r"\+cu(\d+)", torch_version)
    if not match:
        return None
    digits = match.group(1)
    if len(digits) < 3:
        return None
    return int(digits[:-1]), int(digits[-1])


def probe_gpus():
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=name,driver_version,compute_cap",
                "--format=csv,noheader",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        log("GPU detection unavailable: nvidia-smi not found; CUDA 13 upgrade skipped")
        return []
    except (subprocess.CalledProcessError, OSError) as exc:
        log(f"GPU detection failed; CUDA 13 upgrade skipped ({exc})")
        return []

    devices = []
    for row in csv.reader(result.stdout.splitlines(), skipinitialspace=True):
        if len(row) < 3:
            continue
        name, driver, compute = (field.strip() for field in row[:3])
        devices.append((name, driver, compute))

    if not devices:
        log("No NVIDIA GPU detected; CUDA 13 upgrade skipped")
        return []

    for name, driver, compute in devices:
        log(f"GPU: {name}; driver {driver}; compute capability {compute}")
    return devices


def cuda13_compatibility(devices):
    if not devices:
        return False, "no NVIDIA GPU detected"

    for name, driver, compute in devices:
        if version_tuple(driver) < (580,):
            return False, f"{name} driver {driver} is below the CUDA 13 minimum 580"
        capability = version_tuple(compute)
        if len(capability) < 2 or capability[:2] < (7, 5):
            return False, f"{name} compute capability {compute} is below 7.5"
    return True, "all GPUs meet the CUDA 13 requirements"


def torch_distribution_version():
    try:
        return metadata.version("torch")
    except metadata.PackageNotFoundError as exc:
        raise SetupError("PyTorch is not installed in the active Python environment") from exc


def cuda13_library_dirs():
    directories = set()
    for distribution in metadata.distributions():
        name = (distribution.metadata.get("Name") or "").lower().replace("_", "-")
        if not name.startswith("nvidia-") or not name.endswith("-cu13"):
            continue
        for package_file in distribution.files or ():
            path = Path(distribution.locate_file(package_file))
            for parent in path.parents:
                if parent.name == "lib" and "nvidia" in parent.parts and parent.is_dir():
                    if any(parent.glob("*.so")) or any(parent.glob("*.so.*")):
                        directories.add(str(parent))
                    break

    result = sorted(directories)
    if not result:
        raise SetupError("CUDA 13 PyTorch is installed, but its NVIDIA library directories were not found")
    if not any((Path(directory) / "libnvrtc-builtins.so.13.0").is_file() for directory in result):
        raise SetupError("CUDA 13 library missing: libnvrtc-builtins.so.13.0")
    return result


def add_library_dirs(directories):
    current = os.environ.get("LD_LIBRARY_PATH", "")
    entries = [entry for entry in current.split(os.pathsep) if entry]
    added = [directory for directory in directories if directory not in entries]
    os.environ["LD_LIBRARY_PATH"] = os.pathsep.join(added + entries)
    log(f"CUDA 13 libraries configured: {os.environ['LD_LIBRARY_PATH']}")


def torch_probe(require_cuda):
    probe = r"""
import json
import torch

available = torch.cuda.is_available()
if available:
    value = torch.tensor([1.0], device="cuda")
    if (value + 1).item() != 2.0:
        raise RuntimeError("CUDA tensor smoke test returned an unexpected result")
print(json.dumps({
    "version": torch.__version__,
    "cuda": torch.version.cuda,
    "available": available,
}))
"""
    result = subprocess.run(
        [sys.executable, "-c", probe],
        capture_output=True,
        text=True,
        env=os.environ.copy(),
    )
    if result.returncode != 0:
        detail = result.stderr.strip().splitlines()
        raise SetupError("PyTorch validation failed: " + (detail[-1] if detail else "unknown error"))
    try:
        state = json.loads(result.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError) as exc:
        raise SetupError("Could not read PyTorch validation result") from exc

    log(f"PyTorch: {state['version']}; CUDA runtime: {state['cuda'] or 'none'}")
    if require_cuda and not state["available"]:
        raise SetupError("An NVIDIA GPU is present, but PyTorch reports CUDA unavailable")
    if state["available"]:
        log("CUDA GPU operation test passed")
    return state


def run_pip(arguments, capture=False):
    output_streams = (
        {"capture_output": True}
        if capture
        else {"stdout": sys.stderr, "stderr": sys.stderr}
    )
    try:
        return subprocess.run(
            [sys.executable, "-m", "pip", *arguments],
            check=True,
            text=True,
            env=os.environ.copy(),
            **output_streams,
        )
    except subprocess.CalledProcessError as exc:
        if capture:
            detail = (exc.stderr or exc.stdout or "").strip().splitlines()
            log("PyTorch wheel preflight failed: " + (detail[-1] if detail else "pip returned an error"))
        raise
    except OSError as exc:
        raise SetupError(f"Could not run pip: {exc}") from exc


def prepare_cuda13(devices):
    version = torch_distribution_version()
    variant = cuda_variant(version)
    log(f"Installed PyTorch distribution: {version}")

    if variant and variant[0] == 13:
        directories = cuda13_library_dirs()
        add_library_dirs(directories)
        state = torch_probe(require_cuda=bool(devices))
        if not state["cuda"] or not state["cuda"].startswith("13."):
            raise SetupError(f"Expected PyTorch CUDA 13.x, but it reports {state['cuda']}")
        log(f"CUDA {state['cuda']} already installed; skipping upgrade")
        return

    compatible, reason = cuda13_compatibility(devices)
    auto_upgrade = os.environ.get("COMFYUI_AUTO_CUDA13", "1")
    if auto_upgrade not in ("0", "1"):
        raise SetupError("COMFYUI_AUTO_CUDA13 must be 0 or 1")

    should_upgrade = bool(variant and variant[0] == 12 and compatible and auto_upgrade == "1")
    if should_upgrade:
        log("CUDA 13 upgrade supported: yes")
        python_version = sys.version_info[:2]
        if python_version < (3, 10):
            log(f"CUDA 13 upgrade skipped: Python {python_version[0]}.{python_version[1]} is too old")
        else:
            packages = list(TORCH_PACKAGES)
            index_args = ["--index-url", CUDA_INDEX]
            log("Checking CUDA 13 PyTorch wheels before changing the environment")
            try:
                run_pip(
                    ["install", "--dry-run", "--only-binary=:all:", *index_args, *packages],
                    capture=True,
                )
            except (subprocess.CalledProcessError, SetupError):
                log("CUDA 13 upgrade skipped; retaining the current PyTorch installation")
            else:
                log("Upgrading PyTorch to 2.9.1+cu130")
                try:
                    run_pip(["install", *index_args, *packages])
                except (subprocess.CalledProcessError, SetupError) as exc:
                    raise SetupError("PyTorch upgrade failed; refusing to start ComfyUI") from exc

                upgraded_version = torch_distribution_version()
                upgraded_variant = cuda_variant(upgraded_version)
                if upgraded_variant != (13, 0):
                    raise SetupError(f"PyTorch upgrade completed with unexpected version {upgraded_version}")
                directories = cuda13_library_dirs()
                add_library_dirs(directories)
                state = torch_probe(require_cuda=True)
                if state["cuda"] != "13.0":
                    raise SetupError(f"PyTorch upgrade reports unexpected CUDA runtime {state['cuda']}")
                log("CUDA 13 PyTorch upgrade and GPU test completed successfully")
                return
    elif not compatible:
        log(f"CUDA 13 upgrade supported: no ({reason})")
    elif auto_upgrade == "0":
        log("CUDA 13 upgrade skipped: COMFYUI_AUTO_CUDA13=0")
    elif not variant or variant[0] != 12:
        log("CUDA 13 upgrade skipped: installed PyTorch is not a CUDA 12 build")

    torch_probe(require_cuda=bool(devices))


def main():
    devices = probe_gpus()
    prepare_cuda13(devices)
    print(os.environ.get("LD_LIBRARY_PATH", ""))


if __name__ == "__main__":
    try:
        main()
    except SetupError as exc:
        log(f"CUDA/PyTorch setup failed: {exc}")
        raise SystemExit(1)
