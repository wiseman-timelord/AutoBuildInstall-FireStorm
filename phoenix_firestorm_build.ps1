# Requires Powreshell Version 5.1 or higher
# build-fs.ps1 – Universal Firestorm Viewer Builder
# Hardware-optimized compilation with automatic CPU GPU feature detection
# ---

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('5', '7')]
    [string]$PSVersion = '5'
)

# Fix for UTF8 encoding in PowerShell Core
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
}

# NEW: Global PowerShell mode tracking
$script:PS_MODE = if ($PSVersionTable.PSVersion.Major -ge 6) { '7' } else { '5' }
Write-Host "PowerShell Mode: $($script:PS_MODE) (Actual: $($PSVersionTable.PSVersion))" -ForegroundColor Cyan

# Variables Constants
$script:BuildOK = $false
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$dataDir   = "$PSScriptRoot\data"
$finalDir  = "$PSScriptRoot"
$script:cmakePath = $null
$script:msbuildPath = $null
$script:autobuildPath = $null
$script:gitPath = $null
$script:vsInstallPath = $null
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
    RAM = 0
    OS = ""
    OptimizationFlags = ""
    CMakeFlags = @()
}
$tags = @{
    "CUSTOM" = @{
        url  = ""  # Will be populated dynamically
        dir  = ""  # Will be populated dynamically
    }
    "6.6.17 (Legacy GPU - Simple AND Advanced Lighting)" = @{
        url  = "https://github.com/FirestormViewer/phoenix-firestorm/archive/refs/tags/Firestorm_6.6.17_Release.zip"
        dir  = "phoenix-firestorm-Firestorm_6.6.17_Release"
    }
    "7.2.2.79439 (Modern GPU - ONLY Advanced Lighting)" = @{
        url  = "https://github.com/FirestormViewer/phoenix-firestorm/archive/refs/tags/Firestorm_Release_7.2.2.79439.zip"
        dir  = "phoenix-firestorm-Firestorm_Release_7.2.2.79439"
    }
    "master (bleeding-edge, git clone)" = @{
        url  = "https://github.com/FirestormViewer/phoenix-firestorm.git"   # special value triggers git
        dir  = "phoenix-firestorm-master"
    }
}

function Initialize-BuildEnvironment {
    Write-Host "Initializing build environment..." -F Cyan

    # wipe the entire data tree with verification
    $data = "$PSScriptRoot\data"
    if (Test-Path $data) {
        Write-Host "  Removing data directory..." -F Yellow
        Remove-Item $data -Recurse -Force -EA SilentlyContinue
        
        # Verify deletion was successful
        if (-not (Test-Path $data)) {
            Write-Host "  [OK] Data directory successfully removed" -F Green
        } else {
            Write-Host "  [WARN] Data directory removal may be incomplete" -F Yellow
            # Try one more time with alternate method
            try {
                Remove-Item $data -Recurse -Force -EA Stop
                if (-not (Test-Path $data)) {
                    Write-Host "  [OK] Data directory removed on second attempt" -F Green
                }
            } catch {
                Write-Host "  [ERROR] Could not remove data directory: $_" -F Red
                Write-Host "  This may cause build issues. Consider manually deleting the folder." -F Yellow
            }
        }
    } else {
        Write-Host "  [OK] No existing data directory found" -F Green
    }
	
    # fallback to local build if pre-builts fail
    $env:AUTOBUILD_BUILD_BOOST = "ON"
    $env:AUTOBUILD_BUILD_LLDB  = "ON"

    try {
        "test" | Out-File (Join-Path $PSScriptRoot "test_write.tmp") -EA Stop
        Remove-Item "$PSScriptRoot\test_write.tmp" -Force -EA SilentlyContinue
    } catch {
        Write-Host "  [WARN] Limited write permissions" -F Yellow
    }

    $host.UI.RawUI.WindowTitle = "Firestorm Viewer Builder"
    Write-Host "Initialization complete`n" -F Green
}

function Clear-FailedDependencies {
    Write-Host "`nCleaning up failed dependency downloads..." -ForegroundColor Yellow
    
    $cacheDirs = @(
        "$dataDir\autobuild_cache",
        "$dataDir\installable_cache"
    )
    
    foreach ($cacheDir in $cacheDirs) {
        if (Test-Path $cacheDir) {
            try {
                # Remove partial failed downloads
                Get-ChildItem $cacheDir -Include "*.part", "*.tmp", "*.bz2", "*.gz", "*.zip" -Recurse | 
                    Remove-Item -Force -ErrorAction SilentlyContinue
                Write-Host "  [OK] Cleaned $cacheDir" -ForegroundColor Green
            }
            catch {
                Write-Host "  [WARN] Could not clean cachedir" -ForegroundColor Yellow
            }
        }
    }
    
    # Force clean environment variables
    $env:AUTOBUILD_BUILD_BOOST = "ON"
    $env:AUTOBUILD_BUILD_LLDB = "ON"
    $env:AUTOBUILD_VERBOSE = "ON"  # Enable verbose logging for troubleshooting
    
    Write-Host "Dependency cleanup complete`n" -ForegroundColor Green
}

# Functions
function Header($title) {
    Clear-Host
	Write-Host $bar -ForegroundColor Cyan
    Write-Host $title.PadLeft(($title.Length + 79) / 2).PadRight(80) -ForegroundColor Yellow
    Write-Host $bar -ForegroundColor Cyan
}

