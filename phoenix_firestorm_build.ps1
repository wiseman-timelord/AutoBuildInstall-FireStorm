# Requires Powreshell Version 5.1 or higher
# build-fs.ps1 – Universal Firestorm Viewer Builder
# Hardware-optimized compilation with automatic CPU GPU feature detection
# -------------------------------------------------------------------------

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('5', '7')]
    [string]$PSVersion = '5'
)

# Fix for UTF-8 encoding in PowerShell Core
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
}

# Variables Constants
$script:BuildOK = $false
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Powershell Version
$actualVersion = $PSVersionTable.PSVersion
Write-Host "PowerShell Version: $actualVersion" -ForegroundColor Cyan
if ($PSVersion -eq '7' -and $actualVersion.Major -ge 6) {
    Write-Host "Mode: PowerShell Core/7+ features enabled" -ForegroundColor Green
} else {
    Write-Host "Mode: PowerShell 5.1 compatibility mode" -ForegroundColor Yellow
}
Write-Host ""
$dataDir   = "$PSScriptRoot\data"
$finalDir  = "$PSScriptRoot"
$bar       = "=" * 79

# Maps
$script:HardwareProfile = @{
    CPU = @{
        Name = ""
        Vendor = ""
        Cores = 0
        Threads = 0
        Features = @()
    }
    GPU = @()
    RAM = 0
    OS = ""
    OptimizationFlags = ""
    CMakeFlags = @()
}
$tags = @{
    "6.6.17 (Legacy GPU - Simple AND Advanced Lighting)" = @{
        url  = "https://github.com/FirestormViewer/phoenix-firestorm/archive/refs/tags/Firestorm_6.6.17_Release.zip"
        dir  = "phoenix-firestorm-Firestorm_6.6.17_Release"
    }
    "7.2.2.79439 (Modern GPU - ONLY Advanced Lighting)" = @{
        url  = "https://github.com/FirestormViewer/phoenix-firestorm/archive/refs/tags/Firestorm_Release_7.2.2.79439.zip"
        dir  = "phoenix-firestorm-Firestorm_Release_7.2.2.79439"
    }
    "master (bleeding-edge, git clone)" = @{
        url  = "https://github.com/FirestormViewer/phoenix-firestorm.git"   # special value – triggers git
        dir  = "phoenix-firestorm-master"
    }
}

# Functions...
function Header($title) {
    Clear-Host
	Write-Host $bar -ForegroundColor Cyan
    Write-Host $title.PadLeft(($title.Length + 79) / 2).PadRight(80) -ForegroundColor Yellow
    Write-Host $bar -ForegroundColor Cyan
}

function Draw-Box($title, $content, $color = "Cyan") {
    $width = 76
    $topLeft = "╔"
    $topRight = "╗"
    $bottomLeft = "╚"
    $bottomRight = "╝"
    $horizontal = "═"
    $vertical = "║"
    
    Write-Host "$topLeft$($horizontal * $width)$topRight" -ForegroundColor $color
    Write-Host "$vertical $($title.PadRight($width - 2)) $vertical" -ForegroundColor $color
    Write-Host "$vertical$($horizontal * $width)$vertical" -ForegroundColor $color
    
    foreach ($line in $content) {
        Write-Host "$vertical $($line.PadRight($width - 2)) $vertical" -ForegroundColor White
    }
    
    Write-Host "$bottomLeft$($horizontal * $width)$bottomRight" -ForegroundColor $color
}

function Get-CompileThreads {
    $t = $script:HardwareProfile.CPU.Threads
    if ($t -le 0) { $t = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors }
    [math]::Max(1, [math]::Round($t * 0.85))
}

function Get-BuildThreadCount {
    # Returns 85 % of logical CPUs minimum 1
    $threads = $script:HardwareProfile.CPU.Threads
    if ($threads -le 0) { $threads = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors }
    [int]$eightyFive = [math]::Max(1, [math]::Round($threads * 0.85))
    return $eightyFive
}

