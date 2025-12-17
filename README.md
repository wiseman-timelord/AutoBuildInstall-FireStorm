# AutoBuildInstall-FireStorm
Status - Alpha

### Description:
"AutoBuildInstall-FireStorm", A Windows-only build helper that downloads the chosen Firestorm viewer source, auto-detects your hardware, compiles optimized Release binary with VS2019, shows 15-step progress bars for every download, and—on success—drops the finished viewer straight into the folder from which you ran the script, ready to launch.

### Preview:
- The Menu (outdated)...
```
================================================================================

FIRESTORM VIEWER - OPTIMIZED BUILD SYSTEM
================================================================================


This tool will:
  1. Detect your hardware capabilities
  2. Download Firestorm source code
  3. Configure optimal build settings
  4. Compile viewer with hardware-specific optimizations
  5. Deploy to current directory

================================================================================


Selection: [I] Detect, Compile & Install    [A] Abandon Install

Enter your choice: I

```
- HArdware Detection...
```
```
===============================================================================
                  HARDWARE DETECTION & OPTIMIZATION ANALYSIS
===============================================================================

╔════════════════════════════════════════════════════════════════════════════╗
║ CPU CAPABILITIES                                                           ║
║════════════════════════════════════════════════════════════════════════════║
║ Processor    : AMD Ryzen 9 3900X 12-Core Processor                         ║
║ Vendor       : AMD                                                         ║
║ Cores        : 12 physical / 24 threads (compile with 20)                  ║
║                                                                            ║
║ Detected Instruction Sets:                                                 ║
║   [V] SSE4.2                                                               ║
║   [V] AVX                                                                  ║
║   [V] AVX2                                                                 ║
║   [V] FMA3                                                                 ║
║   [V] BMI1                                                                 ║
║   [V] BMI2                                                                 ║
║   [V] F16C                                                                 ║
╚════════════════════════════════════════════════════════════════════════════╝

╔════════════════════════════════════════════════════════════════════════════╗
║ GPU CAPABILITIES                                                           ║
║════════════════════════════════════════════════════════════════════════════║
║ Device       : Radeon (TM) RX 470 Graphics                                 ║
║ Vendor       : AMD                                                         ║
║ VRAM         : 4 GB                                                        ║
║                                                                            ║
║ Capabilities:                                                              ║
║   [V] GCN                                                                  ║
║   [V] OpenCL                                                               ║
╚════════════════════════════════════════════════════════════════════════════╝

╔════════════════════════════════════════════════════════════════════════════╗
║ GPU CAPABILITIES                                                           ║
║════════════════════════════════════════════════════════════════════════════║
║ Device       : NVIDIA GeForce GTX 1060 3GB                                 ║
║ Vendor       : NVIDIA                                                      ║
║ VRAM         : 3 GB                                                        ║
║                                                                            ║
║ Capabilities:                                                              ║
║   [V] CUDA                                                                 ║
║   [V] Pascal+                                                              ║
╚════════════════════════════════════════════════════════════════════════════╝

╔════════════════════════════════════════════════════════════════════════════╗
║ SYSTEM MEMORY                                                              ║
║════════════════════════════════════════════════════════════════════════════║
║ Total RAM    : 31.93 GB                                                    ║
║ Build Status : Excellent (8GB minimum, 16GB+ recommended)                  ║
╚════════════════════════════════════════════════════════════════════════════╝

╔════════════════════════════════════════════════════════════════════════════╗
║ OPERATING SYSTEM                                                           ║
║════════════════════════════════════════════════════════════════════════════║
║ OS           : Microsoft Windows 8.1 Pro                                   ║
║ Version      : 6.3.9600                                                    ║
║ Architecture : 64-bit                                                      ║
╚════════════════════════════════════════════════════════════════════════════╝

╔════════════════════════════════════════════════════════════════════════════╗
║ OPTIMIZATION PROFILE                                                       ║
║════════════════════════════════════════════════════════════════════════════║
║ Compiler     : MSVC (Visual Studio 2019)                                   ║
║ Architecture : x64                                                         ║
║                                                                            ║
║ Target ISA   : AVX2 + FMA3 [High Performance]                              ║
║                                                                            ║
║ Build Flags  : /O2 /GL /Oi /Ot /Qvec /fp:fast /DNDEBUG /arch:AVX2          ║
╚════════════════════════════════════════════════════════════════════════════╝

```
