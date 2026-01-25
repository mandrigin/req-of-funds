# On-Device LLM Options for macOS - Research Findings

**Issue:** rff-1pz6
**Date:** 2026-01-25
**Goal:** Allow AI analysis without internet/API keys using on-device models

## Executive Summary

There are four viable approaches for on-device LLM support in the RFF app, ranging from deeply integrated Apple frameworks to third-party tools. The recommended approach is **Apple Foundation Models Framework** for simplicity and native integration, with **MLX** as a fallback for custom models.

---

## Option 1: Apple Foundation Models Framework (RECOMMENDED)

**Status:** Available in macOS 26 "Tahoe" (released WWDC 2025)

### Overview
Apple's official framework for on-device generative AI. Enables developers to use Apple Intelligence capabilities directly in their apps with as few as 3 lines of Swift code.

### Pros
- Native Swift integration with minimal code
- On-device processing (no cloud, no API keys)
- Free inference (no cost to developers or users)
- Privacy-first design
- Supports: text generation, guided generation, tool calling
- Works offline
- Automatic optimization for Apple Silicon

### Cons
- Requires macOS 26+ (limits deployment target)
- Limited to Apple's built-in models (not customizable)
- May have capability limits compared to cloud APIs

### Integration Complexity
**Low** - 3 lines of Swift code for basic usage

### Example Usage
```swift
import FoundationModels

let model = AppleIntelligence.shared
let response = try await model.generate(prompt: "Analyze this invoice...")
```