function Show-ThreadingInfo {
    $total = $script:HardwareProfile.CPU.Threads
    $use   = Get-BuildThreadCount
    Write-Host "  Compiler threads : $use / $total  (85 % calculation)" -ForegroundColor Gray
}

function Test-CPUFeature($featureName) {
    try {
        # Check CPU features using WMIC
        $cpuInfo = Get-CimInstance -ClassName Win32_Processor
        $description = $cpuInfo.Description
        $name = $cpuInfo.Name.ToUpper()
        
        # Detect vendor
        $vendor = "Unknown"
        if ($name -like "*INTEL*") { $vendor = "Intel" }
        elseif ($name -like "*AMD*") { $vendor = "AMD" }
        
        # Feature detection based on processor capabilities
        $features = @()
        
        # Check for AVX support Sandy Bridge+ / Bulldozer+
        if ($cpuInfo.Architecture -eq 9) { # x64
            $features += "SSE4.2"
            
            # Modern processors 2011+ typically have AVX
            try {
                $osInfo = Get-CimInstance Win32_OperatingSystem
                if ($osInfo.OSArchitecture -eq "64-bit") {
                    $features += "AVX"
                }
            } catch {}
        }
        
        # Detect AVX2 Haswell+ / Zen+ - check processor generation
        if ($name -match "i[3579]-[4-9]\d{3}|i[3579]-1[0-9]\d{3}") { # Intel 4th gen+
            $features += "AVX2", "FMA3", "BMI1", "BMI2"
        }
        elseif ($name -match "Ryzen|EPYC|Threadripper") { # AMD Zen+
            $features += "AVX2", "FMA3", "BMI1", "BMI2"
        }
        elseif ($name -match "i[3579]-[12]\d{3}") { # Intel 1st-3rd gen
            $features += "FMA3"
        }
        
        # Detect F16C Ivy Bridge+ / Zen+
        if ($name -match "i[3579]-[3-9]\d{3}|i[3579]-1[0-9]\d{3}|Ryzen|EPYC") {
            $features += "F16C"
        }
        
        # Detect AVX-512 Skylake-X+ / Zen 4+
        if ($name -match "i[79]-[789]\d{2}X|i[79]-1[0-9]\d{2}X|Xeon.*Platinum|Xeon.*Gold|Ryzen.*7[0-9]00") {
            $features += "AVX-512"
        }
        
        return @{
            Vendor = $vendor
            Features = $features
            Name = $cpuInfo.Name
            Cores = $cpuInfo.NumberOfCores
            Threads = $cpuInfo.NumberOfLogicalProcessors
        }
        
    } catch {
        return @{
            Vendor = "Unknown"
            Features = @()
            Name = "Unknown Processor"
            Cores = 0
            Threads = 0
        }
    }
}

function Detect-GPUCapabilities {
    try {
        $gpus = Get-CimInstance Win32_VideoController | Where-Object { 
            $_.AdapterRAM -gt 500MB -and $_.Name -notlike "*Basic*" -and $_.Name -notlike "*Microsoft*"
        }
        
        $gpuList = @()
        
        foreach ($gpu in $gpus) {
            $vramGB = [math]::Round($gpu.AdapterRAM / 1GB, 2)
            $name = $gpu.Name
            $vendor = "Unknown"
            $features = @()
            
            # Detect vendor and capabilities
            if ($name -like "*NVIDIA*" -or $name -like "*GeForce*" -or $name -like "*Quadro*" -or $name -like "*Tesla*") {
                $vendor = "NVIDIA"
                $features += "CUDA"
                
                # Detect RTX Turing+
                if ($name -match "RTX|Titan RTX") {
                    $features += "RTX", "Tensor Cores", "Ray Tracing"
                }
                
                # Detect GTX 10/16/20 series or newer
                if ($name -match "GTX (10|16)|RTX") {
                    $features += "Pascal+"
                }
                
            } elseif ($name -like "*AMD*" -or $name -like "*Radeon*" -or $name -like "*FirePro*") {
                $vendor = "AMD"
                
                # Detect RDNA RX 5000+
                if ($name -match "RX [567]\d{3}|RX [67]\d{3}") {
                    $features += "RDNA", "OpenCL 2.0"
                } else {
                    $features += "GCN", "OpenCL"
                }
                
            } elseif ($name -like "*Intel*") {
                $vendor = "Intel"
                $features += "Quick Sync"
                
                # Detect Arc or Xe
                if ($name -match "Arc|Xe") {
                    $features += "Xe Graphics", "Ray Tracing"
                }
            }
            
            $gpuList += @{
                Name = $name
                Vendor = $vendor
                VRAM = $vramGB
                Features = $features
            }
        }
        
        return $gpuList
        
    } catch {
        return @()
    }
}

