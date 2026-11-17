import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import configure_cuda13 as setup


class Cuda13SetupTests(unittest.TestCase):
    def test_cuda_variant_parsing(self):
        self.assertEqual(setup.cuda_variant("2.9.1+cu130"), (13, 0))
        self.assertEqual(setup.cuda_variant("2.8.0+cu128"), (12, 8))
        self.assertIsNone(setup.cuda_variant("2.9.1"))

    def test_driver_and_architecture_requirements(self):
        self.assertEqual(
            setup.cuda13_compatibility([("NVIDIA A40", "595.112.07", "8.6")]),
            (True, "all GPUs meet the CUDA 13 requirements"),
        )
        eligible, reason = setup.cuda13_compatibility(
            [("NVIDIA T4", "575.57.08", "7.5")]
        )
        self.assertFalse(eligible)
        self.assertIn("below the CUDA 13 minimum 580", reason)

        eligible, reason = setup.cuda13_compatibility(
            [("Older GPU", "595.112.07", "7.0")]
        )
        self.assertFalse(eligible)
        self.assertIn("below 7.5", reason)

    def test_cuda13_library_detection_requires_nvrtc_builtins(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            library_dir = Path(temp_dir) / "site-packages/nvidia/cuda_nvrtc/lib"
            library_dir.mkdir(parents=True)
            (library_dir / "libnvrtc.so.13").touch()
            nvrtc_builtins = library_dir / "libnvrtc-builtins.so.13.0"
            nvrtc_builtins.touch()
            package_file = Path("nvidia/cuda_nvrtc/lib/libnvrtc-builtins.so.13.0")
            fake_distribution = SimpleNamespace(
                metadata={"Name": "nvidia-cuda-nvrtc-cu13"},
                files=[package_file],
                locate_file=lambda path: Path(temp_dir) / "site-packages" / path,
            )
            with patch.object(setup.metadata, "distributions", return_value=[fake_distribution]):
                self.assertEqual(setup.cuda13_library_dirs(), [str(library_dir)])

            nvrtc_builtins.unlink()
            with patch.object(setup.metadata, "distributions", return_value=[fake_distribution]):
                with self.assertRaisesRegex(setup.SetupError, "libnvrtc-builtins.so.13.0"):
                    setup.cuda13_library_dirs()

    def test_library_path_preserves_existing_entries_without_duplicates(self):
        with patch.dict(os.environ, {"LD_LIBRARY_PATH": "/system:/cuda13"}):
            setup.add_library_dirs(["/cuda13", "/new-cuda13"])
            self.assertEqual(
                os.environ["LD_LIBRARY_PATH"], "/new-cuda13:/system:/cuda13"
            )

    def test_cuda12_build_upgrades_only_after_successful_preflight(self):
        with (
            patch.object(setup, "torch_distribution_version", side_effect=["2.8.0+cu128", "2.9.1+cu130"]),
            patch.object(setup.sys, "version_info", (3, 11)),
            patch.object(setup, "run_pip") as run_pip,
            patch.object(setup, "cuda13_library_dirs", return_value=["/cuda13"]),
            patch.object(setup, "torch_probe", return_value={"cuda": "13.0"}) as torch_probe,
            patch.dict(os.environ, {"COMFYUI_AUTO_CUDA13": "1", "LD_LIBRARY_PATH": ""}),
        ):
            setup.prepare_cuda13([("NVIDIA RTX 6000 Ada", "595.112.07", "8.9")])

        self.assertEqual(run_pip.call_count, 2)
        self.assertIn("--dry-run", run_pip.call_args_list[0].args[0])
        self.assertNotIn("--dry-run", run_pip.call_args_list[1].args[0])
        torch_probe.assert_called_once_with(require_cuda=True)

    def test_a40_cuda12_build_upgrades(self):
        with (
            patch.object(setup, "torch_distribution_version", side_effect=["2.8.0+cu128", "2.9.1+cu130"]),
            patch.object(setup.sys, "version_info", (3, 11)),
            patch.object(setup, "run_pip") as run_pip,
            patch.object(setup, "cuda13_library_dirs", return_value=["/cuda13"]),
            patch.object(setup, "torch_probe", return_value={"cuda": "13.0"}),
            patch.dict(os.environ, {"COMFYUI_AUTO_CUDA13": "1", "LD_LIBRARY_PATH": ""}),
        ):
            setup.prepare_cuda13([("NVIDIA A40", "595.112.07", "8.6")])
        self.assertEqual(run_pip.call_count, 2)

    def test_missing_pytorch_fails_safely(self):
        with patch.object(
            setup,
            "torch_distribution_version",
            side_effect=setup.SetupError("PyTorch is not installed"),
        ):
            with self.assertRaisesRegex(setup.SetupError, "not installed"):
                setup.prepare_cuda13([])

    def test_existing_cuda13_skips_pip(self):
        with (
            patch.object(setup, "torch_distribution_version", return_value="2.9.1+cu130"),
            patch.object(setup, "run_pip") as run_pip,
            patch.object(setup, "cuda13_library_dirs", return_value=["/cuda13"]),
            patch.object(setup, "torch_probe", return_value={"cuda": "13.0"}),
            patch.dict(os.environ, {"LD_LIBRARY_PATH": ""}),
        ):
            setup.prepare_cuda13([("NVIDIA A40", "595.112.07", "8.6")])
        run_pip.assert_not_called()

    def test_opt_out_skips_upgrade_and_keeps_current_cuda(self):
        with (
            patch.object(setup, "torch_distribution_version", return_value="2.8.0+cu128"),
            patch.object(setup, "run_pip") as run_pip,
            patch.object(setup, "torch_probe", return_value={"cuda": "12.8"}) as torch_probe,
            patch.dict(os.environ, {"COMFYUI_AUTO_CUDA13": "0"}),
        ):
            setup.prepare_cuda13([("NVIDIA A40", "595.112.07", "8.6")])
        run_pip.assert_not_called()
        torch_probe.assert_called_once_with(require_cuda=True)

    def test_incompatible_driver_skips_upgrade(self):
        with (
            patch.object(setup, "torch_distribution_version", return_value="2.8.0+cu128"),
            patch.object(setup, "run_pip") as run_pip,
            patch.object(setup, "torch_probe", return_value={"cuda": "12.8"}) as torch_probe,
        ):
            setup.prepare_cuda13([("NVIDIA A40", "575.57.08", "8.6")])
        run_pip.assert_not_called()
        torch_probe.assert_called_once_with(require_cuda=True)

    def test_failed_preflight_retains_current_pytorch(self):
        with (
            patch.object(setup, "torch_distribution_version", return_value="2.8.0+cu128"),
            patch.object(setup.sys, "version_info", (3, 11)),
            patch.object(
                setup,
                "run_pip",
                side_effect=subprocess.CalledProcessError(1, "pip"),
            ) as run_pip,
            patch.object(setup, "torch_probe", return_value={"cuda": "12.8"}) as torch_probe,
        ):
            setup.prepare_cuda13([("NVIDIA A40", "595.112.07", "8.6")])
        run_pip.assert_called_once()
        torch_probe.assert_called_once_with(require_cuda=True)

    def test_failed_upgrade_stops_startup(self):
        with (
            patch.object(setup, "torch_distribution_version", return_value="2.8.0+cu128"),
            patch.object(setup.sys, "version_info", (3, 11)),
            patch.object(
                setup,
                "run_pip",
                side_effect=[None, subprocess.CalledProcessError(1, "pip")],
            ) as run_pip,
        ):
            with self.assertRaisesRegex(setup.SetupError, "refusing to start ComfyUI"):
                setup.prepare_cuda13([("NVIDIA A40", "595.112.07", "8.6")])
        self.assertEqual(run_pip.call_count, 2)

    def test_unusable_upgraded_pytorch_stops_startup(self):
        with (
            patch.object(setup, "torch_distribution_version", side_effect=["2.8.0+cu128", "2.9.1+cu130"]),
            patch.object(setup.sys, "version_info", (3, 11)),
            patch.object(setup, "run_pip"),
            patch.object(setup, "cuda13_library_dirs", return_value=["/cuda13"]),
            patch.object(setup, "torch_probe", side_effect=setup.SetupError("CUDA tensor test failed")),
            patch.dict(os.environ, {"COMFYUI_AUTO_CUDA13": "1", "LD_LIBRARY_PATH": ""}),
        ):
            with self.assertRaisesRegex(setup.SetupError, "CUDA tensor test failed"):
                setup.prepare_cuda13([("NVIDIA A40", "595.112.07", "8.6")])


if __name__ == "__main__":
    unittest.main()
