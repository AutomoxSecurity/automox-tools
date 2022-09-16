## Evaluation code
# these variables should reflect what is configured in the Remediation code
#==============================
# Configurable Variables
#==============================
$always_run = $true
$vars = @("REQUESTS_CA_BUNDLE","GIT_SSL_CAPATH","NODE_EXTRA_CA_CERTS","WEBSOCKET_CLIENT_CA_BUNDLE","AWS_CA_BUNDLE","SSL_CERT_FILE")
$certFilePath = "$env:ProgramData\proxy"
$certFileName = "cabundle.crt"

#==============================
# Dynamic Variables
#==============================
$certFile = "$certFilePath\$certFileName"

if ($always_run) {
    exit 1
}
foreach ($var in $vars) {
    if (![System.Environment]::GetEnvironmentVariable($var)) {
        exit 1
    }
}
if (!(Test-Path $certFile)) {
    exit 1
}




## Remediation code
#================================================================
# HEADER
#================================================================
# SYNOPSIS
#    Creates environment variables for internal CA certificates.
#
# DESCRIPTION
#   To use this worklet we need to have an idea of what environment variables need to be set
#   for our environments, as well as if we want the worklet to distribute the CA certificate.
#   If the worklet does not distribute the certificate it assumes that you have loaded the 
#   CA certificate into the system certificate store through system management, or otherwise.
#   Once we run the worklet, it will output a dump of all system root CAs to a bundle file
#   on disk, which will be referenced by the configured environment variables.
#
# USAGE
#    ./remediation.ps1
#
# EXAMPLES
#	  ./remediation.ps1
#    
#================================================================
# IMPLEMENTATION
#    version         1.1
#    author          Randall Pipkin
# 
#================================================================
# END_OF_HEADER
#================================================================

#==============================
# Configurable Variables
#==============================
# Each identified environment variable you need to support in your environment
# make sure this matches what you're evaluating against
$vars = @("REQUESTS_CA_BUNDLE","GIT_SSL_CAPATH","NODE_EXTRA_CA_CERTS","WEBSOCKET_CLIENT_CA_BUNDLE","AWS_CA_BUNDLE","SSL_CERT_FILE")
# specify the commented a value if you're delivering the certificate via Worklet attachment
# replace <worklet.crt> with the name of your cert file
$tmpFiles = @() # @("$pwd\<ca.crt>", "$pwd\<intermediate.crt>")
# The filename of the target certificates bundle file
$certFileName = "cabundle.crt"
# The path the certificate will be stored at for environment variable reference, default is C:\ProgramData\proxy
$certFilePath = "$env:ProgramData\proxy"
# paths to check for java keystores
$java_app_paths = @("C:\Program Files\JetBrains")

#=============================
# Dynamic Variables
#=============================
$certFile = "$certFilePath\$certFileName"

# The following section only runs when a certificate is being provided with the worklet.
# It takes the provided certificate, and appends it to the list of Trusted Root certificates.
# Then outputs the list of certificates as a bundle to disk, and sets it as read-only.


#if the desired directory does not exist, create it
if (!(Test-Path -PathType container $certFilePath)) {
    Write-Host "Creating output directory $certFilePath, as it does not exist"
    New-Item -ItemType Directory -Force -Path $certFilePath
}

# check if the file exists, if it does, we need to remove the readOnly flag
if ((Test-Path $certFile)) {
    Write-Host "Found existing bundle file, removing ReadOnly flag"
    Set-ItemProperty -Path $certFile -Name IsReadOnly -Value $false
}