function Detect-Hardware {
    Header "HARDWARE DETECTION & OPTIMIZATION ANALYSIS"
    Write-Host ""
    
    try {
        # CPU Detection
        $cpuData = Test-CPUFeature
        $script:HardwareProfile.CPU = $cpuData
        
        $compileThreads = Get-CompileThreads
        $cpuContent = @(
            "Processor    : $($cpuData.Name)",
            "Vendor       : $($cpuData.Vendor)",
            "Cores        : $($cpuData.Cores) physical / $($cpuData.Threads) threads (compile with $compileThreads)",
            "",
            "Detected Instruction Sets:"
        )
        
        if ($cpuData.Features.Count -gt 0) {
            foreach ($feature in $cpuData.Features) {
                $cpuContent += "  [✓] $feature"
            }
        } else {
            $cpuContent += "  [!] No advanced features detected (SSE2 baseline)"
        }
        
        Draw-Box "CPU CAPABILITIES" $cpuContent "Green"
        Write-Host ""
        
        # GPU Detection
        $gpuData = Detect-GPUCapabilities
        $script:HardwareProfile.GPU = $gpuData
        
        if ($gpuData.Count -gt 0) {
            foreach ($gpu in $gpuData) {
                $gpuContent = @(
                    "Device       : $($gpu.Name)",
                    "Vendor       : $($gpu.Vendor)",
                    "VRAM         : $($gpu.VRAM) GB",
                    "",
                    "Capabilities:"
                )
                
                if ($gpu.Features.Count -gt 0) {
                    foreach ($feature in $gpu.Features) {
                        $gpuContent += "  [✓] $feature"
                    }
                } else {
                    $gpuContent += "  [!] Basic graphics capabilities"
                }
                
                Draw-Box "GPU CAPABILITIES" $gpuContent "Magenta"
                Write-Host ""
            }
        } else {
            Write-Host "⚠ No dedicated GPU detected (integrated graphics will be used)" -ForegroundColor Yellow
            Write-Host ""
        }
        
        # RAM Detection
        $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
        $script:HardwareProfile.RAM = $ram
        
        $ramStatus = if ($ram -ge 16) { "Excellent" } 
                     elseif ($ram -ge 8) { "Good" } 
                     else { "Minimum" }
        
        Draw-Box "SYSTEM MEMORY" @(
            "Total RAM    : $ram GB",
            "Build Status : $ramStatus (8GB minimum, 16GB+ recommended)"
        ) "Cyan"
        Write-Host ""
        
        # OS Detection
        $os = Get-CimInstance Win32_OperatingSystem
        $script:HardwareProfile.OS = "$($os.Caption) ($($os.Version))"
        
        Draw-Box "OPERATING SYSTEM" @(
            "OS           : $($os.Caption)",
            "Version      : $($os.Version)",
            "Architecture : $($os.OSArchitecture)"
        ) "White"
        Write-Host ""
        
        # Generate optimization flags
        Generate-OptimizationFlags
        
        # Display optimization summary
        $optContent = @(
            "Compiler     : MSVC (Visual Studio 2019)",
            "Architecture : x64",
            ""
        )
        
        if ($cpuData.Features -contains "AVX-512") {
            $optContent += "Target ISA   : AVX-512 [Maximum Performance]"
        } elseif ($cpuData.Features -contains "AVX2") {
            $optContent += "Target ISA   : AVX2 + FMA3 [High Performance]"
        } elseif ($cpuData.Features -contains "AVX") {
            $optContent += "Target ISA   : AVX [Enhanced Performance]"
        } else {
            $optContent += "Target ISA   : SSE2 [Baseline Compatibility]"
        }
        
        $optContent += ""
        $optContent += "Build Flags  : $($script:HardwareProfile.OptimizationFlags)"
        
        Draw-Box "OPTIMIZATION PROFILE" $optContent "Yellow"
        Write-Host ""

        return $true
        
    } catch {
        Write-Warning "Hardware detection encountered an error: $_"
        return $false
    }
}

