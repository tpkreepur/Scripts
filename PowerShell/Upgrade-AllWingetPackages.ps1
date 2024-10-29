# Upgrade-AllWingetPackages.ps1
# This script upgrades all the winget packages installed on the current machine.

# Get the list of installed packages
$installedPackages = winget list

# Loop through each package and upgrade it
foreach ($package in $installedPackages) {
  $packageName = $package.Name
  Write-Output "Upgrading $packageName..."
  winget upgrade --id $package.Id --silent --accept-source-agreements --accept-package-agreements
}

Write-Output "All packages have been upgraded."
