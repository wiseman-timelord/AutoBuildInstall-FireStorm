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
- HArdware Detection (outdated)...
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

Press any key to continue with installation...

```
- Compiling/Installing (and current/recent issues)...
```
===============================================================================
                          CHECKING BUILD PREREQUISITES

===============================================================================
Building Firestorm 6.x - requires Visual Studio 2019
Detected: CMake 3.26.3.0
Detected: Visual Studio 2019 (for Firestorm 6.6.17)
Detected: autobuild 0.0.0.0
Detected: Python 3.11.0

All prerequisites satisfied!

Creating data directory: C:\Game_Files\AutoBuildInstall-Firestorm\data
Data directory ready

Attempting Git clone first...
Repository: https://github.com/FirestormViewer/phoenix-firestorm.git
Branch/Tag: Firestorm_6.6.17_Release
Download-WithGit called (PS Mode: 7)
  RepoUrl: https://github.com/FirestormViewer/phoenix-firestorm.git
  Branch: Firestorm_6.6.17_Release
  Destination: C:\Game_Files\AutoBuildInstall-Firestorm\data\phoenix-firestorm-F
irestorm_6.6.17_Release
Git found at: C:\Program Files\Git\cmd\git.exe

Cloning repository with built-in git progress...
Executing: git clone --depth=1 --branch Firestorm_6.6.17_Release https://github.
com/FirestormViewer/phoenix-firestorm.git C:\Game_Files\AutoBuildInstall-Firesto
rm\data\phoenix-firestorm-Firestorm_6.6.17_Release
Cloning into 'C:\Game_Files\AutoBuildInstall-Firestorm\data\phoenix-firestorm-Fi
restorm_6.6.17_Release'...
remote: Enumerating objects: 16170, done.
remote: Counting objects: 100% (16170/16170), done.
remote: Compressing objects: 100% (12350/12350), done.
remote: Total 16170 (delta 6996), reused 9237 (delta 3714), pack-reused 0 (from
0)
Receiving objects: 100% (16170/16170), 42.16 MiB | 2.10 MiB/s, done.
Resolving deltas: 100% (6996/6996), done.
Note: switching to 'cd3a50a94fb9c97aeabb414b13fc704d8a9d3b8d'.

You are in 'detached HEAD' state. You can look around, make experimental
changes and commit them, and you can discard any commits you make in this
state without impacting any branches by switching back to a branch.

If you want to create a new branch to retain commits you create, you may
do so (now or later) by using -c with the switch command. Example:

  git switch -c <new-branch-name>

Or undo this operation with:

  git switch -

Turn off this advice by setting config variable advice.detachedHead to false

Updating files: 100% (26393/26393), done.

[OK] Git clone successful - 20 items downloaded
Git clone successful!

Verified: indra directory found at C:\Game_Files\AutoBuildInstall-Firestorm\data
\phoenix-firestorm-Firestorm_6.6.17_Release\indra
Source obtained via Git - skipping ZIP extraction

Patching Variables.cmake...
  if() count: 22, else() count: 7, endif() count: 22
  Patches applied successfully (backup saved as Variables.cmake.backup)
[INFO] Configuring for Visual Studio 2019 (vc160)
Autobuild config: C:\Game_Files\AutoBuildInstall-Firestorm\data\phoenix-firestor
m-Firestorm_6.6.17_Release\autobuild.xml
Cache folders ready
  AUTOBUILD_INSTALLABLE_CACHE: C:\Game_Files\AutoBuildInstall-Firestorm\data\ins
tallable_cache
MSVC path set to: C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\
VC\Tools\MSVC\14.29.30133\bin\Hostx64\x64
Hardware optimization flags detected:
  Compiler flags: /O2 /GL /Oi /Ot /Qvec /fp:fast /DNDEBUG /arch:AVX2
  CMake flags: -DCMAKE_BUILD_TYPE=Release -DUSE_OPENMP=ON -DUSE_AVX2=ON -DUSE_FM
A=ON
Configuring CMake with /O2 /GL /Oi /Ot /Qvec /fp:fast /DNDEBUG /arch:AVX2
Generator: Visual Studio 16 2019
Single configuration attempt
Running autobuild configure...
  [OPTIMIZATION] Using ReleaseFS_AVX2 build configuration
  Working directory: C:\Game_Files\AutoBuildInstall-Firestorm\data\phoenix-fires
torm-Firestorm_6.6.17_Release
  Build configuration: ReleaseFS_AVX2
  Command: autobuild configure -A 64 -c ReleaseFS_AVX2 -- -DLL_TESTS:BOOL=FALSE
Warning: no --id argument or AUTOBUILD_BUILD_ID environment variable specified;
    using a value from the UTC date and time (253530430), which may not be uniqu
e
 'C:\Program Files\CMake\bin\cmake.exe' '-DCMAKE_BUILD_TYPE:STRING=Release' '-DA
DDRESS_SIZE:STRING=64' '-DROOT_PROJECT_NAME:STRING=SecondLife' '-DINSTALL_PROPRI
ETARY=TRUE' '-G' 'Visual Studio 16 2019' '-A' 'x64' '-DLL_TESTS:BOOL=FALSE' '..\
indra'
-- Selecting Windows SDK version 10.0.19041.0 to target Windows 6.3.9600.
-- The C compiler identification is MSVC 19.29.30159.0
-- The CXX compiler identification is MSVC 19.29.30159.0
-- Detecting C compiler ABI info
-- Detecting C compiler ABI info - done
-- Check for working C compiler: C:/Program Files (x86)/Microsoft Visual Studio/
2019/Community/VC/Tools/MSVC/14.29.30133/bin/Hostx64/x64/cl.exe - skipped
-- Detecting C compile features
-- Detecting C compile features - done
-- Detecting CXX compiler ABI info
-- Detecting CXX compiler ABI info - done
-- Check for working CXX compiler: C:/Program Files (x86)/Microsoft Visual Studi
o/2019/Community/VC/Tools/MSVC/14.29.30133/bin/Hostx64/x64/cl.exe - skipped
-- Detecting CXX compile features
-- Detecting CXX compile features - done
CMake Error at cmake/Variables.cmake:105 (endif):
  Flow control statements are not properly nested.
Call Stack (most recent call first):
  CMakeLists.txt:41 (include)


-- Configuring incomplete, errors occurred!
ERROR: default configuration returned 1
For more information: try re-running your command with --verbose or --debug
  Autobuild created build directory: C:\Game_Files\AutoBuildInstall-Firestorm\da
ta\phoenix-firestorm-Firestorm_6.6.17_Release\build-vc160-64
CMake configuration failed - exit code 1

===============================================================================
CMAKE CONFIGURATION FAILED
===============================================================================

===============================================================================
CMAKE CONFIGURATION ERROR
===============================================================================

===============================================================================
ERROR: CMake error: CMake configuration failed with exit code: 1
===============================================================================

Stack Trace:
at Configure-CMake, C:\Game_Files\AutoBuildInstall-Firestorm\phoenix_firestorm_b
uild.ps1: line 1564
at <ScriptBlock>, C:\Game_Files\AutoBuildInstall-Firestorm\phoenix_firestorm_bui
ld.ps1: line 1672

BUILD FAILED (Exit Code: 1)

..PowerShell Script Exited.

Press any key to continue . . .

```