function Generate-OptimizationFlags {
    $flags = "/O2 /GL /Oi /Ot /Qvec /fp:fast /DNDEBUG"
    $cmakeFlags = @(
        "-DCMAKE_BUILD_TYPE=Release",
        "-DUSE_OPENMP=ON"
    )
    
    $cpuFeatures = $script:HardwareProfile.CPU.Features
    
    # Select highest available instruction set
    if ($cpuFeatures -contains "AVX-512") {
        $flags += " /arch:AVX512"
        $cmakeFlags += "-DUSE_AVX512=ON"
    } elseif ($cpuFeatures -contains "AVX2") {
        $flags += " /arch:AVX2"
        $cmakeFlags += "-DUSE_AVX2=ON"
    } elseif ($cpuFeatures -contains "AVX") {
        $flags += " /arch:AVX"
        $cmakeFlags += "-DUSE_AVX=ON"
    }
    
    # Add FMA support if available
    if ($cpuFeatures -contains "FMA3") {
        $cmakeFlags += "-DUSE_FMA=ON"
    }
    
    $script:HardwareProfile.OptimizationFlags = $flags
    $script:HardwareProfile.CMakeFlags = $cmakeFlags
}

function Show-CombinedMenu {
    Clear-Host
    $bar = "-" * 79
    Write-Host $bar -ForegroundColor Cyan
    Write-Host "    AutoBuildInstall-FireStorm" -ForegroundColor Yellow
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This Installer Will:" -ForegroundColor White
    Write-Host "    1. Detect your hardware capabilities" -ForegroundColor Gray
    Write-Host "    2. Download Firestorm source code" -ForegroundColor Gray
    Write-Host "    3. Configure optimal build settings" -ForegroundColor Gray
    Write-Host "    4. Compile viewer with hardware-specific optimizations" -ForegroundColor Gray
    Write-Host "    5. Deploy to current directory" -ForegroundColor Gray
    Write-Host ""
    Write-Host ""
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Choose Firestorm Version:"

    # Build numbered list from the $tags hashtable (already ordered in the script)
    $list = @($tags.Keys)
    1..$list.Count | ForEach-Object {
        Write-Host ("   {0,2}. {1}" -f $_, $list[$_-1]) -ForegroundColor White
    }
    Write-Host ""
    Write-Host ""
    Write-Host $bar -ForegroundColor Cyan

    # Version choice
    do {
        $in = Read-Host "Selection (1-$($list.Count)) or [A]bandon"
        if ($in -eq 'A' -or $in -eq 'a') {
            Write-Host "`nInstallation abandoned by user." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
            exit
        }
        [int]$c = 0
    } until ([int]::TryParse($in, [ref]$c) -and $c -ge 1 -and $c -le $list.Count)

    # Store chosen tag / URL / directories exactly like Choose-Tag did
    $script:tag       = $list[$c - 1]
    $script:srcUrl    = $tags[$tag].url
    $script:srcDir    = "$dataDir\$($tags[$tag].dir)"
    $script:buildDir  = "$dataDir\build-$($tag.Split(' ')[0])"

    Write-Host "`nSelected: " -NoNewline -ForegroundColor Cyan
    Write-Host $tag -ForegroundColor Green
    Write-Host ""
}

