# AutoBuildInstall-FireStorm
Status - Alpha

### Description:
"AutoBuildInstall-FireStorm", A Windows-only build-helper that lists recent downloads of Firestorm viewer source, auto-detects your hardware, compiles optimized Release binary with VS2019/VS2022, shows 15-step progress bars for every download, and—on success—drops the finished viewer straight into the folder from which you ran the script, ready to launch.

### Preview:
- The Current output...
```


===============================================================================
    AutoBuildInstall-FireStorm
===============================================================================

Locating Python 3...
  Found via py launcher: Python 3.12.4

Starting builder...

==============================================================================
  AutoBuildInstall-FireStorm  v2.0
  Builds the Firestorm viewer from source, optimised for this machine.
==============================================================================
  [ OK ] Build root   E:\fsbuild  (81 GB free, same drive as this script)
  [ OK ] Disk space   81 GB free on E:\

==============================================================================
  HARDWARE
==============================================================================
+--------------------------------------------------------------------------+
| SYSTEM                                                                   |
+--------------------------------------------------------------------------+
| Processor    : AMD Ryzen 9 3900X 12-Core Processor                       |
| Vendor       : AMD                                                       |
| Cores        : 12 physical / 24 logical (building with 21)               |
| Instruction  : AVX2                                                      |
| Features     : SSE2, SSE3, SSSE3, SSE4.1, SSE4.2, AVX, AVX2              |
| Memory       : 63.9 GB                                                   |
| OS           : Windows 10 (build 10.0.19045)                             |
| GPU          : Radeon (TM) RX 470 Graphics                               |
| GPU          : NVIDIA GeForce GTX 1060 3GB                               |
+--------------------------------------------------------------------------+

==============================================================================
  PREREQUISITES
==============================================================================
  [ OK ] git          git version 2.52.0.windows.1
  [ OK ] cmake        cmake version 3.31.6-msvc6
  [ OK ] Visual Studio 2022  C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools
  [ OK ] cygwin       C:\Program_Files\cygwin64\bin
  [ OK ] NSIS         C:\Program_Files\NSIS\makensis.EXE
  [ OK ] python       3.12.4 (C:\Program Files\Python312\python.exe)

  [ OK ] All required tools present

==============================================================================
  CHOOSE FIRESTORM VERSION
==============================================================================
  [ .. ] Fetching available versions...

  RELEASES  (recommended - what most people want)
    1. 7.2.4.80712     <-- current release
    2. 7.2.3.80036
    3. 7.2.2.79439
    4. 7.1.13.78266
    5. 7.1.11.76496
    6. 7.1.10.75913

  BETAS  (newer, less tested)
    7. 7.2.5.81336
    8. 7.2.5.81269
    9. 7.2.4.80712
   10. 7.2.4.80703

  OTHER
   11. master          (bleeding edge, may not compile)
   12. Enter a tag, branch or version manually
   13. Show all 60 Firestorm tags

  Selection [Enter = 7.2.4.80712, q = quit]: 2
  Using Firestorm_Release_7.2.3.80036

==============================================================================
  SOURCE
==============================================================================
  [ .. ] Firestorm source: existing checkout at Firestorm_Release_7.2.3.80036, updating
  [ OK ] Fetching Firestorm source - ok (00:01)
  [ OK ] Firestorm source up to date at Firestorm_Release_7.2.3.80036
  [ .. ] build variables: existing checkout at master, updating
  [ OK ] Fetching build variables - ok (00:00)
  [ OK ] build variables up to date at master
  [ OK ] AUTOBUILD_VARIABLES_FILE = E:\fsbuild\fs-build-variables\variables

==============================================================================
  PYTHON BUILD ENVIRONMENT
==============================================================================
  [ OK ] Reusing virtual environment at E:\fsbuild\venv
  [ OK ] Upgrading pip - ok (00:00)
  [ .. ] Installing autobuild from the repo's requirements.txt
  [ OK ] Installing build requirements - ok (00:00)
  [ OK ] autobuild    autobuild 3.10.2

  Ready to build Firestorm_Release_7.2.3.80036 into E:\fsbuild
  This will take a long time and use a lot of disk.
  Continue? [Y/n] y

==============================================================================
  DEPENDENCIES
==============================================================================
  56 dependencies required, 4 already valid, 52 to fetch
  [ .. ] Interrupted transfers resume automatically; it is safe to stop and re-run.

  [ OK ] [1/52] boost - verified (00:37)
  [ OK ] [2/52] colladadom - verified (00:24)
  / [3/52] dictionaries [00:33]  dictionaries 7% (512.0KB/6.9MB) 1.1MB/s


(...)

```

### Instruction
- One would need to have installed all the requirements. Currently its not worked yet for me. So there is no way its likely to work for you.

### Development
- Wait until internet sorts itself out, and test/develop again, it makes debugging possibly incomplete installer script a little harder otherwise, and time.

