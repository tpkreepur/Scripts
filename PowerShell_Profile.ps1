$shell = $Host.UI.RawUI

$shell.WindowTitle = "PS"

$shell.BackgroundColor = "Black"
$shell.ForegroundColor = "White"

Set-Location D:\RedArrow\Scripts

Set-StrictMode -Version 2

function Set-OhMyPoshThemeBasedOnAWSProfile {
  if ($env:AWS_PROFILE) {
      Set-PoshPrompt -Theme "cloud-context"
  } else {
      Set-PoshPrompt -Theme "clean-detailed"
  }
}

Import-Module posh-git
Import-Module oh-my-posh
Set-OhMyPoshThemeBasedOnAWSProfile
