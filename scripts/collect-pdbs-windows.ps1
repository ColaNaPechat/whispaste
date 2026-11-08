param(
  [Parameter(Mandatory=$false)][string]$DllDir,
  [Parameter(Mandatory=$false)][string]$OutDir
)

if ($OutDir -and -not (Test-Path $OutDir)) {
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

if ($DllDir -and $OutDir -and (Test-Path $DllDir)) {
  Get-ChildItem -Path $DllDir -Filter *.pdb -Recurse -ErrorAction SilentlyContinue |
    Copy-Item -Destination $OutDir -Force -ErrorAction SilentlyContinue
}

exit 0