function Draw-Box($title, $content, $color = "Cyan") {
    $width = 76
    $topLeft = "+"
    $topRight = "+"
    $bottomLeft = "+"
    $bottomRight = "+"
    $horizontal = "-"
    $vertical = "|"
    
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
    # Returns 85 percent of logical CPUs minimum 1
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
        
        # Check for AVX support Sandy Bridge+ Bulldozer+
        if ($cpuInfo.Architecture -eq 9) { # x64
            $features += "SSE4.2"
            
            # Modern processors 2011 typically have AVX
            try {
                $osInfo = Get-CimInstance Win32_OperatingSystem
                if ($osInfo.OSArchitecture -eq "64-bit") {
                    $features += "AVX"
                }
            } catch {}
        }
        
        # Detect AVX2 Haswell Zen check processor generation
        if ($name -match "i[3579]-[4-9]\d{3}|i[3579]-1[0-9]\d{3}") { # Intel 4th gen+
            $features += "AVX2", "FMA3", "BMI1", "BMI2"
        }
        elseif ($name -match "Ryzen|EPYC|Threadripper") { # AMD Zen
            $features += "AVX2", "FMA3", "BMI1", "BMI2"
        }
        elseif ($name -match "i[3579]-[12]\d{3}") { # Intel 1st-3rd gen
            $features += "FMA3"
        }
        
        # Detect F16C Ivy Bridge Zen+
        if ($name -match "i[3579]-[3-9]\d{3}|i[3579]-1[0-9]\d{3}|Ryzen|EPYC") {
            $features += "F16C"
        }
        
        # Detect AVX-512 Skylake-X Zen 4+
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
                
                # Detect RTX Turing
                if ($name -match "RTX|Titan RTX") {
                    $features += "RTX", "Tensor Cores", "Ray Tracing"
                }
                
                # Detect GTX 10 16 20 series or newer
                if ($name -match "GTX (10|16)|RTX") {
                    $features += "Pascal+"
                }
                
            } elseif ($name -like "*AMD*" -or $name -like "*Radeon*" -or $name -like "*FirePro*") {
                $vendor = "AMD"
                
                # Detect RDNA RX 5000
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
    # Create 78 character bar for consistent borders
    $bar78 = "=" * 78
    
    Clear-Host
    Write-Host $bar78 -ForegroundColor Cyan
    # Center the title text properly
    $title = "HARDWARE DETECTION & OPTIMIZATION ANALYSIS"
    $paddingLeft = [math]::Floor((78 - $title.Length) / 2)
    $paddedTitle = (" " * $paddingLeft) + $title
    Write-Host $paddedTitle -ForegroundColor Yellow
    Write-Host $bar78 -ForegroundColor Cyan
    
    try {
        # CPU Detection
        $cpuData = Test-CPUFeature
        $script:HardwareProfile.CPU = $cpuData
        $compileThreads = Get-CompileThreads
        
        # Determine highest AVX level
        $avxLevel = "SSE2"
        if ($cpuData.Features -contains "AVX-512") {
            $avxLevel = "AVX-512"
        } elseif ($cpuData.Features -contains "AVX2") {
            $avxLevel = "AVX2"
        } elseif ($cpuData.Features -contains "AVX") {
            $avxLevel = "AVX"
        }
        
        # FMA3 is the standard implementation in modern CPUs
        $fmaStatus = if ($cpuData.Features -contains "FMA3") { "FMA3" } else { "None" }
        
        # RAM Detection
        $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
        $script:HardwareProfile.RAM = $ram
        
        # OS Detection
        $os = Get-CimInstance Win32_OperatingSystem
        $script:HardwareProfile.OS = "$($os.Caption) ($($os.Version))"
        
        # Create combined system capabilities content
        $systemContent = @(
            "Processor    : $($cpuData.Name)",
            "Vendor       : $($cpuData.Vendor)",
            "Cores        : $($cpuData.Cores) physical / $($cpuData.Threads) threads (compiling with $compileThreads)",
            "AVX Level    : $avxLevel",
            "FMA Support  : $fmaStatus",
            "Total RAM    : $ram GB",
            "OS           : $($os.Caption)",
            "Version      : $($os.Version)",
            "Architecture : $($os.OSArchitecture)"
        )
        
        Draw-Box "SYSTEM CAPABILITIES" $systemContent "Cyan"
        Write-Host ""
        
        # Generate optimization flags silently no output between boxes
        $null = Generate-OptimizationFlags -Silent $true | Out-Null
        
        # Determine compiler version based on Firestorm version
        $firestormVersion = $script:tag
        $compilerVersion = "MSVC 2019"  # Default to VS2019 for v6
        if ($firestormVersion -match "7\.") {
            $compilerVersion = "MSVC 2022"  # v7 uses VS2022
        } elseif ($firestormVersion -match "master") {
            $compilerVersion = "MSVC 2022"  # master branch uses latest
        } elseif ($firestormVersion -match "Modern GPU") {
            $compilerVersion = "MSVC 2022"  # Modern GPU versions are v7+
        }
        $script:HardwareProfile.Compiler = $compilerVersion
        
        # Determine target ISA for display include FMA3 with all AVX levels
        $targetISA = "SSE2"
        if ($cpuData.Features -contains "AVX-512") {
            $targetISA = "AVX-512"
            if ($cpuData.Features -contains "FMA3") {
                $targetISA += " + FMA3"
            }
        } elseif ($cpuData.Features -contains "AVX2") {
            $targetISA = "AVX2"
            if ($cpuData.Features -contains "FMA3") {
                $targetISA += " + FMA3"
            }
        } elseif ($cpuData.Features -contains "AVX") {
            $targetISA = "AVX"
            if ($cpuData.Features -contains "FMA3") {
                $targetISA += " + FMA3"
            }
        }
        
        # Format CMake flags properly with line breaks
        $cmakeFlags = $script:HardwareProfile.CMakeFlags -join ' '
        
        # Display optimization summary with proper compiler version
        $optContent = @(
            "Compiler     : $($script:HardwareProfile.Compiler)",
            "Architecture : x64",
            "Target ISA   : $targetISA",
            "Compile Flags: $($script:HardwareProfile.OptimizationFlags)",
            "CMake Flags  : $cmakeFlags"
        )
        
        Draw-Box "OPTIMIZATION PROFILE" $optContent "Yellow"
        Write-Host ""
        
        # Add bottom border to complete the layout
        Write-Host $bar78 -ForegroundColor Cyan
        
        # Don't return $true to avoid printing "True" in output
    } catch {
        Write-Warning "Hardware detection encountered an error: $_"
        return $false
    }
}

function Generate-OptimizationFlags {
    param(
        [switch]$Silent = $false
    )
    
    $flags = "/O2 /GL /Oi /Ot /Qvec /fp:fast /DNDEBUG"
    $cmakeFlags = @(
        "-DCMAKE_BUILD_TYPE=Release",
        "-DUSE_OPENMP=ON"
    )
    $cpuFeatures = $script:HardwareProfile.CPU.Features
    
    if (-not $Silent) {
        Write-Host "Detected CPU features: $($cpuFeatures -join ', ')" -F Cyan
    }
    
    # Select highest available instruction set with FMA support
    if ($cpuFeatures -contains "AVX-512") {
        $flags += " /arch:AVX512"
        $cmakeFlags += "-DUSE_AVX512=ON"
        if (-not $Silent) {
            Write-Host "[OPTIMIZATION] Using AVX-512 instruction set" -F Green
        }
    } 
    elseif ($cpuFeatures -contains "AVX2") {
        $flags += " /arch:AVX2"
        $cmakeFlags += "-DUSE_AVX2=ON"
        if (-not $Silent) {
            Write-Host "[OPTIMIZATION] Using AVX2 instruction set" -F Green
        }
        # Always enable FMA3 with AVX2 if available
        if ($cpuFeatures -contains "FMA3") {
            $cmakeFlags += "-DUSE_FMA=ON"
            if (-not $Silent) {
                Write-Host "[OPTIMIZATION] Enabling FMA3 support (AVX2+FMA)" -F Green
            }
        } else {
            if (-not $Silent) {
                Write-Host "[INFO] AVX2 detected but FMA3 not available" -F Yellow
            }
        }
    } 
    elseif ($cpuFeatures -contains "AVX") {
        $flags += " /arch:AVX"
        $cmakeFlags += "-DUSE_AVX=ON"
        if (-not $Silent) {
            Write-Host "[OPTIMIZATION] Using AVX instruction set" -F Green
        }
        # Enable FMA3 with AVX if available
        if ($cpuFeatures -contains "FMA3") {
            $cmakeFlags += "-DUSE_FMA=ON"
            if (-not $Silent) {
                Write-Host "[OPTIMIZATION] Enabling FMA3 support (AVX+FMA)" -F Green
            }
        }
    } 
    else {
        if (-not $Silent) {
            Write-Host "[OPTIMIZATION] Using SSE2 baseline instruction set" -F Yellow
        }
    }
    
    # Always enable FMA if detected, regardless of instruction set
    if ($cpuFeatures -contains "FMA3") {
        if ($cmakeFlags -notcontains "-DUSE_FMA=ON") {
            $cmakeFlags += "-DUSE_FMA=ON"
            if (-not $Silent) {
                Write-Host "[OPTIMIZATION] Forcing FMA3 support (CPU capability detected)" -F Magenta
            }
        }
    }
    
    $script:HardwareProfile.OptimizationFlags = $flags
    $script:HardwareProfile.CMakeFlags = $cmakeFlags
    
    if (-not $Silent) {
        Write-Host "Generated compiler flags: $flags" -F Cyan
        Write-Host "Generated CMake flags: $($cmakeFlags -join ' ')" -F Cyan
    }
}