# We dump the trusted root store to file, as proxies or secure web gateways may selectively decrypt traffic.
# This means we need to be able to handle both internal and trusted roots, and both need to be present in the certificate bundle
Write-Host "Writing bundle file from trusted root store"
((Get-ChildItem Cert: -Recurse | Where-Object { $_.RawData -ne $null } `
    | Sort-Object -Property Thumbprint -Unique `
    |% { "-----BEGIN CERTIFICATE-----", [System.Convert]::ToBase64String($_.RawData, "InsertLineBreaks"), "-----END CERTIFICATE-----", "" }) `
    -replace "`r","") -join "`n" `
    | Out-File -Encoding ascii $certFile -NoNewline -ErrorAction Stop

# append the worklet certificates to the trusted roots
if ($tmpFiles) {
    Write-Host "Appending provided certificates to root bundle"
    # grab contents of existing bundle file
    $file_contents = (Get-Content $certFile -Raw) 
    # iterate over provided certificates

    foreach ($tmpFile in $tmpFiles) {
        # grab contents of worklet certificate, replace removing carriage
        $tmp_content = "`n" + ((Get-Content $tmpFile -Raw) -replace "`r","")
        # pipe the combined contents to overwrite the bundle file
        $tmp_content | Out-File -Append -Encoding ascii $certFile -NoNewline -ErrorAction Stop
    }

}

Write-host "Locking down permissions to bundle file"
# lockdown the file so adding new certificates outside of administrators isn't possible by)
# iterating over the list of inherent permissions, and removing all except SYSTEM and Administrators
$ruleAllowReadEveryone = New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone", "Read", "Allow")
$certACLs = (Get-Item $certFile).GetAccessControl('Access')
$certACLs.Access `
    | ? { $_.IdentityReference -ne "NT AUTHORITY\SYSTEM" -and $_.IdentityReference -ne "BUILTIN\Administrators" } `
    | % { $certACLs.RemoveAccessRule($_) 2>&1 >$null }

# allow everyone read access to handle drop privileges, as this is not a sensitive file.
$certACLs.AddAccessRule($ruleAllowReadEveryone)
Set-Acl -AclObject $certACLs $certFile

# readOnly flag, as the file doesn't need to be edited other than by this script
Set-ItemProperty -Path $certFile -Name IsReadOnly -Value $true

if (! (Test-Path $certFile)) {
    Write-Error "Defined certificate bundle file does not exist, or was not properly created."
    exit 1
}

Write-Host "Configuring desired environment variables for the system"
# set each of the system environment variables if they do not exist
foreach ($var in $vars) {
    if (![System.Environment]::GetEnvironmentVariable($var)) {
        [System.Environment]::SetEnvironmentVariable($var, $certFile, [System.EnvironmentVariableTarget]::Machine)
    }
}

Write-Host "Checking for defined java application presence"
# search recursively through each defined Java applications path
foreach ($java_app in $java_app_paths) {
    # get keytool exe path if it's present in path
    $keytool_path = ""
    if (Get-Command keytool 2>&1 >$null) {
        $keytool_path = (Get-Command keytool).Source
    }
    else {
        # keytool is not in path, search the application directory
        Write-Warning "Unable to find keytool.exe in path, checking application directory"
        $keytool_path = (
            Get-ChildItem -Path "C:\Program Files\JetBrains" -filter keytool.exe -Recurse -ErrorAction SilentlyContinue -Force `
            | Select-Object -First 1
            ).FullName
    }
    # verify we have a keytool path to work with
    if ($keytool_path) {
        # iterate through keystores, checking for existing certificates
        Get-ChildItem -Path $java_app -filter cacerts -Recurse -ErrorAction SilentlyContinue -Force | % {
            Write-Host "Checking keystore '$($_.FullName)' for certificates."
            # grab list of current keystore certs
            $certs = (echo changeit | & $keytool_path -list -keystore $_.FullName 2>&1 | Select-String -NotMatch password) 

            foreach ($cert in $tmpFiles) {
                Write-Host "Checking for presence of $((Get-Item $cert).Name) in keystore"
                $cert_friendly_name = (Get-Item $cert).Name.Replace(".","-")
                $found = $false
                # iterate through each certificate in the Java keystore
                foreach ($cert_entry in $certs) {
                    # refer to the entire line string rather than the string-match object
                    $cert_entry = $cert_entry.Line
                    # if the cert friendly name matches a line in the file, mark as found
                    if ($cert_entry -ne "" -and $cert_entry.StartsWith($cert_friendly_name)) {
                        $found = $true
                        break
                    }
                }
                # if this certificate didn't exist, we should add it.
                if (!$found) {
                    Write-Host "Certificate $cert_friendly_name missing from keystore, adding"
                    echo "changeit`nyes`n" | & $keytool_path -importcert -file $cert -alias $cert_friendly_name -keystore $_.FullName 2>$null >$null 
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "Failed to add certificate to keystore '$($_.FullName)', check password and permissions"
                    }
                }
                else {
                    Write-Host "Certificate $cert_friendly_name already exists, skipping"
                }
            }
        }
    }
    else {
        Write-Warning "Cannot find keytool.exe to modify keystores, skipping $java_app"
    }
}