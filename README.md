# ComfyUI R2 Bootstrap

> Status: experimental work in progress. This repository is public so it can be cloned and tested on disposable GPU pods, but it is not a finished production installer yet.

Bootstrap scripts for rebuilding a disposable ComfyUI GPU pod from assets stored in a private Cloudflare R2 bucket.

The pod is treated as stateless. Models, LoRAs, workflows, and other persistent ComfyUI assets are stored in the user's private R2 bucket. Custom nodes are fetched from their source repositories using a private manifest in that bucket. This repository contains public installation logic and an example manifest, not the user's private node list or credentials.

## Repository Layout

```text
bootstrap/
├── install_from_r2.sh
├── install_from_r2_v2.sh
├── custom_nodes.example.json
├── r2.env.example
└── runtime/
    └── start_comfyui.sh
```

## What Belongs In R2

The relevant bucket paths are:

```text
bootstrap/
└── custom_nodes.json       # private; uploaded by you

comfyui/
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

The installer restores `comfyui/models/` and `comfyui/user/`. It does not restore `comfyui/custom_nodes/` from R2; it installs those repositories from `bootstrap/custom_nodes.json` instead.

## Quick Start

On a fresh GPU pod (enable port 8188), use the active development branch while this project is still under construction:

Before the install command, make sure `bootstrap/custom_nodes.json` has been uploaded to your R2 bucket as described in [Custom Nodes](#custom-nodes).

```bash
cd /workspace
find . -mindepth 1 -maxdepth 1 -exec rm -rf {} +
git clone -b bootstrap-r2-dev https://github.com/arjenjongeling/comfyui-r2-bootstrap.git .
cp bootstrap/r2.env.example bootstrap/r2.env
nano bootstrap/r2.env
bash bootstrap/install_from_r2_v2.sh
```

## Custom Nodes

The installer reads `bootstrap/custom_nodes.json` from the root of your R2 bucket. Create your private copy from the public example and edit it to list the nodes you need:

```bash
cp bootstrap/custom_nodes.example.json bootstrap/custom_nodes.json
nano bootstrap/custom_nodes.json
```

Add one entry per node to the `custom_nodes` array. `name` is the folder name to create under `comfyui/custom_nodes/`; `repository` is the node's HTTPS repository URL. Leave `revision` empty to use the repository's current default version. The example file is only a template; replace or extend its sample entry. The installer handles fetching the repositories; you do not need to run Git commands to maintain the manifest.

Upload the private file to the bucket root's `bootstrap/` path. Substitute the rclone remote and bucket configured for your R2 account:

```bash
rclone copyto \
  bootstrap/custom_nodes.json \
  "YOUR_RCLONE_REMOTE:YOUR_R2_BUCKET/bootstrap/custom_nodes.json" \
  --s3-no-check-bucket \
  --progress
```

The installer will not copy the rest of the bucket's `bootstrap/` directory. Keep `bootstrap/custom_nodes.json` and `bootstrap/r2.env` private; they are excluded from the public project files. Do not upload the private manifest to this public repository.

### Finding A Node's Repository

For a node already installed through ComfyUI Manager, open the Manager's installed-nodes view and use the node's details or repository link. You can also search for the node's name in the Manager's node list or on the node author's documentation page. Copy the repository's HTTPS URL into the `repository` field and use the node's installed folder name for `name`.

The `revision` field is optional. Leave it empty unless you need to pin a specific version. If you do, open the repository in a web browser, find the desired version in its history, and copy its full revision identifier into `revision`.

## Security

Keep `bootstrap/r2.env` and `bootstrap/custom_nodes.json` private. Never publish them or include model files in this repository. The `.example` files are templates and contain no credentials or private node list.

## Status

This project is under active development. The v2 installer restores models and user data from R2, installs custom nodes from the private manifest, and starts ComfyUI after setup completes. Validate it on a disposable pod before relying on it for important workloads.
