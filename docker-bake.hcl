# Version pins and image definitions — the single source of truth for both
# local builds (`docker buildx bake <image>`) and CI.

variable "REGISTRY" {
  default = "ghcr.io/jakub-k-slys/runpods"
}

# Comma-separated tags to apply to every image; CI sets e.g. "latest,sha-abc1234".
variable "TAGS" {
  default = "dev"
}

variable "TAILSCALE_VERSION" {
  default = "1.104.2"
}

variable "TAILSCALE_SHA256" {
  default = "512f613ed7d04fc7282f7dc5bd76aa105aae28168fbb9357eb749ebcbc29f0ae"
}

variable "RUNPOD_BASE_IMAGE" {
  default = "runpod/base:1.4.1-ubuntu2404"
}

# CUDA 12.8 runs on any host with a 12.8+ driver; the 13.x tags refuse older drivers.
variable "RUNPOD_COMFYUI_IMAGE" {
  default = "runpod/comfyui:1.4.1-comfyuiv0.35.0-cuda12.8"
}

variable "TENSORFLOW_VERSION" {
  default = "2.21.0"
}

function "image_tags" {
  params = [name]
  result = [for tag in split(",", TAGS) : "${REGISTRY}/${name}:${tag}"]
}

group "default" {
  targets = ["tf", "comfyui"]
}

target "tailscale" {
  context   = "common/tailscale"
  platforms = ["linux/amd64"]
  args = {
    TAILSCALE_VERSION = TAILSCALE_VERSION
    TAILSCALE_SHA256  = TAILSCALE_SHA256
  }
}

target "_pod" {
  platforms = ["linux/amd64"]
  contexts = {
    tailscale = "target:tailscale"
    scripts   = "common/tailscale"
  }
  labels = {
    "org.opencontainers.image.source" = "https://github.com/jakub-k-slys/runpods"
  }
}

target "tf" {
  inherits = ["_pod"]
  context  = "images/tf"
  tags     = image_tags("tf")
  args = {
    BASE_IMAGE         = RUNPOD_BASE_IMAGE
    TENSORFLOW_VERSION = TENSORFLOW_VERSION
  }
}

target "comfyui" {
  inherits = ["_pod"]
  context  = "images/comfyui"
  tags     = image_tags("comfyui")
  args = {
    BASE_IMAGE = RUNPOD_COMFYUI_IMAGE
  }
}
