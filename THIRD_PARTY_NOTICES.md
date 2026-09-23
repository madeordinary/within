# Third-party notices

Within's original application code is MIT licensed. Third-party code and model weights retain their own licenses. The app's MIT license does not relicense the speech model.

## FluidAudio

- Source: https://github.com/FluidInference/FluidAudio
- Pinned commit: `b811a61569aa02691c99b808d08ee989b630c133`
- License: Apache License 2.0. The original `LICENSE` and `ThirdPartyLicenses/` are preserved by the source preparation script.
- Within changes: disable the SDK's centralized log sinks; expose a serial bounded-ingress path to the sliding-window recognizer; treat individual window errors as failures; remove the unused NeMo text-processing binary from dependency resolution. See `Patches/fluidaudio-privacy-and-bounded-ingress.patch`.
- Within invokes local Parakeet ASR only. It does not expose or use the SDK's speech synthesis, diarization, speaker embedding, or cloud download APIs.
- The upstream SDK includes third-party components. Their notices are retained in the vendor source, including fastcluster, VBx, Japanese G2P, and NeMo text processing. The unused NeMo binary is not downloaded or linked by Within.

## NVIDIA Parakeet TDT 0.6B v3

- Original model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Model creator: NVIDIA.
- Core ML conversion: Fluid Inference, https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- Converted model revision: `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`.
- Selected encoder: `Encoder_v2.mlmodelc`, int8-v2 quantization, from that conversion.
- License: Creative Commons Attribution 4.0 International, https://creativecommons.org/licenses/by/4.0/ ; legal terms: https://creativecommons.org/licenses/by/4.0/legalcode.en .
- The model weights are not bundled in the application and are not modified by Within. An explicit download fetches the exact converted files. Their signed-app manifest contains per-file SHA-256 and size. The conversion and quantization were performed by the model distributor, not by Within.
- Credit and source/license links are also included in the app's About view. There is no endorsement by NVIDIA or Fluid Inference.

## Apple frameworks and symbols

AppKit, SwiftUI, AVFoundation, AudioToolbox, Core Audio, Core ML, ApplicationServices, Carbon hotkey APIs, and system symbols are supplied by macOS and used under Apple's applicable platform terms. They are not redistributed as source dependencies.
