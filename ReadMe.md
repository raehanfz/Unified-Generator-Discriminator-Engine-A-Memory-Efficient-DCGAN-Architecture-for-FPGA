# DCGAN FPGA Accelerator

A resource-efficient FPGA-based hardware accelerator for Deep Convolutional Generative Adversarial Network (DCGAN) inference. This design implements both the generator and discriminator networks within a 32KB weight memory budget, enabling deployment on low-cost FPGA platforms.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Module Descriptions](#module-descriptions)
4. [Data Flow](#data-flow)
5. [Memory Organization](#memory-organization)
6. [Specifications](#specifications)
7. [File Structure](#file-structure)
8. [Simulation](#simulation)

---

## Overview

This accelerator implements a complete DCGAN system capable of:
- Generating 32x32x3 RGB images from 24-element noise vectors (Generator)
- Classifying images as real or fake (Discriminator)

The design emphasizes memory efficiency through aggressive model compression and a unified compute engine that handles both convolution and transposed convolution operations.

### Key Features

- Complete GAN implementation (Generator + Discriminator)
- 32KB total weight storage (all weights fit on-chip)
- 4-way parallel MAC compute engine
- Weight caching to eliminate redundant ROM accesses
- Ping-pong RAM for continuous layer processing
- Fixed-point Q8.8 arithmetic throughout

---

## Architecture

### System Block Diagram

```
+-----------------------------------------------------------------------------------+
|                              SYSTEM_TOP_LEVEL                                     |
|                                                                                   |
|  +-------------+     +---------------+                                            |
|  |   NOISE     |     | LAYER_CONFIG  |                                            |
|  | GENERATOR   |     |     ROM       |------> Layer parameters                    |
|  +------+------+     +-------+-------+              |                             |
|         |                    |                      v                             |
|         v                    |         +------------------------+                 |
|  +-------------+             |         |   SYSTEM_CONTROLLER    |                 |
|  | FC_LAYER    |<------------+         |                        |                 |
|  |  HANDLER    |                       |  - State machine       |                 |
|  +------+------+                       |  - Layer sequencing    |                 |
|         |                              |  - Control signals     |                 |
|         v                              +------------------------+                 |
|  +-------------+                                  |                               |
|  | INPUT_MUX   |<---------------------------------+                               |
|  |             |<---- Patch data                  |                               |
|  +------+------+                                  |                               |
|         |                                         |                               |
|         v                                         |                               |
|  +-------------+     +------------------+         |                               |
|  |  COMPUTE    |<----| WEIGHT_STREAMER  |<--------+                               |
|  |   ENGINE    |     |    (CACHED)      |                                         |
|  | (4 MACs)    |     +--------+---------+                                         |
|  +------+------+              |                                                   |
|         |                     |                                                   |
|         v              +------+------+                                            |
|  +-------------+       | WEIGHT_ROM  |                                            |
|  | OUTPUT_MUX  |       |   (32KB)    |                                            |
|  +------+------+       +-------------+                                            |
|         |                                                                         |
|         +----------------+------------------+                                     |
|         |                |                  |                                     |
|         v                v                  v                                     |
|  +-------------+  +-------------+  +----------------+                             |
|  |STREAM_TO_RAM|  |FRAMEBUFFER  |  | DISC_RESULT    |                             |
|  +------+------+  | (3072x16)   |  |   REGISTER     |                             |
|         |         +-------------+  +----------------+                             |
|         v                                                                         |
|  +--------------------+                                                           |
|  | MEMORY_SUBSYSTEM   |                                                           |
|  | +----------------+ |                                                           |
|  | | PINGPONG_RAM   | |                                                           |
|  | | (2x 8192x16)   | |                                                           |
|  | +----------------+ |                                                           |
|  +---------+----------+                                                           |
|            |                                                                      |
|            v                                                                      |
|  +--------------------+                                                           |
|  |     UPSCALER       |                                                           |
|  | (2x nearest neighbor)|                                                         |
|  +---------+----------+                                                           |
|            |                                                                      |
|            v                                                                      |
|  +--------------------+     +------------------+                                  |
|  | PATCH_EXTRACTOR    |---->| PATCH_REPLAY     |                                  |
|  |                    |     |    BUFFER        |----> To INPUT_MUX                |
|  +--------------------+     +------------------+                                  |
|                                                                                   |
+-----------------------------------------------------------------------------------+
```

---

## Module Descriptions

### Top Level

#### system_top_level.v
Top-level wrapper that instantiates and connects all modules. Provides external interface for control signals, status outputs, framebuffer read port, and discriminator result.

Ports:
- Inputs: clk, rst_n, start_generator, start_discriminator, seed_value, seed_load, fb_rd_addr
- Outputs: busy, inference_done, current_layer, fb_rd_data, frame_ready, disc_result, disc_result_valid

---

### Control

#### system_controller.v
Main state machine that orchestrates the entire inference process. Sequences through all generator and discriminator layers, configures each module per layer, and manages data flow control.

States:
- IDLE: Waiting for start signal
- GEN_START: Initialize generator
- LOAD_BIAS: Load bias values from ROM
- FC_CACHE/FC_START/FC_PROCESS: Fully connected layer processing
- CONV_SETUP/CONV_CACHE/CONV_START/CONV_PROCESS: Convolution layer processing
- BANK_SWITCH: Switch ping-pong RAM banks between layers
- DISC_START/DISC_SETUP: Discriminator initialization and layer setup
- OUTPUT/DONE: Final output and completion

#### layer_config_rom.v
Stores configuration parameters for all 9 network layers. Provides weight base addresses, bias addresses, channel counts, spatial dimensions, kernel sizes, strides, padding, and activation types.

Layer configurations:
- Layers 0-4: Generator (G_FC, G_L0 through G_L3)
- Layers 5-8: Discriminator (D_L0 through D_L3)

---

### Compute

#### compute_engine.v
Core computation unit with 4 parallel MAC (multiply-accumulate) channels. Performs the actual convolution operations for all layers.

Features:
- 4 parallel 16-bit multipliers
- 4 independent 48-bit accumulators
- Configurable accumulation limit per output
- Integrated bias addition
- Parallel activation units
- Sequential 4-value output serialization

Data format:
- Input/weights: Q8.8 (16-bit fixed-point)
- Products: Q16.16 (32-bit)
- Accumulators: Q32.16 (48-bit)
- Output: Q8.8 (16-bit after saturation)

#### activation_unit.v
Configurable activation function applied after accumulation and bias addition.

Modes:
- 0: Linear (pass-through)
- 1: ReLU (max(0, x))
- 2: LeakyReLU (x if x > 0, else 0.1x)

---

### Weight Management

#### weight_rom.v
Read-only memory storing all network weights and biases. Total capacity is 32K x 16-bit entries.

Memory map:
- 0-12287: G_FC weights (24 x 512 = 12,288)
- 12288-12799: G_FC biases (512)
- 12800-31087: Remaining layer weights and biases

#### weight_streamer_cached.v
Streams weights from ROM to compute engine with integrated 4-bank BRAM cache. Eliminates redundant ROM reads by caching all weights for current layer.

Features:
- 4-bank parallel cache (3072 entries per bank)
- Single ROM load per layer, multiple cache reads per patch
- Parallel 4-weight output per cycle
- Bias loading and streaming
- Configurable for different layer sizes

Operations:
1. BIAS_LOAD: Load biases from ROM
2. CACHE_LOAD: Load all layer weights into cache
3. STREAM: Serve weights from cache to compute engine

---

### Data Path - Input

#### noise_generator.v
16-bit LFSR (Linear Feedback Shift Register) generating pseudo-random noise values for generator input.

Specifications:
- Polynomial: x^16 + x^14 + x^13 + x^11 + 1
- Period: 65,535 (maximal length)
- Output: 16-bit noise values
- Supports custom seed loading

#### fc_layer_handler.v
Handles the generator's fully connected layer. Buffers 24 noise values and streams them repeatedly for each output group.

Operation:
1. Load 24 noise values into internal buffer
2. Stream all 24 values for each group of 4 outputs
3. Repeat 128 times (512 outputs / 4 parallel)

#### input_mux.v
3-to-1 multiplexer selecting data source for compute engine.

Sources:
- sel=0: FC layer handler (generator FC layer)
- sel=1: Patch replay buffer (convolution layers)
- sel=2: Reserved

#### patch_extractor.v
Extracts KxK patches from input feature maps for convolution operations. Buffers entire input image and outputs patches in sliding window order.

Features:
- Configurable image dimensions and channel count
- Configurable kernel size, stride, and padding
- Handles multi-channel patch extraction
- Outputs patches in row-major order

#### patch_replay_buffer.v
Buffers one complete patch and replays it multiple times for different output channel groups.

Purpose:
- Single patch load from patch_extractor
- Multiple replays to compute engine (one per output group)
- Reduces patch_extractor bandwidth requirements

#### upscaler_simple.v
2x nearest-neighbor upscaler for generator transposed convolution layers.

Operation:
- Duplicates each row (row repeat)
- Duplicates each pixel horizontally
- Bypasses when ups_bypass=1 (for non-upsampling layers)

---

### Data Path - Output

#### output_mux.v
Routes compute engine results to appropriate destination based on current layer.

Destinations:
- sel=0: Stream-to-RAM (intermediate layers)
- sel=1: Output framebuffer (generator final layer G_L3)
- sel=2: Discriminator result register (discriminator final layer D_L3)

---

### Memory Subsystem

#### memory_subsystem.v
Wrapper containing all data memory components and routing logic.

Components:
- Ping-pong RAM (dual banks)
- RAM-to-stream interface
- Stream-to-RAM interface
- Output framebuffer
- Bank controller

#### pingpong_ram.v
Dual-bank RAM allowing simultaneous read from one bank while writing to another.

Specifications:
- 2 banks x 8192 entries x 16 bits
- Bank A: Read while Bank B writes (or vice versa)
- Automatic bank switching between layers

#### ram_to_stream.v
Reads data from ping-pong RAM and streams to processing pipeline.

Features:
- Configurable start address and length
- Optional row repetition (for upscaling support)
- Can read from framebuffer (discriminator input)

#### stream_to_ram.v
Receives processed data and writes to ping-pong RAM.

Features:
- Configurable start address
- Sequential write addressing
- Handshaking with upstream modules

#### output_framebuffer.v
Stores final generator output image (32x32x3 RGB).

Specifications:
- 3072 entries x 16 bits
- Dual-port (write from generator, read for discriminator or external)
- frame_ready signal indicates complete image

---

## Data Flow

### Generator Flow

```
Noise Generator (24 values)
        |
        v
FC Layer Handler (buffers noise)
        |
        v
Input Mux (sel=0)
        |
        v
Compute Engine + Weight Streamer --> Stream-to-RAM --> Pingpong RAM
        |
        |  [Repeat for Conv layers G_L0 through G_L2]
        |
        v
RAM-to-Stream --> Upscaler --> Patch Extractor --> Patch Replay --> Input Mux (sel=1)
        |
        v
Compute Engine + Weight Streamer --> Stream-to-RAM --> Pingpong RAM
        |
        |  [Final layer G_L3]
        |
        v
Output Mux (sel=1) --> Framebuffer (32x32x3)
```

### Discriminator Flow

```
Framebuffer (32x32x3)
        |
        v
RAM-to-Stream (from_fb=1)
        |
        v
Patch Extractor --> Patch Replay --> Input Mux (sel=1)
        |
        v
Compute Engine + Weight Streamer --> Stream-to-RAM --> Pingpong RAM
        |
        |  [Repeat for Conv layers D_L0 through D_L2]
        |
        v
RAM-to-Stream --> Patch Extractor --> Patch Replay --> Input Mux
        |
        |  [Final layer D_L3]
        |
        v
Output Mux (sel=2) --> disc_result register
```

---

## Memory Organization

### Weight ROM Layout (32K x 16-bit)

| Address Range | Content | Size |
|---------------|---------|------|
| 0 - 12287 | G_FC weights | 12,288 |
| 12288 - 12799 | G_FC biases | 512 |
| 12800 - 22015 | G_L0 weights | 9,216 |
| 22016 - 22047 | G_L0 biases | 32 |
| 22048 - 26655 | G_L1 weights | 4,608 |
| 26656 - 26671 | G_L1 biases | 16 |
| 26672 - 27823 | G_L2 weights | 1,152 |
| 27824 - 27831 | G_L2 biases | 8 |
| 27832 - 28047 | G_L3 weights | 216 |
| 28048 - 28050 | G_L3 biases | 3 |
| 28051 - 28242 | D_L0 weights | 192 |
| 28243 - 28246 | D_L0 biases | 4 |
| 28247 - 28758 | D_L1 weights | 512 |
| 28759 - 28766 | D_L1 biases | 8 |
| 28767 - 30814 | D_L2 weights | 2,048 |
| 30815 - 30830 | D_L2 biases | 16 |
| 30831 - 31086 | D_L3 weights | 256 |
| 31087 | D_L3 bias | 1 |

### Weight Cache Organization

4 parallel BRAM banks for simultaneous 4-weight read:
- Bank 0: Filters 0, 4, 8, 12, ...
- Bank 1: Filters 1, 5, 9, 13, ...
- Bank 2: Filters 2, 6, 10, 14, ...
- Bank 3: Filters 3, 7, 11, 15, ...

Maximum cache size: 12,288 entries (for G_FC layer)

---

## Specifications

### Network Parameters

| Parameter | Value |
|-----------|-------|
| Noise vector size (nz) | 24 |
| Generator filter multiplier (ngf) | 8 |
| Discriminator filter multiplier (ndf) | 4 |
| Output image size | 32 x 32 x 3 |
| Total parameters | 31,581 |
| Weight memory | 32KB |

### Layer Configuration

| Layer | Type | In Ch | Out Ch | In Size | Out Size | Kernel | Stride |
|-------|------|-------|--------|---------|----------|--------|--------|
| G_FC | FC | 24 | 512 | 1 | 4x4 | - | - |
| G_L0 | Conv | 32 | 32 | 4x4 | 4x4 | 3x3 | 1 |
| G_L1 | ConvT | 32 | 16 | 4x4 | 8x8 | 3x3 | 1 |
| G_L2 | ConvT | 16 | 8 | 8x8 | 16x16 | 3x3 | 1 |
| G_L3 | ConvT | 8 | 3 | 16x16 | 32x32 | 3x3 | 1 |
| D_L0 | Conv | 3 | 4 | 32x32 | 16x16 | 4x4 | 2 |
| D_L1 | Conv | 4 | 8 | 16x16 | 8x8 | 4x4 | 2 |
| D_L2 | Conv | 8 | 16 | 8x8 | 4x4 | 4x4 | 2 |
| D_L3 | Conv | 16 | 1 | 4x4 | 1x1 | 4x4 | 1 |

### Performance (Simulation @ 100MHz)

| Metric | Value |
|--------|-------|
| Generator cycles | 758,457 |
| Discriminator cycles | 108,978 |
| Total cycles | 867,435 |
| Generator latency | 7.58 ms |
| Discriminator latency | 1.09 ms |
| Total latency | 8.67 ms |
| Throughput | ~115 images/sec |

### Resource Estimates

| Resource | Usage |
|----------|-------|
| Weight ROM | 32K x 16-bit |
| Weight Cache | 12K x 16-bit (4 banks) |
| Ping-pong RAM | 2 x 8K x 16-bit |
| Framebuffer | 3K x 16-bit |
| DSPs | 4 (MAC units) |

---

## File Structure

```
rtl/
├── system_top_level.v        # Top-level wrapper
├── system_controller.v       # Main state machine
├── layer_config_rom.v        # Layer parameters
│
├── compute_engine.v          # 4-way parallel MAC
├── activation_unit.v         # ReLU/LeakyReLU/Linear
│
├── weight_rom.v              # 32KB weight storage
├── weight_streamer_cached.v  # Weight streaming with cache
│
├── noise_generator.v         # LFSR noise source
├── fc_layer_handler.v        # FC layer control
├── input_mux.v               # Input source selection
├── patch_extractor.v         # KxK patch extraction
├── patch_replay_buffer.v     # Patch buffering/replay
├── upscaler_simple.v         # 2x nearest-neighbor
│
├── output_mux.v              # Output routing
│
├── memory_subsystem.v        # Memory wrapper
├── pingpong_ram.v            # Dual-bank RAM
├── ram_to_stream.v           # RAM read interface
├── stream_to_ram.v           # RAM write interface
├── output_framebuffer.v      # Final image storage
│
└── tb_system_top_level.v     # System testbench
```

---

## Simulation

### Requirements

- Icarus Verilog (iverilog) or compatible Verilog simulator
- VCD viewer (GTKWave recommended) for waveform analysis

### Running Simulation

```bash
cd rtl
iverilog -o tb_system tb_system_top_level.v
vvp tb_system
```

### Expected Output

```
==============================================
DCGAN System Testbench - Generator + Discriminator
==============================================

######################################
# GENERATOR TEST                     #
######################################
[CTRL] Starting Generator
[CTRL] FC: Loading bias, output_groups=128
...
[CTRL] Generator complete!

  Generator PASS
    Cycles: 758457
    Outputs: 8216

######################################
# DISCRIMINATOR TEST                 #
######################################
[CTRL] Starting Discriminator
...
[CTRL] Discriminator complete!

  Discriminator PASS
    Cycles: 108978
    Outputs: 1800

==============================================
ALL TESTS PASSED!
==============================================
```

### Viewing Waveforms

```bash
gtkwave tb_system.vcd
```

Key signals to observe:
- `dut.controller_state` - Current state machine state
- `dut.current_layer` - Active layer (0-8)
- `dut.u_compute_engine.data_in` - Input data to compute
- `dut.u_compute_engine.weights_in` - Weight values
- `dut.u_compute_engine.result_out` - Computed results
- `dut.mux_valid_out` / `dut.mux_ready_in` - Data handshaking

---

## License

[Specify license here]

---

## References

1. Radford, A., Metz, L., and Chintala, S. "Unsupervised Representation Learning with Deep Convolutional Generative Adversarial Networks." arXiv:1511.06434, 2015.

2. Liu, S., et al. "Memory-Efficient Architecture for Accelerating Generative Networks on FPGA." International Conference on Field-Programmable Technology (FPT), 2018.