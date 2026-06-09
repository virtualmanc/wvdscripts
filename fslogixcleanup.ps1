##This script will delete FSLogix profiles from multiple file shares. By default it is in simulation mode. 

# Define the paths to the FSLogix profile folders
$profileFolderPaths = @(
    "C:\Path\To\FSLogix\Profiles1",  # Replace with your actual paths
    "C:\Path\To\FSLogix\Profiles2",
    "\\NetworkShare\FSLogix\Profiles3"
)

# Define the log file path
$logFilePath = "C:\Path\To\Log\DeletedFilesLog.txt"  # Replace with the desired log file path

# Define the age threshold in days
$ageThreshold = 180

# Set this to $true to actually delete the files and folders, or $false to simulate
$performDeletion = $false  # Set to $false for simulation mode

# Initialize variables to track the total size and count of files deleted across all paths
$totalSizeDeleted = 0
$totalFilesDeleted = 0
$totalFoldersDeleted = 0

# Initialize the log file
"Starting deletion process of VHD and VHDX files at $(Get-Date)" | Out-File -FilePath $logFilePath

# Loop through each profile folder path
foreach ($profileFolderPath in $profileFolderPaths) {
    # Log the current profile folder being processed
    "Processing profile folder: $profileFolderPath" | Out-File -FilePath $logFilePath -Append
    Write-Output "Processing profile folder: $profileFolderPath"

    # Check if the path exists
    if (-Not (Test-Path -Path $profileFolderPath)) {
        $errorOutput = "Error: The path '$profileFolderPath' does not exist."
        Write-Output $errorOutput
        $errorOutput | Out-File -FilePath $logFilePath -Append
        continue  # Skip to the next path
    }

    # Find all VHD and VHDX files in the profile folder recursively, including hidden and system files
    $files = Get-ChildItem -Path $profileFolderPath -Recurse -Force | Where-Object { 
        -not $_.PSIsContainer -and ($_.Extension -eq ".vhd" -or $_.Extension -eq ".vhdx") 
    }

    # Initialize variables for the current profile folder
    $folderSizeDeleted = 0
    $folderFilesDeleted = 0
    $folderFoldersDeleted = 0

    # Process the files to delete or simulate deletion
    $files | ForEach-Object {
        $filePath = $_.FullName
        $fileSizeMB = [math]::Round($_.Length / 1MB, 2)

        # Ensure LastWriteTime is valid before proceeding
        if ($_.LastWriteTime -ne $null) {
            $fileLastModified = $_.LastWriteTime
            $fileAgeDays = (New-TimeSpan -Start $fileLastModified -End (Get-Date)).Days

            # Check if the file is older than the threshold
            if ($fileAgeDays -gt $ageThreshold) {
                $reason = "File was last modified $fileAgeDays days ago, exceeding the threshold of $ageThreshold days."

                if ($performDeletion) {
                    # Attempt to delete the file
                    try {
                        Remove-Item -Path $filePath -Force -ErrorAction Stop
                        $deletionSucceeded = $true
                    } catch {
                        $deletionSucceeded = $false
                        $errorMessage = $_.Exception.Message
                    }

                    if ($deletionSucceeded) {
                        $fileOutput = "Deleted: $filePath ($fileSizeMB MB) - $reason"
                        # Add file size to total size deleted
                        $folderSizeDeleted += $_.Length
                        $folderFilesDeleted += 1
                    } else {
                        $fileOutput = "Failed to delete: $filePath ($fileSizeMB MB) - $errorMessage"
                    }
                } else {
                    # Simulate deletion
                    $fileOutput = "Simulated deletion: $filePath ($fileSizeMB MB) - $reason"
                    Remove-Item -Path $filePath -Force -WhatIf
                    # For simulation, add file size to total size to be deleted
                    $folderSizeDeleted += $_.Length
                    $folderFilesDeleted += 1
                }

                # Output to console and append to log file
                Write-Output $fileOutput
                $fileOutput | Out-File -FilePath $logFilePath -Append

            } else {
                $reason = "File was last modified $fileAgeDays days ago, within the threshold of $ageThreshold days. Not deleting."
                $fileOutput = "Skipping: $filePath ($fileSizeMB MB) - $reason"

                # Output to console and append to log file
                Write-Output $fileOutput
                $fileOutput | Out-File -FilePath $logFilePath -Append
            }
        } else {
            # Handle cases where LastWriteTime is null or not valid
            $fileOutput = "Skipping: $filePath - Unable to determine last modified date."
            Write-Output $fileOutput
            $fileOutput | Out-File -FilePath $logFilePath -Append
        }
    }

    # After deleting files, attempt to delete empty folders
    "Starting deletion of empty folders in $profileFolderPath at $(Get-Date)" | Out-File -FilePath $logFilePath -Append

    # Find all directories under the profile folder, including hidden and system folders
    $directories = Get-ChildItem -Path $profileFolderPath -Recurse -Force | Where-Object { $_.PSIsContainer }

    # Reverse the list to delete from the deepest nested folders first
    $directories = $directories | Sort-Object -Property FullName -Descending

    $directories | ForEach-Object {
        $dirPath = $_.FullName
        # Check if the directory is empty (including hidden and system files)
        if (-Not (Get-ChildItem -Path $dirPath -Force)) {
            # Directory is empty
            if ($performDeletion) {
                try {
                    Remove-Item -Path $dirPath -Force -Recurse -ErrorAction Stop
                    $folderDeleted = $true
                } catch {
                    $folderDeleted = $false
                    $errorMessage = $_.Exception.Message
                }

                if ($folderDeleted) {
                    $folderOutput = "Deleted empty folder: $dirPath"
                    $folderFoldersDeleted += 1
                } else {
                    $folderOutput = "Failed to delete folder: $dirPath - $errorMessage"
                }
            } else {
                # Simulate deletion
                $folderOutput = "Simulated deletion of empty folder: $dirPath"
                Remove-Item -Path $dirPath -Force -Recurse -WhatIf
                $folderFoldersDeleted +=1
            }

            # Output to console and append to log file
            Write-Output $folderOutput
            $folderOutput | Out-File -FilePath $logFilePath -Append
        }
    }

    # Update the total counts and sizes
    $totalSizeDeleted += $folderSizeDeleted
    $totalFilesDeleted += $folderFilesDeleted
    $totalFoldersDeleted += $folderFoldersDeleted

    # Convert the folder size from bytes to a more readable format (e.g., MB)
    $folderSizeDeletedMB = [math]::Round($folderSizeDeleted / 1MB, 2)

    # Output the totals for the current profile folder
    if ($performDeletion) {
        $summaryOutput = "Profile folder: $profileFolderPath"
        Write-Output $summaryOutput
        $summaryOutput | Out-File -FilePath $logFilePath -Append

        $summaryOutput = "Total number of files deleted: $folderFilesDeleted"
        Write-Output $summaryOutput
        $summaryOutput | Out-File -FilePath $logFilePath -Append

        $summaryOutput = "Total size of VHD and VHDX files deleted: $folderSizeDeletedMB MB"
        Write-Output $summaryOutput
        $summaryOutput | Out-File -FilePath $logFilePath -Append

        $summaryOutput = "Total number of empty folders deleted: $folderFoldersDeleted"
        Write-Output $summaryOutput
        $summaryOutput | Out-File -FilePath $logFilePath -Append
    } else {
        $summaryOutput = "Profile folder: $profileFolderPath"
        Write-Output $summaryOutput
        $summaryOutput | Out-File -FilePath $logFilePath -Append

        $summaryOutput = "Total number of files that would be deleted: $folderFilesDeleted"
        Write-Output $summaryOutput
        $summaryOutput | Out-File -FilePath $logFilePath -Append

        $summaryOutput = "Total size of VHD and VHDX files that would be deleted: $folderSizeDeletedMB MB"
        Write-Output $summaryOutput
        $summaryOutput | Out-File -FilePath $logFilePath -Append

        $summaryOutput = "Total number of empty folders that would be deleted: $folderFoldersDeleted"
        Write-Output $summaryOutput
        $summaryOutput | Out-File -FilePath $logFilePath -Append
    }
}