function Show-CombinedMenu {
    do {
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

        # Build numbered list from the tags hashtable excluding CUSTOM
        $list = @($tags.Keys | Where-Object { $_ -ne "CUSTOM" })
        1..$list.Count | ForEach-Object {
            Write-Host ("   {0,2}. {1}" -f $_, $list[$_-1]) -ForegroundColor White
        }
        
        # Add custom revision option
        $customOption = $list.Count + 1
        Write-Host ("   {0,2}. {1}" -f $customOption, "Enter A Revision Number") -ForegroundColor White
        
        Write-Host ""
        Write-Host ""
        Write-Host $bar -ForegroundColor Cyan

        # Version choice
        $in = Read-Host "Selection (1-$customOption) or [A]bandon"
        if ($in -eq 'A' -or $in -eq 'a') {
            Write-Host "`nInstallation abandoned by user." -ForegroundColor Yellow
            Start-Sleep -Seconds 2
            exit
        }
        
        [int]$c = 0
        if (-not [int]::TryParse($in, [ref]$c) -or $c -lt 1 -or $c -gt $customOption) {
            continue
        }
        
        # Handle custom revision option
        if ($c -eq $customOption) {
            $customInfo = Get-CustomRevision -MenuCount $list.Count
            if ($null -eq $customInfo) {
                continue  # Return to menu
            }
            
            # Set script variables for custom revision
            $script:tag       = $customInfo.Tag
            $script:srcUrl    = $customInfo.Url
            $script:srcDir    = "$dataDir\$($customInfo.Dir)"
            $script:buildDir  = "$dataDir\build-custom-$($customInfo.Tag.Split(' ')[0])"
            
            Write-Host "`nSelected: " -NoNewline -ForegroundColor Cyan
            Write-Host $script:tag -ForegroundColor Green
            Write-Host ""
            return
        }
        
        # Handle standard selections
        $script:tag       = $list[$c - 1]
        $script:srcUrl    = $tags[$tag].url
        $script:srcDir    = "$dataDir\$($tags[$tag].dir)"
        $script:buildDir  = "$dataDir\build-$($tag.Split(' ')[0])"

        Write-Host "`nSelected: " -NoNewline -ForegroundColor Cyan
        Write-Host $tag -ForegroundColor Green
        Write-Host ""
        return
        
    } while ($true)
}

function Show-TransferRate($bytesDownloaded, $startTime) {
    try {
        $elapsed = ([DateTime]::Now - $startTime).TotalSeconds
        if ($elapsed -le 0) { return }
        
        $bytesPerSecond = $bytesDownloaded / $elapsed
        
        # Format transfer rate
        $rateUnit = "B/s"
        $rateValue = $bytesPerSecond
        if ($bytesPerSecond -ge 1MB) {
            $rateValue = [math]::Round($bytesPerSecond / 1MB, 2)
            $rateUnit = "MB/s"
        } elseif ($bytesPerSecond -ge 1KB) {
            $rateValue = [math]::Round($bytesPerSecond / 1KB, 2)
            $rateUnit = "KB/s"
        }
        
        # Format downloaded amount
        $downloadUnit = "B"
        $downloadValue = $bytesDownloaded
        if ($bytesDownloaded -ge 1GB) {
            $downloadValue = [math]::Round($bytesDownloaded / 1GB, 2)
            $downloadUnit = "GB"
        } elseif ($bytesDownloaded -ge 1MB) {
            $downloadValue = [math]::Round($bytesDownloaded / 1MB, 2)
            $downloadUnit = "MB"
        } elseif ($bytesDownloaded -ge 1KB) {
            $downloadValue = [math]::Round($bytesDownloaded / 1KB, 2)
            $downloadUnit = "KB"
        }
        
        Write-Host "`rTransfer Rate: $rateValue$rateUnit, Downloaded: $downloadValue$downloadUnit    " -NoNewline -ForegroundColor Cyan
    } catch {
        # Silently handle console output errors
    }
}

function Show-ProgressBar($percent, $done, $total) {
    try {
        $steps = 40
        $filled = [int][math]::Floor($percent / 100 * $steps)
        $emptyCount = $steps - $filled
        
        # PowerShell 5 7 compatible
        if ($script:PS_MODE -eq '7') {
            $prog = [char]0x2588
            $empty = [char]0x2591
        } else {
            $prog = '#'
            $empty = '-'
        }
        
        $barFilled = ''
        $barEmpty = ''
        for ($i = 0; $i -lt $filled; $i++) { $barFilled += $prog }
        for ($i = 0; $i -lt $emptyCount; $i++) { $barEmpty += $empty }
        $barLine = $barFilled + $barEmpty
        
        Write-Host "`r[$barLine] $percent% - $done MB / $total MB" -NoNewline -ForegroundColor Cyan
        if ($percent -ge 100) { Write-Host "" }
    } catch {
        # Silently handle console output errors
        # This prevents the "A device attached to the system is not functioning" error
    }
}

function Get-CustomRevision {
    param([int]$MenuCount)
    
    Clear-Host
    $bar = "-" * 79
    Write-Host $bar -ForegroundColor Cyan
    Write-Host "    Custom Revision Download" -ForegroundColor Yellow
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Enter a Firestorm revision number (e.g., 7.3.22, 6.6.17)" -ForegroundColor White
    Write-Host "Leave blank to return to the main menu" -ForegroundColor Gray
    Write-Host ""
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ""
    
    $revision = Read-Host "Enter the revision number"
    
    # Return to menu if blank
    if ([string]::IsNullOrWhiteSpace($revision)) {
        return $null
    }
    
    # Basic validation: should be in format like X.X.X or X.X.X.X
    if ($revision -notmatch '^\d+\.\d+(\.\d+)?(\.\d+)?$') {
        Write-Host "`nInvalid revision format. Expected format: X.X.X or X.X.X.X" -ForegroundColor Red
        Write-Host "Press any key to return to menu..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return $null
    }
    
    # Construct the tag name Firestorm uses different formats, try the most common
    $possibleTags = @(
        "Firestorm_$($revision.Replace('.', '_'))_Release",
        "Firestorm_Release_$revision",
        "Release_$revision"
    )
    
    Write-Host "`nValidating revision $revision..." -ForegroundColor Cyan
    
    # Try to validate the tag exists on GitHub
    $validTag = $null
    foreach ($tag in $possibleTags) {
        $testUrl = "https://github.com/FirestormViewer/phoenix-firestorm/releases/tag/$tag"
        try {
            $response = Invoke-WebRequest -Uri $testUrl -Method Head -UseBasicParsing -ErrorAction SilentlyContinue
            if ($response.StatusCode -eq 200) {
                $validTag = $tag
                Write-Host "[OK] Found tag: $tag" -ForegroundColor Green
                break
            }
        } catch {
            # Continue to next possibility
        }
    }
    
    if (-not $validTag) {
        Write-Host "`n[WARNING] Could not verify tag exists on GitHub" -ForegroundColor Yellow
        Write-Host "Will attempt to download using: Firestorm_$($revision.Replace('.', '_'))_Release" -ForegroundColor Yellow
        $validTag = "Firestorm_$($revision.Replace('.', '_'))_Release"
        Write-Host ""
        $confirm = Read-Host "Continue anyway? (Y/N)"
        if ($confirm -ne 'Y' -and $confirm -ne 'y') {
            return $null
        }
    }
    
    # Return the custom tag info
    return @{
        Tag = "$revision (Custom Revision)"
        Url = "https://github.com/FirestormViewer/phoenix-firestorm/archive/refs/tags/$validTag.zip"
        Dir = "phoenix-firestorm-$validTag"
    }
}

