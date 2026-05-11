# Modules
Set-ExecutionPolicy -ExecutionPolicy Unrestricted
$modules = @('Az.Accounts','Az.DesktopVirtualization','Az.ConnectedMachine')
foreach ($m in $modules) { if (-not (Get-Module -ListAvailable -Name $m))
{ Install-Module $m -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop } ; Import-Module $m -ErrorAction Stop }

# Parameters
$SubscriptionId = "yourAzuresubhere"
$HostPoolRG = "AVDHybrid"
$HostPoolName = "AVDHybrid"
$ArcRG = "AVDHybrid"
$ArcMachine = $env:COMPUTERNAME
$ArcRegion = "uksouth"
$ExtType = "CloudDeviceExtension"
$ExtPublisher = "Microsoft.AzureVirtualDesktop"
$ExtName = "$ExtPublisher.$ExtType"

# Auth
Connect-AzAccount -DeviceCode -ErrorAction Stop | Out-Null
Select-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop

# Registration token (~24 hours)
$expiresUtc = (Get-Date).ToUniversalTime().AddHours(24).ToString("o")
$regInfo = New-AzWvdRegistrationInfo -ResourceGroupName $HostPoolRG -HostPoolName $HostPoolName -ExpirationTime $expiresUtc
$token = $regInfo.Token

# Settings
$settings = @{ isCloudDevice = $false }
$protectedSettings = @{ registrationToken = $token }

# Install extension
New-AzConnectedMachineExtension -Name $ExtName -ResourceGroupName $ArcRG -MachineName $ArcMachine -Location $ArcRegion -Publisher $ExtPublisher -ExtensionType $ExtType -Setting $settings -ProtectedSetting $protectedSettings -ErrorAction Stop