# Convert the total size from bytes to a more readable format (e.g., MB)
$totalSizeDeletedMB = [math]::Round($totalSizeDeleted / 1MB, 2)

# Output the grand totals
"-------------------------------" | Out-File -FilePath $logFilePath -Append
"Grand Totals:" | Out-File -FilePath $logFilePath -Append
Write-Output "-------------------------------"
Write-Output "Grand Totals:"

if ($performDeletion) {
    $summaryOutput = "Total number of files deleted: $totalFilesDeleted"
    Write-Output $summaryOutput
    $summaryOutput | Out-File -FilePath $logFilePath -Append

    $summaryOutput = "Total size of VHD and VHDX files deleted: $totalSizeDeletedMB MB"
    Write-Output $summaryOutput
    $summaryOutput | Out-File -FilePath $logFilePath -Append

    $summaryOutput = "Total number of empty folders deleted: $totalFoldersDeleted"
    Write-Output $summaryOutput
    $summaryOutput | Out-File -FilePath $logFilePath -Append
} else {
    $summaryOutput = "Total number of files that would be deleted: $totalFilesDeleted"
    Write-Output $summaryOutput
    $summaryOutput | Out-File -FilePath $logFilePath -Append

    $summaryOutput = "Total size of VHD and VHDX files that would be deleted: $totalSizeDeletedMB MB"
    Write-Output $summaryOutput
    $summaryOutput | Out-File -FilePath $logFilePath -Append

    $summaryOutput = "Total number of empty folders that would be deleted: $totalFoldersDeleted"
    Write-Output $summaryOutput
    $summaryOutput | Out-File -FilePath $logFilePath -Append
}

# Log completion
if ($performDeletion) {
    "Deletion process completed at $(Get-Date)" | Out-File -FilePath $logFilePath -Append
    Write-Output "Deletion process completed at $(Get-Date)"
} else {
    "Deletion simulation completed at $(Get-Date)" | Out-File -FilePath $logFilePath -Append
    Write-Output "Deletion simulation completed at $(Get-Date)"
}