function Download-WithInvokeWebRequest {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$MaxRetries = 10
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "`nRetry attempt $attempt of $MaxRetries" -ForegroundColor Yellow
        }
        try {
            # Enable TLS 1.2
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $webClient = New-Object System.Net.WebClient
            $webClient.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
            $webClient.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
            $response = $webClient.OpenRead($Url)
            $totalLength = $response.Length
            $fileStream = New-Object System.IO.FileStream($Destination, [System.IO.FileMode]::Create)
            $buffer = New-Object byte[] 65536
            $totalRead = 0
            $lastPercent = -1
            $startTime = [DateTime]::Now
            
            while (($read = $response.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $read)
                $totalRead += $read
                
                # For GitHub tag downloads, totalLength is often 0 or -1
                if ($totalLength -gt 0) {
                    # Known size - use percentage progress
                    $percent = [int](($totalRead / $totalLength) * 100)
                    if ($percent -ne $lastPercent -and ($percent % 5 -eq 0 -or $percent -eq 100)) {
                        try {
                            Show-ProgressBar $percent ([math]::Round($totalRead / 1MB, 1)) ([math]::Round($totalLength / 1MB, 1))
                        } catch {
                            # Silently continue if console output fails
                        }
                        $lastPercent = $percent
                    }
                } else {
                    # Unknown size - show transfer rate and downloaded amount
                    $elapsed = ([DateTime]::Now - $startTime).TotalSeconds
                    if ($elapsed -gt 0) {
                        $bytesPerSecond = $totalRead / $elapsed
                        
                        # Format transfer rate
                        $rateUnit = "B/s"
                        $rateValue = $bytesPerSecond
                        if ($bytesPerSecond -ge 1MB) {
                            $rateValue = [math]::Round($bytesPerSecond / 1MB, 2)
                            $rateUnit = "MB/s"
                        } elseif ($bytesPerSecond -ge 1KB) {
                            $rateValue = [math]::Round($bytesPerSecond / 1KB, 2)
                            $rateUnit = "KB/s"
                        }
                        
                        # Format downloaded amount
                        $downloadUnit = "B"
                        $downloadValue = $totalRead
                        if ($totalRead -ge 1GB) {
                            $downloadValue = [math]::Round($totalRead / 1GB, 2)
                            $downloadUnit = "GB"
                        } elseif ($totalRead -ge 1MB) {
                            $downloadValue = [math]::Round($totalRead / 1MB, 2)
                            $downloadUnit = "MB"
                        } elseif ($totalRead -ge 1KB) {
                            $downloadValue = [math]::Round($totalRead / 1KB, 2)
                            $downloadUnit = "KB"
                        }
                        
                        try {
                            Write-Host "`rTransfer Rate: $rateValue$rateUnit, Downloaded: $downloadValue$downloadUnit    " -NoNewline -ForegroundColor Cyan
                        } catch {
                            # Silently handle console output errors
                        }
                    }
                }
            }
            
            $fileStream.Close()
            $response.Close()
            $webClient.Dispose()
            
            # Final display
            if ($totalLength -gt 0) {
                try {
                    Write-Host "`rDownload: 100% complete                    " -ForegroundColor Green
                } catch {
                    # Ignore console errors
                }
            } else {
                try {
                    Write-Host "`rDownload complete!                          " -ForegroundColor Green
                } catch {
                    # Ignore console errors
                }
            }
            
            return
        }
        catch {
            if ($fileStream) { $fileStream.Close() }
            if ($response) { $response.Close() }
            if ($webClient) { $webClient.Dispose() }
            Write-Host ""
            Write-Host "[ERROR] Download attempt $attempt failed: $_" -ForegroundColor Red
            if ($attempt -eq $MaxRetries) { throw }
            $waitTime = [math]::Min(5 * $attempt, 30)
            Write-Host "Waiting $waitTime seconds before retry..." -ForegroundColor Yellow
            Start-Sleep -Seconds $waitTime
        }
    }
}

function Download-WithGit {
    param(
        [string]$RepoUrl,
        [string]$Branch,
        [string]$Destination,
        [int]$MaxRetries = 10
    )
    # Validate parameters
    if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
        Write-Host "[ERROR] RepoUrl parameter is empty" -ForegroundColor Red
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        Write-Host "[ERROR] Branch parameter is empty" -ForegroundColor Red
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Destination)) {
        Write-Host "[ERROR] Destination parameter is empty" -ForegroundColor Red
        return $false
    }
    Write-Host "Download-WithGit called (PS Mode: $($script:PS_MODE))" -ForegroundColor Gray
    Write-Host "  RepoUrl: $RepoUrl" -ForegroundColor Gray
    Write-Host "  Branch: $Branch" -ForegroundColor Gray
    Write-Host "  Destination: $Destination" -ForegroundColor Gray
    
    # Check for Git availability
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCommand) {
        Write-Host "Git command not found in PATH" -ForegroundColor Yellow
        Write-Host "Git not found – falling back to archive download" -ForegroundColor Yellow
        return $false
    }
    Write-Host "Git found at: $($gitCommand.Source)" -ForegroundColor Gray
    
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "`nGit clone retry attempt $attempt of $MaxRetries" -ForegroundColor Yellow
        }
        try {
            # Clean up any existing destination
            if (Test-Path $Destination) {
                Write-Host "Removing existing destination: $Destination" -ForegroundColor Gray
                Remove-Item $Destination -Recurse -Force -ErrorAction Stop
            }
            
            Write-Host "`nCloning repository with built-in git progress..." -ForegroundColor Cyan
            Write-Host "Executing: git clone --depth=1 --branch $Branch $RepoUrl $Destination" -ForegroundColor Gray
            
            # Let git handle its own progress reporting no custom parsing needed
            & $script:gitPath clone --depth=1 --branch $Branch $RepoUrl $Destination
            
            $gitExitCode = $LASTEXITCODE
            
            # Check if git succeeded
            if ($gitExitCode -eq 0) {
                # Verify destination exists and has content
                if (Test-Path $Destination) {
                    $items = Get-ChildItem -Path $Destination -ErrorAction SilentlyContinue
                    if ($items.Count -gt 0) {
                        Write-Host "`n[OK] Git clone successful - $($items.Count) items downloaded" -ForegroundColor Green
                        return $true
                    } else {
                        throw "Git clone succeeded but destination folder is empty"
                    }
                } else {
                    throw "Git clone succeeded but destination folder was not created"
                }
            }
            throw "Git failed with exit code $gitExitCode"
        }
        catch {
            Write-Host "[ERROR] Git attempt $attempt failed: $_" -ForegroundColor Red
            if ($attempt -eq $MaxRetries) { 
                Write-Host "Max git retries reached" -ForegroundColor Red
                return $false 
            }
            $waitTime = [math]::Min(5 * $attempt, 30)
            Write-Host "Waiting $waitTime seconds before retry..." -ForegroundColor Yellow
            Start-Sleep -Seconds $waitTime
        }
    }
    return $false
}