### Sources
- [Apple Intelligence Developer Docs](https://developer.apple.com/apple-intelligence/)
- [WWDC 2025 Announcement](https://www.apple.com/newsroom/2025/06/apple-supercharges-its-tools-and-technologies-for-developers/)

---

## Option 2: MLX Framework

**Status:** Stable, officially supported by Apple

### Overview
Apple's array framework for machine learning on Apple silicon. MLX Swift provides native Swift bindings. Now the official Apple-recommended framework for running custom LLMs locally.

### Pros
- Official Apple support (presented at WWDC 2025)
- Optimized for Apple Silicon unified memory
- Supports thousands of Hugging Face models
- Native Swift integration via mlx-swift
- Works on M1-M5 chips (19-27% boost on M5)
- Complete privacy (no data leaves device)
- Supports custom/fine-tuned models

### Cons
- Requires downloading model files (can be large: 2-8GB+)
- User needs sufficient RAM for model
- More complex integration than Foundation Models
- Not all model architectures supported yet

### Integration Complexity
**Medium** - Requires Swift Package Manager integration and model management

### Key Packages
- [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) - Core Swift bindings
- [ml-explore/mlx-lm](https://github.com/ml-explore/mlx-lm) - LLM support
- [LocalLLMClient](https://dev.to/tattn/localllmclient-a-swift-package-for-local-llms-using-llamacpp-and-mlx-1bcp) - Unified MLX + llama.cpp Swift package

### Recommended Models
- **Small (8GB RAM):** Phi-3 Mini 3.8B, Llama 3.2 3B
- **Medium (16GB RAM):** Gemma 3 4B-IT, Qwen 2.5 7B
- **Large (32GB+ RAM):** Llama 3.1 8B

### Sources
- [MLX Official](https://opensource.apple.com/projects/mlx/)
- [WWDC 2025 Session](https://developer.apple.com/videos/play/wwdc2025/298/)
- [MLX on M5](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)

---

## Option 3: Ollama Integration

**Status:** Stable, requires user to install Ollama separately

### Overview
Ollama is a popular tool for running LLMs locally. Users install it separately, and apps connect via localhost HTTP API. Several Swift libraries provide easy integration.

### Pros
- Easy model management (one command to download models)
- Large model ecosystem (Llama, Mistral, CodeLlama, etc.)
- REST API compatible with OpenAI format
- Active community and updates
- Vision model support

### Cons
- **Requires user to install Ollama separately**
- Additional process running in background
- More moving parts to manage
- Detection needed (check if Ollama is running)

### Integration Complexity
**Low-Medium** - Simple HTTP API, but requires Ollama installation

### Swift Libraries
- [OllamaKit](https://github.com/kevinhermawan/OllamaKit) - Full-featured Swift client
- [ollama-swift](https://github.com/mattt/ollama-swift) - Supports structured outputs, tool use, vision

### Example Usage
```swift
import OllamaKit

let client = OllamaKit(baseURL: URL(string: "http://localhost:11434")!)
let response = try await client.generate(
    model: "llama3.2",
    prompt: "Analyze this invoice..."
)
```

### Sources
- [OllamaKit GitHub](https://github.com/kevinhermawan/OllamaKit)
- [NSHipster Ollama Guide](https://nshipster.com/ollama/)
- [Building Local LLM App](https://medium.com/codex/building-a-local-llama-3-app-for-your-mac-with-swift-e96f3a77c0bb)

---

## Option 4: llama.cpp / GGUF Direct Integration

**Status:** Stable, C++ with Swift bindings

### Overview
llama.cpp is a C++ library for running quantized LLMs. Uses GGUF format models. Has Swift Package Manager support.

### Pros
- Very fast (50-100+ tokens/sec on M3/M4)
- Memory efficient (quantized models fit in 4-8GB)
- Huge model selection (any GGUF model works)
- No external dependencies
- Cross-platform

### Cons
- C++ interop complexity
- Need to bundle or download models
- More low-level than other options
- Model management is manual

### Integration Complexity
**Medium-High** - Requires C++ interop, model management

### Swift Integration
- [llama.cpp SPM](https://swiftpackageindex.com/ggml-org/llama.cpp) - Official Swift Package
- [LocalLLMClient](https://dev.to/tattn/localllmclient-a-swift-package-for-local-llms-using-llamacpp-and-mlx-1bcp) - Unified wrapper

### Performance (Apple Silicon)
- M1/M2: ~30-50 tokens/sec
- M3/M4: ~50-100 tokens/sec
- M5: ~120+ tokens/sec

### Sources
- [llama.cpp GitHub](https://github.com/ggml-org/llama.cpp)
- [How to run llama.cpp on Mac 2025](https://t81dev.medium.com/how-to-run-llama-cpp-on-mac-in-2025-local-ai-on-apple-silicon-2e4f8aba70e4)
- [Core ML Llama 3.1](https://machinelearning.apple.com/research/core-ml-on-device-llama)

---

## Comparison Matrix

| Aspect | Foundation Models | MLX | Ollama | llama.cpp |
|--------|------------------|-----|--------|-----------|
| Setup Complexity | Very Low | Medium | Medium | High |
| User Requirements | macOS 26+ | macOS 14+ | Install Ollama | None |
| Model Flexibility | None (Apple only) | High | High | Very High |
| Swift Integration | Native | Native | Via lib | Via lib |
| Offline Capable | Yes | Yes | Yes | Yes |
| Privacy | Full | Full | Full | Full |
| Performance | Optimized | Optimized | Good | Very Good |
| Model Size Control | N/A | User choice | User choice | User choice |
| Maintenance | Apple | Apple | Community | Community |

---

## Recommendation

### Primary: Apple Foundation Models Framework
For users on macOS 26+, use Apple's Foundation Models framework. It provides:
- Zero setup for users
- Native Swift integration
- No model downloads required
- Best privacy guarantees

### Secondary: MLX with LocalLLMClient
For users who want custom models or are on older macOS:
- Add LocalLLMClient package
- Ship with small default model or download on demand
- Offers flexibility without external tools

### Tertiary: Ollama Detection
For power users who already have Ollama:
- Detect if Ollama is running
- Use as additional provider option
- Similar to current Claude Code CLI detection pattern

---

## Implementation Approach

1. **Phase 1:** Add Foundation Models support (new provider type)
   - Check for macOS 26+ availability
   - Add `AIProvider.foundation` case
   - Implement using Foundation Models API

2. **Phase 2:** Add MLX fallback
   - Add LocalLLMClient package
   - Bundle or download small model (Phi-3 Mini ~2GB)
   - Add `AIProvider.localMLX` case

3. **Phase 3:** Ollama detection (optional)
   - Check if Ollama is running on localhost:11434
   - Add `AIProvider.ollama` case
   - Use OllamaKit for integration

---

## Next Steps

1. Verify macOS 26 availability on target devices
2. Prototype Foundation Models integration
3. Evaluate model quality for invoice analysis task
4. If insufficient, add MLX fallback with appropriate model