function Show-ProgressBar($percent, $done, $total) {
    $prog = [char]9608
    $empty = [char]9617
    $steps = 40
    $filled = [math]::Floor($percent / 100 * $steps)
    $emptyCount = $steps - $filled
    $barLine = "$prog" * $filled + "$empty" * $emptyCount
    Write-Host "`r[$barLine] $percent% - $done MB / $total MB" -NoNewline -ForegroundColor Cyan
    if ($percent -ge 100) { Write-Host "" }
}

function Download-WithInvokeWebRequest {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$MaxRetries = 10
    )

    $blocks = 15
    # full / empty are now LOCAL to this helper – no more scope leak
    $full   = [char]9608
    $empty  = [char]9617

    function Draw-Bar($percent) {
        $filled = [math]::Floor(($percent / 100) * $blocks)
        $bar = ($full * $filled) + ($empty * ($blocks - $filled))
        Write-Host "`r[$bar] $([int]$percent)% " -NoNewline -ForegroundColor Cyan
    }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $req = $res = $reader = $writer = $null
        try {
            $existing = if (Test-Path $Destination) {
                (Get-Item $Destination).Length
            } else { 0 }

            $req = [System.Net.HttpWebRequest]::Create($Url)
            if ($existing -gt 0) { $req.AddRange($existing) }

            $res   = $req.GetResponse()
            $total = $existing + $res.ContentLength

            $reader = $res.GetResponseStream()
            $writer = New-Object System.IO.FileStream `
                ($Destination,
                 [System.IO.FileMode]::OpenOrCreate,
                 [System.IO.FileAccess]::Write,
                 [System.IO.FileShare]::ReadWrite)

            $writer.Seek(0, 'End') | Out-Null

            $buffer = New-Object byte[] 65536
            $done = $existing

            while (($read = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $writer.Write($buffer, 0, $read)
                $done += $read
                Draw-Bar ([int](($done / $total) * 100))
            }

            Write-Host ""
            return
        }
        catch {
            if ($attempt -eq $MaxRetries) { throw }
            Start-Sleep -Seconds ([math]::Min(5 * $attempt, 30))
        }
        finally {
            if ($reader) { $reader.Dispose() }
            if ($writer) { $writer.Dispose() }
            if ($res)    { $res.Dispose() }
        }
    }
}

function Robust-Download {
    try {
        New-Item -ItemType Directory -Path $dataDir -ErrorAction SilentlyContinue | Out-Null

        # ---------- git clone path ----------
        if ($srcUrl -like '*.git') {
            Write-Host 'Selected source is Git repository – cloning...' -ForegroundColor Cyan
            if (Download-WithGit -RepoUrl $srcUrl -Branch 'master' -Destination $srcDir) {
                Write-Host "Git clone complete!`n" -ForegroundColor Green
                return
            }
            throw 'Git clone failed – cannot continue'
        }

        # ---------- archive download path ----------
        $zip = "$dataDir\fs.zip"
        Write-Host "`nDownloading $tag from GitHub..." -ForegroundColor Cyan
        Write-Host "Source: $srcUrl`n" -ForegroundColor Gray
        Download-WithInvokeWebRequest -Url $srcUrl -Destination $zip -MaxRetries 10
        Write-Host "Download complete!`n" -ForegroundColor Green
    }
    catch {
        throw "Download error: $_"
    }
}