function Robust-Download {
    try {
        Write-Host "`nCreating data directory: $dataDir" -ForegroundColor Gray
        New-Item -ItemType Directory -Path $dataDir -ErrorAction SilentlyContinue | Out-Null
        Write-Host "Data directory ready" -ForegroundColor Gray

        # Determine if this is a git-cloneable source
        $isGitSource = $srcUrl -like '*.git'
        $gitAttempted = $false
        $gitSucceeded = $false

        # Try Git first for ALL sources (if Git is available)
        $gitCommand = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCommand) {
            $script:gitPath = $gitCommand.Source
            
            # Determine branch and repo URL
            $repoUrl = $srcUrl
            $branch = 'master'
            
            if (-not $isGitSource) {
                # Convert ZIP URL to Git URL
                $repoUrl = "https://github.com/FirestormViewer/phoenix-firestorm.git"
                
                # Extract branch/tag from ZIP URL
                if ($srcUrl -match '/tags/([^/]+)\.zip$') {
                    $branch = $matches[1]
                } elseif ($srcUrl -match '/heads/([^/]+)\.zip$') {
                    $branch = $matches[1]
                }
            }
            
            Write-Host "`nAttempting Git clone first..." -ForegroundColor Cyan
            Write-Host "Repository: $repoUrl" -ForegroundColor Gray
            Write-Host "Branch/Tag: $branch" -ForegroundColor Gray
            
            $gitAttempted = $true
            if (Download-WithGit -RepoUrl $repoUrl -Branch $branch -Destination $srcDir) {
                Write-Host "Git clone successful!`n" -ForegroundColor Green
                $gitSucceeded = $true
                
                # Verify the clone
                $indraPath = Join-Path $srcDir "indra"
                if (Test-Path $indraPath) {
                    Write-Host "Verified: indra directory found at $indraPath" -ForegroundColor Green
                    return  # Success - exit function
                } else {
                    Write-Host "[WARNING] indra directory not found - clone may be incomplete" -ForegroundColor Yellow
                    $gitSucceeded = $false
                }
            } else {
                Write-Host "Git clone failed - falling back to ZIP download" -ForegroundColor Yellow
            }
        } else {
            Write-Host "`nGit not found - using ZIP download method" -ForegroundColor Yellow
        }

        # Fallback to ZIP download if Git failed or wasn't available
        if (-not $gitSucceeded) {
            # Ensure we have a ZIP URL
            if ($isGitSource) {
                # Convert .git URL to master ZIP
                $srcUrl = "https://github.com/FirestormViewer/phoenix-firestorm/archive/refs/heads/master.zip"
                Write-Host "Converting Git URL to ZIP: $srcUrl" -ForegroundColor Gray
            }
            
            Write-Host "`nSource type: ZIP archive" -ForegroundColor Gray
            $zip = "$dataDir\fs.zip"
            Write-Host "Target file: $zip" -ForegroundColor Gray
            Write-Host "`nDownloading $tag from GitHub..." -ForegroundColor Cyan
            Write-Host "Source: $srcUrl`n" -ForegroundColor Gray
            Write-Host "Starting download with retry support (max 10 attempts)..." -ForegroundColor Gray
            Download-WithInvokeWebRequest -Url $srcUrl -Destination $zip -MaxRetries 10
            Write-Host "Download complete!`n" -ForegroundColor Green
        }
    }
    catch {
        throw "Download error: $_"
    }
}

function Expand-Zip($zip) {
    Write-Host "Extracting archive..." -ForegroundColor Cyan
    Write-Host "Source: $zip" -ForegroundColor Gray
    Write-Host "Target: $dataDir" -ForegroundColor Gray
    
    # Verify ZIP file exists and is valid
    if (-not (Test-Path $zip)) {
        throw "ZIP file not found: $zip"
    }
    $zipInfo = Get-Item $zip
    Write-Host "ZIP file size: $([math]::Round($zipInfo.Length / 1MB, 2)) MB" -ForegroundColor Gray
    if ($zipInfo.Length -lt 1MB) {
        throw "ZIP file is too small ($($zipInfo.Length) bytes) - download may be corrupt"
    }
    
    # Method 1 Try .NET System.IO.Compression
    $extractSuccess = $false
    try {
        Write-Host "Attempting extraction using .NET System.IO.Compression..." -ForegroundColor Gray
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dataDir)
        $extractSuccess = $true
        Write-Host "Extraction successful using .NET method" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] .NET extraction failed: $_" -ForegroundColor Yellow
        Write-Host "Trying alternative method..." -ForegroundColor Gray
    }
    
    # Method 2 Try Expand-Archive PowerShell native
    if (-not $extractSuccess) {
        try {
            Write-Host "Attempting extraction using Expand-Archive..." -ForegroundColor Gray
            Expand-Archive -Path $zip -DestinationPath $dataDir -Force
            $extractSuccess = $true
            Write-Host "Extraction successful using Expand-Archive" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] Expand-Archive failed: $_" -ForegroundColor Yellow
            Write-Host "Trying final fallback method..." -ForegroundColor Gray
        }
    }
    
    # Method 3 Try Shell.Application COM object - slowest but most compatible
    if (-not $extractSuccess) {
        try {
            Write-Host "Attempting extraction using Shell.Application..." -ForegroundColor Gray
            $shell = New-Object -ComObject Shell.Application
            $zipFile = $shell.NameSpace($zip)
            $destination = $shell.NameSpace($dataDir)
            
            # Copy with progress (4) and no UI 16
            $destination.CopyHere($zipFile.Items(), 4 + 16)
            
            # Wait for extraction to complete COM is async
            Start-Sleep -Seconds 5
            $extractSuccess = $true
            Write-Host "Extraction successful using Shell.Application" -ForegroundColor Green
        } catch {
            Write-Host "[ERROR] Shell.Application extraction failed: $_" -ForegroundColor Red
        }
    }
    
    if (-not $extractSuccess) {
        throw "All extraction methods failed. Please extract the ZIP manually to: $dataDir"
    }
    
    Write-Host "Extraction complete!" -ForegroundColor Green
    Write-Host ""
    
    # Auto-detect the extracted folder
    Write-Host "Scanning for extracted phoenix-firestorm folder..." -ForegroundColor Gray
    Start-Sleep -Seconds 2  # Give filesystem time to update
    
    $phoenixFolders = Get-ChildItem -Path $dataDir -Directory -ErrorAction SilentlyContinue | 
                      Where-Object { $_.Name -like "phoenix-firestorm*" }
    
    if ($phoenixFolders.Count -eq 0) {
        Write-Host "[ERROR] No phoenix-firestorm folder found after extraction!" -ForegroundColor Red
        Write-Host "Contents of data directory:" -ForegroundColor Yellow
        Get-ChildItem -Path $dataDir | ForEach-Object { 
            Write-Host "  - $($_.Name) $(if ($_.PSIsContainer) {'[DIR]'} else {"[$([math]::Round($_.Length/1MB, 2)) MB]"})" -ForegroundColor Gray 
        }
        throw "Extraction appeared to succeed but no source folder was created"
    }
    
    # Find folder with indra subdirectory
    $validFolder = $null
    foreach ($folder in $phoenixFolders) {
        $indraPath = Join-Path $folder.FullName "indra"
        if (Test-Path $indraPath) {
            $validFolder = $folder
            Write-Host "Found valid source folder: $($folder.Name)" -ForegroundColor Green
            Write-Host "  Contains indra subdirectory: $indraPath" -ForegroundColor Gray
            break
        }
    }
    
    if ($null -eq $validFolder) {
        Write-Host "[WARNING] Found phoenix-firestorm folders but none contain 'indra' subdirectory" -ForegroundColor Yellow
        Write-Host "Available folders:" -ForegroundColor Yellow
        foreach ($folder in $phoenixFolders) {
            Write-Host "  - $($folder.Name)" -ForegroundColor Gray
            Write-Host "    Contents:" -ForegroundColor Gray
            Get-ChildItem -Path $folder.FullName | Select-Object -First 10 | ForEach-Object {
                Write-Host "      - $($_.Name)" -ForegroundColor DarkGray
            }
        }
        $validFolder = $phoenixFolders[0]
        Write-Host "Using first folder: $($validFolder.Name)" -ForegroundColor Yellow
    }
    
    # Update script source directory
    $script:srcDir = $validFolder.FullName
    Write-Host "Source directory set to: $script:srcDir" -ForegroundColor Cyan
    Write-Host ""
}

