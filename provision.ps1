Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
trap {
    #Write-Host
    #Write-Host 'whoami from autounattend:'
    #Get-Content C:\whoami-autounattend.txt | ForEach-Object { Write-Host "whoami from autounattend: $_" }
    #Write-Host 'whoami from current WinRM session:'
    #whoami /all >C:\whoami-winrm.txt
    #Get-Content C:\whoami-winrm.txt | ForEach-Object { Write-Host "whoami from winrm: $_" }
    Write-Host
    Write-Host "ERROR: $_"
    Write-Host (($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$','ERROR: $1')
    Write-Host (($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$','ERROR EXCEPTION: $1')
    Write-Host
    Write-Host 'Sleeping for 60m to give you time to look around the virtual machine before self-destruction...'
    Start-Sleep -Seconds (60*60)
    Exit 1
}

# enable TLS 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol `
    -bor [Net.SecurityProtocolType]::Tls12

if (![Environment]::Is64BitProcess) {
    throw 'this must run in a 64-bit PowerShell session'
}

if (!(New-Object System.Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'this must run with Administrator privileges (e.g. in a elevated shell session)'
}

Add-Type -A System.IO.Compression.FileSystem

# mount Guest Additions iso
# work around for issue https://github.com/hashicorp/packer/issues/11357
# ISO image - replace with path to ISO to be mounted
$isoImg = "C:\Users\vagrant\VBoxGuestAdditions.iso"
# Drive letter - use desired drive letter
$driveLetter = "E:"
# Mount the ISO, without having a drive letter auto-assigned
$diskImg = Mount-DiskImage -ImagePath $isoImg  -NoDriveLetter
# Get mounted ISO volume
$volInfo = $diskImg | Get-Volume
# Mount volume with specified drive letter (requires Administrator access)
mountvol $driveLetter $volInfo.UniqueId

# install Guest Additions.
$systemVendor = (Get-WmiObject Win32_ComputerSystemProduct Vendor).Vendor
if ($systemVendor -eq 'QEMU') {
    # do nothing. this was installed in provision-guest-tools-qemu-kvm.ps1.
} elseif ($systemVendor -eq 'innotek GmbH') {
    Write-Host 'Importing the Oracle (for VirtualBox) certificate as a Trusted Publisher...'
    E:\cert\VBoxCertUtil.exe add-trusted-publisher E:\cert\vbox-sha1.cer
    if ($LASTEXITCODE) {
        throw "failed to import certificate with exit code $LASTEXITCODE"
    }

    Write-Host 'Installing the VirtualBox Guest Additions...'
    E:\VBoxWindowsAdditions-amd64.exe /S | Out-String -Stream
    if ($LASTEXITCODE) {
        throw "failed to install with exit code $LASTEXITCODE. Check the logs at C:\Program Files\Oracle\VirtualBox Guest Additions\install.log."
    }
} elseif ($systemVendor -eq 'Microsoft Corporation') {
    # do nothing. Hyper-V enlightments are already bundled with Windows.
} elseif ($systemVendor -eq 'VMware, Inc.') {
    # do nothing. VMware Tools were already installed by vmtools.ps1 (executed from autounattend.xml).
} else {
    throw "Cannot install Guest Additions: Unsupported system ($systemVendor)."
}

Write-Host 'Setting the vagrant account properties...'
# see the ADS_USER_FLAG_ENUM enumeration at https://msdn.microsoft.com/en-us/library/aa772300(v=vs.85).aspx
$AdsScript              = 0x00001
$AdsAccountDisable      = 0x00002
$AdsNormalAccount       = 0x00200
$AdsDontExpirePassword  = 0x10000
$account = [ADSI]'WinNT://./vagrant'
$account.Userflags = $AdsNormalAccount -bor $AdsDontExpirePassword
$account.SetInfo()

Write-Host 'Setting the Administrator account properties...'
$account = [ADSI]'WinNT://./Administrator'
$account.Userflags = $AdsNormalAccount -bor $AdsDontExpirePassword -bor $AdsAccountDisable
$account.SetInfo()

Write-Host 'Disabling auto logon...'
$autoLogonKeyPath = 'HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $autoLogonKeyPath -Name AutoAdminLogon -Value 0
@('DefaultDomainName', 'DefaultUserName', 'DefaultPassword') | ForEach-Object {
    Remove-ItemProperty -Path $autoLogonKeyPath -Name $_ -ErrorAction SilentlyContinue
}

Write-Host 'Disabling Automatic Private IP Addressing (APIPA)...'
Set-ItemProperty `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' `
    -Name IPAutoconfigurationEnabled `
    -Value 0

Write-Host 'Disabling IPv6...'
Set-ItemProperty `
    -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' `
    -Name DisabledComponents `
    -Value 0xff

Write-Host 'Disabling hibernation...'
powercfg /hibernate off

Write-Host 'Setting the power plan to high performance...'
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

Write-Host 'Disabling the Windows Boot Manager menu...'
# NB to have the menu show with a lower timeout, run this instead: bcdedit /timeout 2
#    NB with a timeout of 2 you can still press F8 to show the boot manager menu.
bcdedit /set '{bootmgr}' displaybootmenu no

# remove temporary files.
# NB we ignore the packer generated files so it won't complain in the output.
'C:\tmp','C:\Windows\Temp',$env:TEMP | ForEach-Object {
    Get-ChildItem $_ -Exclude 'packer-*' -Recurse | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}