function Download-WithGit {
    param(
        [string]$RepoUrl,
        [string]$Branch,
        [string]$Destination,
        [int]$MaxRetries = 10
    )

    $blocks = 15
    $full   = [char]9608
    $empty  = [char]9617

    function Draw-Bar($step) {
        $bar = ($full * $step) + ($empty * ($blocks - $step))
        Write-Host "`r[$bar] cloning..." -NoNewline -ForegroundColor Cyan
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "Git not found — falling back to archive download" -ForegroundColor Yellow
        return $false
    }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            if (Test-Path $Destination) {
                Remove-Item $Destination -Recurse -Force
            }

            Draw-Bar 1
            & git clone --depth=1 --branch $Branch $RepoUrl $Destination --progress 2>&1 |
                ForEach-Object {
                    if ($_ -match 'Receiving objects:\s+(\d+)%') {
                        $pct = [int]$Matches[1]
                        Draw-Bar ([int][math]::Min($blocks, [math]::Ceiling($pct / (100 / $blocks))))
                    }
                }

            Write-Host ""
            if ($LASTEXITCODE -eq 0) { return $true }
            throw "Git failed"
        }
        catch {
            if ($attempt -eq $MaxRetries) { return $false }
            Start-Sleep -Seconds ([math]::Min(5 * $attempt, 30))
        }
    }
}


function Expand-Zip($zip) {
    if (Test-Path $srcDir) { 
        Write-Host "Source folder exists – skipping extraction.`n" -ForegroundColor Yellow
        return 
    }
    
    Write-Host "Extracting archive..." -ForegroundColor Cyan
    
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dataDir)
        Write-Host "Extraction complete!`n" -ForegroundColor Green
    } catch {
        $shell = New-Object -ComObject Shell.Application
        $shell.NameSpace($dataDir).CopyHere($shell.NameSpace($zip).Items(), 4 + 16)
        Write-Host "Extraction complete!`n" -ForegroundColor Green
    }
}

function Test-Prerequisites {
    Header "CHECKING BUILD PREREQUISITES"
    
    $issues = @()
    
    $cmake = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmake) {
        Write-Host "[✓] CMake found: $($cmake.Version)" -ForegroundColor Green
    } else {
        Write-Host "[✗] CMake not found" -ForegroundColor Red
        $issues += "CMake is required. Download from: https://cmake.org/download/ "
    }
    
    # Use vswhere to detect Visual Studio 2019
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -version "[16.0,17.0)" -products * -requires Microsoft.Component.MSBuild -property installationPath
        if ($vsPath) {
            $msbuildPath = Join-Path $vsPath "MSBuild\Current\Bin\MSBuild.exe"
            if (Test-Path $msbuildPath) {
                Write-Host "[✓] Visual Studio 2019 found with MSBuild" -ForegroundColor Green
                # Add MSBuild to PATH for this session
                $env:PATH = "$([System.IO.Path]::GetDirectoryName($msbuildPath));$env:PATH"
            } else {
                Write-Host "[✗] MSBuild not found in VS2019 installation" -ForegroundColor Red
                $issues += "MSBuild is missing from VS2019 installation"
            }
        } else {
            Write-Host "[✗] Visual Studio 2019 not found" -ForegroundColor Red
            $issues += "Visual Studio 2019 is required"
        }
    } else {
        Write-Host "[✗] vswhere.exe not found - cannot detect Visual Studio" -ForegroundColor Red
        $issues += "vswhere.exe is required to detect Visual Studio installation"
    }
    
    Write-Host ""
    
    if ($issues.Count -gt 0) {
        foreach ($issue in $issues) {
            Write-Host "  • $issue" -ForegroundColor Yellow
        }
        throw "Prerequisites check failed"
    }
}