function Test-Prerequisites {
    Header "CHECKING BUILD PREREQUISITES"
    $issues = @()
    
    # Determine required Visual Studio version based on Firestorm version
    $firestormVersion = $script:tag
    $requiredVS = "2019"  # Default to VS2019
    $vsVersionRange = "[16.0,17.0)"
    if ($firestormVersion -match "7\." -or $firestormVersion -match "master") {
        $requiredVS = "2022"
        $vsVersionRange = "[17.0,18.0)"
        Write-Host "Building Firestorm 7.x+ - requires Visual Studio 2022" -F Gray
    } else {
        Write-Host "Building Firestorm 6.x - requires Visual Studio 2019" -F Gray
    }
    
    # CMake detection
    $cmake = Get-Command cmake -EA SilentlyContinue
    if ($cmake) { 
        Write-Host "Detected: CMake $($cmake.Version)" -F Green 
        $script:cmakePath = $cmake.Source
    } else { 
        Write-Host "[FAIL] CMake missing" -F Red
        $issues += "Install CMake from https://cmake.org/download/"
    }
    
    # Visual Studio detection
    $vsWherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWherePath) {
        try {
            # Correct vswhere syntax with proper parameter handling
            $vsArgs = @(
                "-version", $vsVersionRange,
                "-products", "*",
                "-requires", "Microsoft.Component.MSBuild",
                "-property", "installationPath",
                "-format", "value"
            )
            
            $vsPath = & $vsWherePath @vsArgs 2>&1
            
            # Clean up any warning/error output
            if ($vsPath -is [System.Array]) {
                $vsPath = ($vsPath | Where-Object { $_ -notmatch "warning|error|copyright" } | Select-Object -First 1).Trim()
            } else {
                $vsPath = $vsPath.ToString().Trim()
            }
            
            if ($vsPath -and $vsPath.Length -gt 0 -and (Test-Path $vsPath)) {
                $msbuild = Join-Path $vsPath "MSBuild\Current\Bin\MSBuild.exe"
                if (Test-Path $msbuild) { 
                    Write-Host "Detected: Visual Studio $requiredVS (for Firestorm $($firestormVersion.Split(' ')[0]))" -F Green
                    $env:PATH = "$(Split-Path $msbuild);$env:PATH"
                    $script:requiredVSVersion = $requiredVS
                    $script:msbuildPath = $msbuild
                } else { 
                    Write-Host "[FAIL] MSBuild missing for Visual Studio $requiredVS" -F Red
                    $issues += "Repair Visual Studio $requiredVS installation"
                }
            } else {
                Write-Host "[FAIL] Visual Studio $requiredVS not found" -F Red
                $issues += "Install Visual Studio $requiredVS with C++ and MSBuild components"
            }
        } catch {
            Write-Host "[FAIL] Visual Studio detection error: $_" -F Red
            $issues += "Visual Studio $requiredVS detection failed"
        }
    } else { 
        Write-Host "[FAIL] vswhere missing - cannot detect Visual Studio installations" -F Red
        $issues += "Install Visual Studio $requiredVS or repair existing installation"
    }
    
    # Autobuild detection
    $ab = Get-Command autobuild -EA SilentlyContinue
    if ($ab) { 
        Write-Host "Detected: autobuild $($ab.Version)" -F Green
        $script:autobuildAvailable = $true 
        $script:autobuildPath = $ab.Source
    } else {
        Write-Host "[MISSING] autobuild" -F Yellow
        $pip = Get-Command pip, pip3 -EA SilentlyContinue | Select -First 1
        if ($pip) {
            $in = Read-Host "Install autobuild via pip? (Y/N)"
            if ($in -match '^y') {
                & $pip.Source install autobuild --user
                if ($LASTEXITCODE -eq 0) { 
                    $ab = Get-Command autobuild -EA SilentlyContinue
                    if ($ab) {
                        Write-Host "Detected: autobuild $($ab.Version)" -F Green
                        $script:autobuildAvailable = $true
                        $script:autobuildPath = $ab.Source
                    } else {
                        Write-Host "[FAIL] autobuild installed but not found in PATH" -F Red
                        $issues += "autobuild not found after installation - restart terminal"
                    }
                } else { 
                    Write-Host "[FAIL] install failed" -F Red
                    $issues += "pip install autobuild failed"
                }
            } else { 
                $issues += "autobuild required; run: pip install autobuild" 
            }
        } else { 
            $issues += "Install Python/pip, then: pip install autobuild" 
        }
    }
    
    # Python detection (required for autobuild)
    $python = Get-Command python, python3 -EA SilentlyContinue | Select-Object -First 1
    if ($python) {
        $pyVersion = & $python.Source --version 2>&1
        Write-Host "Detected: $pyVersion" -F Green
    } else {
        Write-Host "[FAIL] Python not found" -F Red
        $issues += "Install Python 3 from https://www.python.org/downloads/"
    }
    
    # Optional: Check for Cygwin (mentioned in official docs for testing)
    $cygwinBash = Get-Command bash -EA SilentlyContinue | Where-Object { $_.Source -like "*cygwin*" }
    if ($cygwinBash) {
        Write-Host "[INFO] Cygwin detected (optional for testing)" -F Cyan
    } elseif (Test-Path "C:\Cygwin64\bin") {
        Write-Host "[INFO] Cygwin installed but not in PATH (optional for testing)" -F DarkGray
    }
    
    if ($issues) {
        Write-Host "`nPrerequisites check failed:" -F Red
        $issues | ForEach-Object { Write-Host "  - $_" -F Red }
        throw "Cannot continue until prerequisites are met"
    }
    
    Write-Host "`nAll prerequisites satisfied!" -F Green
}

