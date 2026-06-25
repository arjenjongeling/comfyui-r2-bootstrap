# ComfyUI R2 Bootstrap

> Status: experimental work in progress. This repository is public so it can be cloned and tested on disposable GPU pods, but it is not a finished production installer yet.

Bootstrap scripts for rebuilding a disposable ComfyUI GPU pod from assets stored in a private Cloudflare R2 bucket.

The pod is treated as stateless. Models, LoRAs, custom nodes, workflows, and other persistent ComfyUI assets are stored outside the pod in the user's R2 bucket. This repository contains only public installation and runtime logic.

## Repository Layout

```text
bootstrap/
├── install_from_r2.sh
├── r2.env.example
└── runtime/
    └── start_comfyui.sh
```

## What Belongs In R2

Your R2 bucket should contain a ComfyUI-compatible directory tree:

```text
comfyui/
├── custom_nodes/
├── models/
│   ├── checkpoints/
│   ├── diffusion_models/
│   ├── loras/
│   ├── upscale_models/
│   ├── vae/
│   ├── clip/
│   ├── text_encoders/
│   └── controlnet/
└── user/
    └── default/
        └── workflows/
```

## Quick Start

On a fresh GPU pod (enable port 8188), use the active development branch while this project is still under construction:

```bash
cd /workspace
find . -mindepth 1 -maxdepth 1 -exec rm -rf {} +
git clone -b bootstrap-r2-dev https://github.com/arjenjongeling/comfyui-r2-bootstrap.git .
cp bootstrap/r2.env.example bootstrap/r2.env
nano bootstrap/r2.env
bash bootstrap/install_from_r2.sh
```

## Security

Do not commit `bootstrap/r2.env` or any model files. Only `bootstrap/r2.env.example` belongs in git.

## Status

This project is under active development. The bootstrap script is currently a safe scaffold and will be expanded into the full R2 restore flow.