function Configure-CMake {
    try {
        if (Test-Path $buildDir) { 
            Remove-Item $buildDir -Recurse -Force 
        }
        
        New-Item -ItemType Directory -Path $buildDir | Out-Null
        
        # CMakeLists.txt is in the 'indra' subdirectory
        $cmakeSourceDir = Join-Path $srcDir "indra"
        
        # Verify CMakeLists.txt exists
        if (-not (Test-Path (Join-Path $cmakeSourceDir "CMakeLists.txt"))) {
            throw "CMakeLists.txt not found in $cmakeSourceDir - source path is incorrect"
        }
        
        # Set required Firestorm build environment variables
        $env:LL_BUILD = $buildDir
        $env:AUTOBUILD_INSTALLABLE_CACHE = Join-Path $dataDir "installable_cache"
        New-Item -ItemType Directory -Path $env:AUTOBUILD_INSTALLABLE_CACHE -Force -ErrorAction SilentlyContinue | Out-Null
        
        Write-Host "Configuring CMake with hardware optimizations..." -ForegroundColor Cyan
        Write-Host "  Source: $cmakeSourceDir" -ForegroundColor Gray
        Write-Host "  Build:  $buildDir" -ForegroundColor Gray
        Write-Host "  Flags:  $($script:HardwareProfile.OptimizationFlags)`n" -ForegroundColor Gray
        
        $cmakeArgs = @(
            "-G", "Visual Studio 16 2019",
            "-A", "x64",
            "-DCMAKE_CXX_FLAGS=`"$($script:HardwareProfile.OptimizationFlags)`"",
            "-S", "`"$cmakeSourceDir`"",
            "-B", "`"$buildDir`""
        ) + $script:HardwareProfile.CMakeFlags
        
        & cmake @cmakeArgs
        
        if ($LASTEXITCODE -ne 0) { throw "CMake failed" }
        
        Write-Host "`nCMake configuration successful!`n" -ForegroundColor Green
    } catch {
        throw "CMake error: $_"
    }
}

function Build-Viewer {
    try {
        $threads = Get-BuildThreadCount          #  <-- ADDED
        Write-Host "Building Release|x64 (using $threads parallel threads)..." -ForegroundColor Cyan
        Write-Host "This may take 30-60 minutes.`n" -ForegroundColor Yellow

        & msbuild "$buildDir\Firestorm.sln" /m:$threads /p:Configuration=Release /p:Platform=x64 /v:minimal

        if ($LASTEXITCODE -ne 0) { throw "Build failed" }

        Write-Host "`nBuild completed!`n" -ForegroundColor Green
    } catch {
        throw "Build error: $_"
    }
}

function Deploy-To-ScriptFolder {
    try {
        $builtBin = "$buildDir\bin\Release"
        if (-not (Test-Path $builtBin)) { 
            throw "Built binaries not found" 
        }
        Write-Host "Deploying viewer..." -ForegroundColor Cyan
        Copy-Item "$builtBin\*" $finalDir -Recurse -Force
        Write-Host "Deployment complete!`n" -ForegroundColor Green
        $script:BuildOK = $true          # <-- NEW
    }
    catch {
        throw "Deployment error: $_"
    }
}

function Summary {
    Header "BUILD COMPLETE"
    
    Write-Host "Version     : " -NoNewline -ForegroundColor Cyan
    Write-Host $tag -ForegroundColor Green
    
    Write-Host "Deployed to : " -NoNewline -ForegroundColor Cyan
    Write-Host $finalDir -ForegroundColor Gray
    
    Write-Host "Optimized   : " -NoNewline -ForegroundColor Cyan
    
    $features = $script:HardwareProfile.CPU.Features -join ", "
    if ($features) {
        Write-Host $features -ForegroundColor Magenta
    } else {
        Write-Host "SSE2 baseline" -ForegroundColor Yellow
    }
    
    Write-Host "`n$bar" -ForegroundColor Green
}

# -------------------------------------------------------------------------
# MAIN EXECUTION
# -------------------------------------------------------------------------

try {
    $host.UI.RawUI.WindowTitle = "Firestorm Viewer Builder"
    Show-CombinedMenu
    Write-Host ""
    Test-Prerequisites
    Robust-Download
    Expand-Zip "$dataDir\fs.zip"
    Configure-CMake
    Build-Viewer
    Deploy-To-ScriptFolder
    if ($script:BuildOK) { Summary }    # <-- CHANGED
}
catch {
    Write-Host "`n$bar" -ForegroundColor Red
    Write-Host "ERROR: $_" -ForegroundColor Red
    Write-Host $bar -ForegroundColor Red
    Write-Host "`nStack Trace:" -ForegroundColor DarkGray
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
    exit 1          # explicitly fail the process
}

exit 0 