function Configure-CMake {
    try {
        $cmakeSourceDir = Join-Path $script:srcDir "indra"
        if ($cmakeSourceDir.Length -gt 200) {
            Write-Host "[WARN] Path $($cmakeSourceDir.Length) chars - may break builds" -F Yellow
            $short = "C:\temp_compile"
            New-Item $short -ItemType Directory -Force | Out-Null
            $shortSrc = Join-Path $short "fs-src"
            if (Test-Path $shortSrc) { Remove-Item $shortSrc -Recurse -Force }
            Copy-Item $script:srcDir $shortSrc -Recurse -Force
            $script:srcDir = $shortSrc
            $cmakeSourceDir = Join-Path $shortSrc "indra"
            $script:buildDir = Join-Path $short "build"
        }
        $cl = Join-Path $cmakeSourceDir "CMakeLists.txt"
        if (-not (Test-Path $cl)) { throw "CMakeLists.txt missing at $cl" }
        
		# Patch Variables.cmake for CMake compatibility
		$vars = Join-Path $cmakeSourceDir "cmake\Variables.cmake"
		if (Test-Path $vars) {
			Write-Host "Patching Variables.cmake..." -F Cyan
			
			# Backup original
			Copy-Item $vars "$vars.backup" -Force
			
			# Read the file
			$content = Get-Content $vars -Raw
			$originalContent = $content
			
			# Step 1: Replace all RE_MATCH with MATCHES
			$content = $content -replace '\bRE_MATCH\b', 'MATCHES'
			
			# Step 2: Fix the specific problematic pattern at line 79
			# The issue is: if(MATCHES AND ${CMAKE_MATCH_1} STREQUAL "64")
			# This needs to be split into two separate if statements with proper endif
			
			# Pattern: Find the problematic if statement and the associated else/endif
			# We need to add an extra endif() before the else() to close the inner if
			
			$lines = $content -split "`r?`n"
			$newLines = [System.Collections.ArrayList]::new()
			$inProblematicBlock = $false
			$addedEndif = $false
			
			for ($i = 0; $i -lt $lines.Count; $i++) {
				$line = $lines[$i]
				
				# Detect the problematic if statement
				if ($line -match 'if\s*\(\s*MATCHES\s+AND\s+.*CMAKE_MATCH_1.*STREQUAL\s+"64"') {
					# Split into two if statements
					$indent = if ($line -match '^(\s*)') { $matches[1] } else { '' }
					[void]$newLines.Add("${indent}if(MATCHES)")
					[void]$newLines.Add("${indent}    if(CMAKE_MATCH_1 STREQUAL `"64`")")
					$inProblematicBlock = $true
					$addedEndif = $false
				}
				# If we're in the problematic block and hit an else(), add endif() first
				elseif ($inProblematicBlock -and $line -match '^\s*else\s*\(\s*\)\s*$' -and -not $addedEndif) {
					$indent = if ($line -match '^(\s*)') { $matches[1] } else { '' }
					[void]$newLines.Add("${indent}    endif()")  # Close the inner if(CMAKE_MATCH_1...)
					[void]$newLines.Add($line)  # Add the else()
					$addedEndif = $true
				}
				# If we're in the problematic block and hit the final endif(), add one more
				elseif ($inProblematicBlock -and $line -match '^\s*endif\s*\(\s*\)\s*$' -and $addedEndif) {
					[void]$newLines.Add($line)  # This closes the else()
					$indent = if ($line -match '^(\s*)') { $matches[1] } else { '' }
					[void]$newLines.Add("${indent}endif()")  # Close the outer if(MATCHES)
					$inProblematicBlock = $false
				}
				else {
					[void]$newLines.Add($line)
				}
			}
			
			$content = $newLines -join [System.Environment]::NewLine
			
			# Verify we didn't break anything
			$ifCount = ([regex]::Matches($content, '\bif\s*\(')).Count
			$elseCount = ([regex]::Matches($content, '\belse\s*\(')).Count
			$endifCount = ([regex]::Matches($content, '\bendif\s*\(')).Count
			
			Write-Host "  if() count: $ifCount, else() count: $elseCount, endif() count: $endifCount" -F Gray
			
			if ($ifCount -ne $endifCount) {
				Write-Host "  [WARN] if/endif mismatch after patching ($ifCount if vs $endifCount endif)" -F Yellow
			}
			
			if ($content -ne $originalContent) {
				# Write with proper encoding
				$utf8NoBom = New-Object System.Text.UTF8Encoding $false
				[System.IO.File]::WriteAllText($vars, $content, $utf8NoBom)
				Write-Host "  Patches applied successfully (backup saved as Variables.cmake.backup)" -F Green
			} else {
				Write-Host "  No patches needed (file already correct)" -F Gray
			}
		} else {
			Write-Host "  [WARN] Variables.cmake not found at $vars" -F Yellow
		}
        
        # Setup autobuild environment variables
        $env:AUTOBUILD_ADDRSIZE = "64"
        $env:AUTOBUILD_CONFIGURATION = "Release"
        $env:AUTOBUILD_PLATFORM = "windows64"
        
        # Set AUTOBUILD_VSVER based on Firestorm version
        $firestormVersion = $script:tag
        if ($firestormVersion -match "7\." -or $firestormVersion -match "master") {
            $env:AUTOBUILD_VSVER = "170"  # VS2022
            Write-Host "[INFO] Configuring for Visual Studio 2022 (vc170)" -F Cyan
        } else {
            $env:AUTOBUILD_VSVER = "160"  # VS2019
            Write-Host "[INFO] Configuring for Visual Studio 2019 (vc160)" -F Cyan
        }
        
        $env:AUTOBUILD_VCS_INFO = "false"
        
        # Cache directories
        $env:AUTOBUILD_CACHE_DIR = Join-Path $dataDir "autobuild_cache"
        $env:AUTOBUILD_INSTALLABLE_CACHE = Join-Path $dataDir "installable_cache"
        New-Item $env:AUTOBUILD_CACHE_DIR,$env:AUTOBUILD_INSTALLABLE_CACHE -ItemType Directory -Force | Out-Null
        
        # Critical: Point to autobuild.xml in source directory
        $autobuildXml = Join-Path $script:srcDir "autobuild.xml"
        if (Test-Path $autobuildXml) {
            $env:AUTOBUILD_CONFIG_FILE = $autobuildXml
            Write-Host "Autobuild config: $autobuildXml" -F Gray
        } else {
            Write-Host "[WARN] autobuild.xml not found - dependencies may fail" -F Yellow
        }
        
        Write-Host "Cache folders ready" -F Gray
        Write-Host "  AUTOBUILD_INSTALLABLE_CACHE: $env:AUTOBUILD_INSTALLABLE_CACHE" -F DarkGray
        $env:LL_BUILD = $buildDir
        
        # Set MSVC path based on required VS version
        if ($script:requiredVSVersion -eq "2022") {
            $msvcPath = "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC"
        } else {
            $msvcPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community\VC\Tools\MSVC"
        }
        
        if (Test-Path $msvcPath) {
            $latestMSVC = Get-ChildItem $msvcPath | Sort-Object Name -Descending | Select-Object -First 1
            if ($latestMSVC) {
                $binPath = Join-Path $latestMSVC.FullName "bin\Hostx64\x64"
                $env:PATH = "$binPath;$env:PATH"
                Write-Host "MSVC path set to: $binPath" -F Gray
            }
        }
        
        if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
        New-Item $buildDir -ItemType Directory | Out-Null
        
        # Configure CMake (single attempt only - retries are not helpful for config errors)
        Write-Host "Hardware optimization flags detected:" -F Cyan
        Write-Host "  Compiler flags: $($script:HardwareProfile.OptimizationFlags)" -F Yellow
        Write-Host "  CMake flags: $($script:HardwareProfile.CMakeFlags -join ' ')" -F Yellow
        
        Write-Host "Configuring CMake with $($script:HardwareProfile.OptimizationFlags)" -F Cyan
        
        # Determine CMake generator based on VS version
        $cmakeGenerator = if ($script:requiredVSVersion -eq "2022") { "Visual Studio 17 2022" } else { "Visual Studio 16 2019" }
        
        Write-Host "Generator: $cmakeGenerator" -F Cyan
        Write-Host "Single configuration attempt" -F Yellow
        
        
        # Use autobuild configure as per official instructions
        Write-Host "Running autobuild configure..." -F Cyan
        
        # Verify we're in the source directory with autobuild.xml
        $autobuildXmlCheck = Join-Path $script:srcDir "autobuild.xml"
        if (-not (Test-Path $autobuildXmlCheck)) {
            throw "autobuild.xml not found at $autobuildXmlCheck - cannot configure"
        }
        
		Push-Location $script:srcDir
		try {
			# Determine the correct build configuration based on hardware capabilities
			# Firestorm has pre-defined configurations: ReleaseFS_open, ReleaseFS_AVX, ReleaseFS_AVX2
			$buildConfig = "ReleaseFS_open"  # Default (no proprietary libs)
			
			# Check if AVX2 configuration exists in autobuild.xml
			$autobuildXmlContent = Get-Content "$script:srcDir\autobuild.xml" -Raw
			
			if ($script:HardwareProfile.CMakeFlags -contains "-DUSE_AVX2=ON") {
				# Check if ReleaseFS_AVX2 configuration exists
				if ($autobuildXmlContent -match 'ReleaseFS_AVX2') {
					$buildConfig = "ReleaseFS_AVX2"
					Write-Host "  [OPTIMIZATION] Using ReleaseFS_AVX2 build configuration" -F Green
				} else {
					Write-Host "  [INFO] ReleaseFS_AVX2 config not found, using ReleaseFS_open with custom flags" -F Yellow
				}
			} elseif ($script:HardwareProfile.CMakeFlags -contains "-DUSE_AVX=ON") {
				# Check if ReleaseFS_AVX configuration exists
				if ($autobuildXmlContent -match 'ReleaseFS_AVX') {
					$buildConfig = "ReleaseFS_AVX"
					Write-Host "  [OPTIMIZATION] Using ReleaseFS_AVX build configuration" -F Green
				} else {
					Write-Host "  [INFO] ReleaseFS_AVX config not found, using ReleaseFS_open with custom flags" -F Yellow
				}
			}
			
			# Build autobuild arguments
			$autobuildArgs = @(
				"configure",
				"-A", "64",
				"-c", $buildConfig
			)
			
			# Add custom CMake flags after the '--' separator
			$autobuildArgs += "--"
			$autobuildArgs += "-DLL_TESTS:BOOL=FALSE"
			
			# If using ReleaseFS_open (base config), pass our hardware optimization flags directly to CMake
			if ($buildConfig -eq "ReleaseFS_open") {
				Write-Host "  [OPTIMIZATION] Passing custom hardware flags to CMake" -F Cyan
				$autobuildArgs += "-DCMAKE_CXX_FLAGS=$($script:HardwareProfile.OptimizationFlags)"
				$autobuildArgs += "-DCMAKE_C_FLAGS=$($script:HardwareProfile.OptimizationFlags)"
				
				# Add our custom CMake optimization flags
				foreach ($flag in $script:HardwareProfile.CMakeFlags) {
					if ($flag -ne "-DCMAKE_BUILD_TYPE=Release") {  # Skip duplicate
						$autobuildArgs += $flag
					}
				}
			}
			
			Write-Host "  Working directory: $script:srcDir" -F DarkGray
			Write-Host "  Build configuration: $buildConfig" -F DarkGray
			Write-Host "  Command: autobuild $($autobuildArgs -join ' ')" -F DarkGray
			& autobuild @autobuildArgs
			$cmakeExitCode = $LASTEXITCODE
			
		} finally {
			Pop-Location
		}

		# Autobuild creates build directory with specific naming convention
		# Update build directory to match autobuild's structure
		$autobuildBuildDir = Join-Path $script:srcDir "build-vc$($env:AUTOBUILD_VSVER)-64"
		if (Test-Path $autobuildBuildDir) {
			$script:buildDir = $autobuildBuildDir
			Write-Host "  Autobuild created build directory: $script:buildDir" -F Gray
		} else {
			Write-Host "  [WARN] Expected autobuild build directory not found at $autobuildBuildDir" -F Yellow
			# Fallback: search for any build-vc* directory
			$buildDirs = Get-ChildItem -Path $script:srcDir -Directory -Filter "build-vc*" -ErrorAction SilentlyContinue
			if ($buildDirs) {
				$script:buildDir = $buildDirs[0].FullName
				Write-Host "  Using discovered build directory: $script:buildDir" -F Gray
			}
		}

		if ($cmakeExitCode -eq 0) {
			Write-Host "`nCMake configured successfully" -F Green
            
            # Verify FMA and AVX flags were properly set
            $cmakeCache = Join-Path $buildDir "CMakeCache.txt"
            if (Test-Path $cmakeCache) {
                $cacheContent = Get-Content $cmakeCache
                $fmaEnabled = $cacheContent -match "USE_FMA:BOOL=ON"
                $avx2Enabled = $cacheContent -match "USE_AVX2:BOOL=ON"
                
                if ($fmaEnabled) { Write-Host "[OK] FMA support enabled" -F Green }
                else { Write-Host "[WARN] FMA support NOT enabled in CMakeCache" -F Yellow }
                
                if ($avx2Enabled) { Write-Host "[OK] AVX2 support enabled" -F Green }
                else { Write-Host "[WARN] AVX2 support NOT enabled in CMakeCache" -F Yellow }
            }
        } else {
            Write-Host "CMake configuration failed - exit code $cmakeExitCode" -F Red
            $cmakeErrorLog = Join-Path $buildDir "CMakeFiles\CMakeError.log"
            if (Test-Path $cmakeErrorLog) {
                Write-Host "`nCMake Error Log (last 20 lines):" -F Yellow
                Get-Content $cmakeErrorLog -Tail 20 | ForEach-Object {
                    if ($_ -match 'error|fail|cannot') {
                        Write-Host "  $_" -F Red
                    } else {
                        Write-Host "  $_" -F DarkGray
                    }
                }
            }
            
            Write-Host "`n$bar" -F Red
            Write-Host "CMAKE CONFIGURATION FAILED" -F Red
            Write-Host $bar -F Red
            throw "CMake configuration failed with exit code: $cmakeExitCode"
        }
    } catch { 
        Write-Host "`n$bar" -F Red
        Write-Host "CMAKE CONFIGURATION ERROR" -F Red
        Write-Host $bar -F Red
        throw "CMake error: $_"
    }
}

function Build-Viewer {
    try {
        $threads = Get-BuildThreadCount
        Write-Host "Building Release|x64 (using $threads parallel threads)..." -ForegroundColor Cyan
        Write-Host "This may take 30-60 minutes.`n" -ForegroundColor Yellow
        
        Push-Location $script:srcDir
        try {
            # Use autobuild build as per official instructions
            & autobuild build -A 64 -c ReleaseFS_open --no-configure
            
            if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }
            Write-Host "`nBuild completed!`n" -ForegroundColor Green
        } finally {
            Pop-Location
        }
    } catch {
        throw "Build error: $_"
    }
}

function Deploy-To-ScriptFolder {
    try {
        # Autobuild places binaries in a different location than manual CMake builds
        # Try multiple possible locations
        $possiblePaths = @(
            "$($script:buildDir)\newview\Release",  # Autobuild typical location
            "$($script:buildDir)\bin\Release",       # Manual CMake location
            "$($script:buildDir)\Release"            # Alternative location
        )
        
        $builtBin = $null
        foreach ($path in $possiblePaths) {
            if (Test-Path $path) {
                $builtBin = $path
                Write-Host "Found built binaries at: $builtBin" -F Green
                break
            }
        }
        
        if (-not $builtBin) { 
            Write-Host "Searched locations:" -F Yellow
            foreach ($path in $possiblePaths) {
                Write-Host "  - $path $(if (Test-Path $path) {'[EXISTS]'} else {'[NOT FOUND]'})" -F Gray
            }
            throw "Built binaries not found in any expected location" 
        }
        
        Write-Host "Deploying viewer from $builtBin..." -ForegroundColor Cyan
        Copy-Item "$builtBin\*" $finalDir -Recurse -Force
        Write-Host "Deployment complete!`n" -ForegroundColor Green
        $script:BuildOK = $true
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

# MAIN EXECUTION
try {
    $host.UI.RawUI.WindowTitle = "Firestorm Viewer Builder"
    Initialize-BuildEnvironment
    Show-CombinedMenu
    Write-Host ""
    
    # Hardware detection and optimization analysis
    Detect-Hardware
    Write-Host ""
    Write-Host "Press any key to continue with build..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host ""
    
    Test-Prerequisites
    Robust-Download
    
    # Only extract ZIP if not a git clone
	$zipPath = "$dataDir\fs.zip"
	if (Test-Path $zipPath) {
		Expand-Zip $zipPath
	} else {
		Write-Host "Source obtained via Git - skipping ZIP extraction`n" -ForegroundColor Cyan
	}
    
    Configure-CMake
    Build-Viewer
    Deploy-To-ScriptFolder
    if ($script:BuildOK) { Summary }
}
catch {
    Write-Host "`n$bar" -ForegroundColor Red
    Write-Host "ERROR: $_" -ForegroundColor Red
    Write-Host $bar -ForegroundColor Red
    Write-Host "`nStack Trace:" -ForegroundColor DarkGray
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
    exit 1
}

exit 0