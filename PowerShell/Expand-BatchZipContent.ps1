<#
.SYNOPSIS
    Batch extracts .zip files in a target directory with conflict resolution and artifact filtering.

.DESCRIPTION
    This script searches for .zip files in a specified path and extracts their contents.
    It leverages .NET compression classes to allow for granular entry filtering.
    - Recursively ignores '__MACOSX' folders and files.
    - Resolves file name conflicts by appending a counter (e.g., 'file (1).txt') instead of overwriting.
    - Supports -WhatIf for safety.

.PARAMETER Path
    The directory containing the .zip files. Defaults to the current working directory.

.PARAMETER DestinationPath
    The directory to extract files into. Defaults to the same directory as the source zips.

.EXAMPLE
    Expand-BatchZipContent -Path "C:\Downloads" -Verbose
    Extracts all zips in C:\Downloads to C:\Downloads, providing detailed logs.

.EXAMPLE
    Expand-BatchZipContent -WhatIf
    Simulates the extraction process for zips in the current folder.
#>
#requires -version 5.1

function Expand-BatchZipContent {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param (
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$Path = $PWD,

        [Parameter(Position = 1)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$DestinationPath = $Path
    )

    process {
        # Load required .NET assembly for older PS versions, built-in for newer
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        try {
            # Normalize paths
            $SourceDir = (Resolve-Path -Path $Path).Path
            $DestDir   = (Resolve-Path -Path $DestinationPath).Path

            Write-Verbose "Scanning for .zip files in: $SourceDir"

            # Get all zip files
            $ZipFiles = Get-ChildItem -Path $SourceDir -Filter *.zip -File

            if ($null -eq $ZipFiles) {
                Write-Warning "No .zip files found in $SourceDir."
                return
            }

            foreach ($Zip in $ZipFiles) {
                Write-Verbose "Processing Archive: $($Zip.Name)"
                
                try {
                    # Open the zip file in Read mode
                    $ZipHandle = [System.IO.Compression.ZipFile]::OpenRead($Zip.FullName)

                    foreach ($Entry in $ZipHandle.Entries) {
                        
                        # 1. Filter: Skip Directory entries and __MACOSX artifacts
                        # Zip entries ending in / are directories in the .NET model
                        if ($Entry.FullName -match "^__MACOSX" -or $Entry.FullName -match "/$") {
                            Write-Verbose "Skipping artifact/folder: $($Entry.FullName)"
                            continue
                        }

                        # 2. Construct Target Path
                        # We use [IO.Path]::Combine to ensure valid OS separators
                        # We specifically only use the Name, flattening the structure relative to the dest, 
                        # or preserving relative structure depending on preference. 
                        # Given the prompt implies simple extraction, we preserve the internal structure.
                        
                        $TargetFilePath = [System.IO.Path]::Combine($DestDir, $Entry.FullName)
                        $TargetFolder   = [System.IO.Path]::GetDirectoryName($TargetFilePath)

                        # Ensure the parent directory exists
                        if (-not (Test-Path -Path $TargetFolder)) {
                            Write-Verbose "Creating directory: $TargetFolder"
                            if ($PSCmdlet.ShouldProcess($TargetFolder, "Create Directory")) {
                                New-Item -Path $TargetFolder -ItemType Directory -Force | Out-Null
                            }
                        }

                        # 3. Conflict Resolution (Rename Logic)
                        if (Test-Path -Path $TargetFilePath) {
                            $BaseName  = [System.IO.Path]::GetFileNameWithoutExtension($TargetFilePath)
                            $Extension = [System.IO.Path]::GetExtension($TargetFilePath)
                            $Folder    = [System.IO.Path]::GetDirectoryName($TargetFilePath)
                            $Counter   = 1

                            # Loop until we find a filename that doesn't exist
                            do {
                                $NewName = "{0} ({1}){2}" -f $BaseName, $Counter, $Extension
                                $TargetFilePath = [System.IO.Path]::Combine($Folder, $NewName)
                                $Counter++
                            } while (Test-Path -Path $TargetFilePath)

                            Write-Verbose "Conflict detected. Renaming to: $NewName"
                        }

                        # 4. Extract
                        if ($PSCmdlet.ShouldProcess($TargetFilePath, "Extract from $($Zip.Name)")) {
                            # ExtractToFile(Path, Overwrite) - We set overwrite to false because we handled naming
                            $Entry.ExtractToFile($TargetFilePath, $false)
                        }
                    }
                }
                catch {
                    Write-Error "Failed to process zip file '$($Zip.Name)'. Error: $_"
                }
                finally {
                    # Always dispose the handle to unlock the file
                    if ($ZipHandle) { $ZipHandle.Dispose() }
                }
            }
        }
        catch {
            Write-Error "Critical Failure in script execution: $_"
        }
    }
}