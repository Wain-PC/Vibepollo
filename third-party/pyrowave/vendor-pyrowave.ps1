<#
.SYNOPSIS
Refreshes the vendored PyroWave codec (upstream Themaister/pyrowave plus the
pruned Granite subset its C API needs) and reapplies the local patches.

.DESCRIPTION
PyroWave has no bitstream version field, so the host (vibeshine) and the client
(moonlight-qt) must be built from the same commits. Keep PYROWAVE_COMMIT and
GRANITE_COMMIT identical in both repositories and record them in VENDOR.txt.
patches/ and VENDOR.txt in moonlight-qt/pyrowave and
vibeshine/third-party/pyrowave must stay identical.

patches-metal/ is host only: it is applied after patches/ to upstream's Metal
port (metal/), which the macOS host encodes with. It must not change the
bitstream, since clients decode with the Vulkan code above.

The result replaces <Destination> completely. Run from any directory:

    powershell -File third-party\pyrowave\vendor-pyrowave.ps1

CMakeLists.txt next to this script (vibeshine's build wrapper) is not touched.
#>
param(
    [string]$Destination = (Join-Path $PSScriptRoot "pyrowave"),
    [string]$PatchDir = (Join-Path $PSScriptRoot "patches"),
    [string]$MetalPatchDir = (Join-Path $PSScriptRoot "patches-metal"),
    [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) "pyrowave-vendor"),
    [string]$PyroWaveCommit = "186f0393b77f7755953b5ecde994bb1cec2e4155",
    [string]$GraniteCommit = "b6cffd5ce81f540f0855e6778428483e14763d9b"
)

$ErrorActionPreference = "Stop"

