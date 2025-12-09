function Replace-SpacesAndUnderscores {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InputString
  )
  return ($InputString -replace '[ _]', '-')
}

function To-Lower {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InputString
  )
  return $InputString.ToLower()
}

function To-Upper {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InputString
  )
  return $InputString.ToUpper()
}

# Example usage: Rename all files in the current directory
# Replace spaces/underscores with '-' and convert to lowercase.

Get-ChildItem -File | ForEach-Object {
  $originalName = $_.Name
  $newName = Replace-SpacesAndUnderscores $originalName
  # Choose which case conversion to apply:
  $newName = To-Lower $newName
  # To convert to uppercase instead, replace the line above with:
  # $newName = To-Upper $newName

  if ($newName -ne $originalName) {
    Write-Host "Renaming '$originalName' to '$newName'"
    Rename-Item -Path $_.FullName -NewName $newName
  }
  else {
    Write-Host "'$originalName' already meets the naming conventions, no changes made."
  }
}