function Invoke-Git {
    & git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

function Get-Checkout([string]$Url, [string]$Commit, [string]$Path) {
    if (-not (Test-Path (Join-Path $Path ".git"))) {
        Invoke-Git clone --filter=blob:none $Url $Path
    }
    Invoke-Git -C $Path fetch origin $Commit
    Invoke-Git -C $Path checkout --detach $Commit
}

New-Item -ItemType Directory -Force $WorkDir | Out-Null
$pyroSrc = Join-Path $WorkDir "pyrowave"
$graniteSrc = Join-Path $WorkDir "Granite"

Get-Checkout "https://github.com/Themaister/pyrowave" $PyroWaveCommit $pyroSrc
Get-Checkout "https://github.com/Themaister/Granite" $GraniteCommit $graniteSrc
foreach ($module in @("third_party/volk", "third_party/khronos/vulkan-headers")) {
    Invoke-Git -C $graniteSrc submodule sync $module
    Invoke-Git -C $graniteSrc submodule update --init --depth 1 $module
}

# Assemble outside any git work tree: git apply resolves paths from the top of
# an enclosing repository, which would misplace the patches.
$FinalDestination = $Destination
$Destination = Join-Path $WorkDir "stage"
if (Test-Path $Destination) {
    Remove-Item -Recurse -Force $Destination
}
New-Item -ItemType Directory -Force $Destination | Out-Null

# PyroWave: the library, its C API, the checked-in SPIR-V, the bitstream spec and
# the upstream C API / interop tests. Development tools, evaluation data and
# sample assets are dropped.
$pyroKeep = @(
    "CMakeLists.txt", "LICENSE", "README.md", "checkout_granite.sh", "slangmosh.sh",
    "link.T", "pyrowave-shared.def", "pyrowave.h", "pyrowave_c.cpp",
    "pyrowave_common.cpp", "pyrowave_common.hpp", "pyrowave_config.hpp",
    "pyrowave_decoder.cpp", "pyrowave_decoder.hpp",
    "pyrowave_encoder.cpp", "pyrowave_encoder.hpp",
    "pyrowave_c_test.cpp", "pyrowave_c_interop_test.cpp", "pyrowave_device_validation.cpp",
    "encode_desktop.cpp", "com_ptr.hpp", "yuv4mpeg.cpp", "yuv4mpeg.hpp"
)
foreach ($item in $pyroKeep) {
    Copy-Item (Join-Path $pyroSrc $item) (Join-Path $Destination $item)
}
foreach ($dir in @("bitstream", "shaders", "pkg-config")) {
    Copy-Item -Recurse (Join-Path $pyroSrc $dir) (Join-Path $Destination $dir)
}
# The Metal port (macOS host encoder), without its Xcode project.
Copy-Item -Recurse (Join-Path $pyroSrc "metal") (Join-Path $Destination "metal")
Remove-Item -Recurse -Force (Join-Path $Destination "metal/pyrowave.xcodeproj")
New-Item -ItemType Directory -Force (Join-Path $Destination "eval-results") | Out-Null
Copy-Item (Join-Path $pyroSrc "eval-results\pyrowave_regression_results.h") (Join-Path $Destination "eval-results")

# Granite: only what granite-vulkan, granite-util, granite-math and the video
# scaler (colour conversion for the scaled encode path) compile against.
$graniteDst = Join-Path $Destination "Granite"
New-Item -ItemType Directory -Force $graniteDst | Out-Null
Get-ChildItem -File $graniteSrc | ForEach-Object { Copy-Item $_.FullName $graniteDst }
$graniteKeep = @("application", "compiler", "ecs", "event", "filesystem", "math", "path",
                 "threading", "toolchains", "util", "vulkan", "video")
foreach ($dir in $graniteKeep) {
    Copy-Item -Recurse (Join-Path $graniteSrc $dir) (Join-Path $graniteDst $dir)
}
$thirdDst = Join-Path $graniteDst "third_party"
New-Item -ItemType Directory -Force $thirdDst | Out-Null
Get-ChildItem -File (Join-Path $graniteSrc "third_party") | ForEach-Object { Copy-Item $_.FullName $thirdDst }
foreach ($dir in @("dirent", "renderdoc", "stb", "volk")) {
    Copy-Item -Recurse (Join-Path $graniteSrc "third_party\$dir") (Join-Path $thirdDst $dir)
}
$headersSrc = Join-Path $graniteSrc "third_party\khronos\vulkan-headers"
$headersDst = Join-Path $thirdDst "khronos\vulkan-headers"
New-Item -ItemType Directory -Force $headersDst | Out-Null
Get-ChildItem -File $headersSrc | ForEach-Object { Copy-Item $_.FullName $headersDst }
Copy-Item -Recurse (Join-Path $headersSrc "include") (Join-Path $headersDst "include")
if (Test-Path (Join-Path $headersSrc "cmake")) {
    Copy-Item -Recurse (Join-Path $headersSrc "cmake") (Join-Path $headersDst "cmake")
}
# vulkan.hpp and its C++ module siblings are several MB and unused by the C code paths.
Get-ChildItem -Recurse (Join-Path $headersDst "include") -Include *.hpp, *.cppm | Remove-Item -Force

Get-ChildItem -Recurse -Force $Destination -Include .git, .github, .gitmodules | Remove-Item -Recurse -Force

# Local patches, applied in name order. Each one documents why it exists.
# The Metal patches come last: 0101 regenerates a shader from patch 0010's output.
foreach ($dir in @($PatchDir, $MetalPatchDir)) {
    if (Test-Path $dir) {
        foreach ($patch in (Get-ChildItem $dir -Filter *.patch | Sort-Object Name)) {
            Write-Host "Applying $($patch.Name)"
            Invoke-Git -C $Destination apply --whitespace=nowarn -p1 $patch.FullName
        }
    }
}

if (Test-Path $FinalDestination) {
    Remove-Item -Recurse -Force $FinalDestination
}
Move-Item $Destination $FinalDestination
$Destination = $FinalDestination

@"
PyroWave codec, vendored by vendor-pyrowave.ps1. Do not edit by hand; add a
patch under patches/ and rerun the script instead.

pyrowave:        $PyroWaveCommit (https://github.com/Themaister/pyrowave)
Granite:         $GraniteCommit (https://github.com/Themaister/Granite)
volk:            $(& git -C $graniteSrc rev-parse HEAD:third_party/volk)
vulkan-headers:  $(& git -C $graniteSrc rev-parse HEAD:third_party/khronos/vulkan-headers)

The PyroWave bitstream carries no version field. The host and the client must be
built from the same pyrowave commit; the RTSP handshake advertises it as
PYROWAVE_BITSTREAM_ID in pyrowave_protocol.h.

Local patch 0010-deterministic-record-padding.patch zeroes decoder-ignored
sign bits and word-alignment tails on the GPU so identical coefficients produce
identical records. It changes no decoded values or
Vulkan feature requirements. scripts/regenerate-pyrowave-block-packing.py
refreshes only the packing program, preserving all other programs/reflection.

metal/ is upstream's Metal port at the same commit, used by the macOS host
encoder, with patches-metal/ applied: 0101 mirrors patches 0002 and 0010, 0102 is
upstream 79a3232 (P010 input) and 0103 adds 16-bit single plane input. They change
buffer sizing, padding and input wrapping only, so Metal streams decode with the
Vulkan decoder at this commit.
"@ | Set-Content -Encoding utf8 (Join-Path (Split-Path $Destination) "VENDOR.txt")

Write-Host "PyroWave vendored into $Destination"
