# Evaluation code
#==============================
# Configurable Variables
#==============================
# these variables should reflect what is configured in the Remediation code
always_run=0 # 0=true, 1=false
env_vars=("REQUESTS_CA_BUNDLE" "WEBSOCKET_CLIENT_CA_BUNDLE" "NODE_EXTRA_CA_CERTS" "AWS_CA_BUNDLE" "SSL_CERT_FILE" "CURL_CA_BUNDLE")
cert_path="/opt/proxy"
cert_name="cabundle.pem"
shells=("/etc/bashrc" "/etc/zshrc")

#==============================
# Dynamic Variables
#==============================
cert_file="$cert_path/$cert_name"

if [ $always_run -eq 0 ]; then
    exit 1
fi
# iterate through shell global rc files
for s in "${shells[@]}"; do
    for varname in "${env_vars[@]}"; do
        # if a variable does not exist in the rc file, run remediation
        if ! grep -q "${varname}" "$s" 2>&1 >/dev/null; then
            exit 1
        fi
    done
done
# if the certificate bundle or target path do not exist, run remediation
if [ ! -f "$cert_file" ] || [ ! -d "$cert_path" ]; then
    exit 1
fi

# Remediation code
#================================================================
# HEADER
#================================================================
# SYNOPSIS
#    Creates environment variables for internal CA certificates.
#
# DESCRIPTION
#   With this worklet we need to have an idea of what environment variables need to be set
#   for our environments, as well as whether we want the worklet to distribute the certificate.
#   If the worklet does not distribute the certificate, it assumes that you have 
#   loaded the internal CA root certificate into the system certificate store through system management.
#   Due to the way environment variables work, changes from this worklet won't be reflected on user systems
#   until they quit and reopen applications.
#
# USAGE
#    ./remediation.sh
#
# EXAMPLES
#	  ./remediation.sh
#    
#================================================================
# IMPLEMENTATION
#    version         1.1
#    authors         Mat Lee, Randall Pipkin
# 
#================================================================
# END_OF_HEADER
#================================================================


#==============================
# Configurable Variables
#==============================
# the temporary worklet certificate file name, uncomment and 
# replace the <certofocate.crt> with the filename(s) you've uploaded.
# the file must be in PEM format (starts with -----BEGIN CERTIFICATE-----)
tmp_certs=() # ("$(pwd)/<ca.crt>" "$(pwd)/<intermediate.crt>")
# the target certificate bundle file name
cert_name="cabundle.pem"
# the target certificate bundle directory
# this worklet will create the cabundle.pem file in this directory
cert_path="/opt/proxy"
# The array of environment variables you would like to distribute to user profiles
env_vars=("REQUESTS_CA_BUNDLE" "WEBSOCKET_CLIENT_CA_BUNDLE" "NODE_EXTRA_CA_CERTS" "AWS_CA_BUNDLE" "SSL_CERT_FILE" "CURL_CA_BUNDLE")
## !!! supported shell rc files -- this is how we add variables across different users
# by default there are two shells that come with macOS, and this script will attempt 
# to add variables in locations to support both
shells=("/etc/bashrc" "/etc/zshrc")
# we will also write a plist file to user directories that enable loading 
# environment variables automatically for broader coverage. It will be named with this variable
plist_file="proxy-env-vars.plist"
# list of application paths needing java keystore updates -- IMPORTANT NOTES !!
# !! this code will only run if a certificate is distributed WITH the worklet.
# !! if they are installed to a global location, include the full path
# !! if they are installed to user-relative locations, then prefix with a '.' in place of '~'
java_app_dirs=("./Library/Application Support/JetBrains" "/usr/local/Cellar/openjdk")

#==============================
# Dynamic Variables
#==============================
# full file path for reference later
cert_file="${cert_path}/${cert_name}"
# list of user accounts within /users dir
users=$(dscacheutil -q user | egrep -A 3 -B 2 "5[0-9]{2}" | egrep -B 5 "dir: /Users" | grep "name:" | awk '{print $2}')
# current logged in user, if there is one
loggedInUser=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )

# ensure new files are generated in +r only
umask 022

# temporary cert bundle store
tmp_path="$(pwd)/${cert_name}.tmp"

echo "Generating root certificate dump"
security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain /Library/Keychains/System.keychain > "${tmp_path}"
if [ "${tmp_certs}" != "" ]; then
    echo "Appending worklet or otherwise provided certificates to root bundle"
    for tmp_cert in "${tmp_certs[@]}"; do
        cat "${tmp_cert}" | sudo tee -a "${tmp_path}" >/dev/null
    done
fi

# check and create the destination directory if it doesn't exist
if [ ! -d "${cert_path}" ]; then
    echo "Creating directory for storing the CA bundle"
    sudo mkdir -p "${cert_path}"
fi
# ensure the destination directory is accessible to all users for read-only
sudo chmod +rx "${cert_path}"

# lock down the file before moving it to prevent writes, just in case
chmod go-wx "${tmp_path}"
# ensure it can be read by everyone
chmod +r "${tmp_path}"

# copy the cert bundle to the desired destination, remove tmp bundle
sudo mv "${tmp_path}" "${cert_file}"

# iterate through and set all environment variables in global locations
# this will place the values in global shell rc files, as well as
# create plists in user profiles, to minimize impact when macOS 
# randomly overwrites /etc/bashrc and /etc/zshrc files during updates
function config_envs () {
    # populate environment variables in global rc files for common shells
    for s in "${shells[@]}"; do
        echo "Checking for environment variables in $s"
        # iterate over declared variables
        for varname in "${env_vars[@]}"; do
            # if they do not exist in the destination file, add them
            if ! grep -q "${varname}" "$s" 2>&1 >/dev/null; then
                echo "Exporting ${varname} to $s"
                echo "export ${varname}='${cert_file}'" | sudo tee -a "$s" >/dev/null
            fi
        done
    done

    # populate environment variables in user plists for broader coverage and persistence
    echo "Checking user profiles for environment variable plists"
    for user in ${users}; do
        # get user account home directory
        userdir=$(dscacheutil -q user -a name $user | grep "dir:" | awk '{print $2}')
        # create the full path to the user plist target directory
        plist_path="${userdir}/Library/LaunchAgents"
        plist_full_path="${plist_path}/${plist_file}"
        plist_file_hash="$(pwd)/${plist_file}.sum"

        # if the directory doesn't exist, create it
        if [ ! -d "${plist_path}" ]; then
            echo "Creating launchAgent path for user ${user}"
            sudo mkdir -p "${plist_path}"
        fi
        # create the plist file as a launch agent to run on load
        # we're going to check the file hash sum before/after the script
        # to look for changes so we can decide on whether we need to reload the plist
        shasum "${plist_full_path}" > "${plist_file_hash}"
        cat << EOF > "${plist_full_path}"
<?xml version="1.0" encoding="UTF-8"?>

<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" 
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">

<plist version="1.0">
    <dict>
        <key>Label</key>
        <string>Automox Managed Environment Variables</string>
        <key>ProgramArguments</key>
        <array>
        <string>sh</string>
        <string>-c</string>
        <string>$(for varname in "${env_vars[@]}"; do echo -n "launchctl setenv ${varname} '${cert_file}'; "; done)</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
    </dict>
</plist>
EOF
    
        # if the user session is active, we can get the updated variables into _new_ instances of
        # applications, if we reload the plist and the user restarts the applications
        if [ "${user}" == "${loggedInUser}" ]; then
            echo "Checking plist hash sums for changes"
            # check new hash vs old, if changed, reload service
            if ! shasum -c "${plist_file_hash}" 2>&1 >/dev/null; then
                echo "Reloading user ${loggedInUser} plist file"
                for launchd_action in $(echo stop unload load start); do
                    sudo -u ${loggedInUser} launchctl ${launchd_action} "${plist_path}/${plist_file}"
                done

            else
                echo "Skipping plist reload for ${loggedInUser}, no updates"
            fi
        fi

    done
}

function keystore_config () {
  echo "Checking for software certificate keystores"
  
  # iterate over defined Java-based application root directories
  for app_dir in "${java_app_dirs[@]}"; do
    
    # check for whether it's a user-profile based path
    if [ "$app_dir" != "" ] && [ "${app_dir:0:1}" == "." ]; then
        # this is a user profile path, iterate through users checking for application
        for user in ${users}; do

            # define user-relative path for application
            user_root="/Users/${user}/${app_dir:2}"

            # if application directory exists, check for keystores
            if [ -d "${user_root}" ]; then
                echo "Found Java application directory ${app_dir}, checking for keystores"

                # Check for the existence of keytool, or else check the app directory for it.
                # If it does not exist, then skip the app.
                if ! which keytool 2>&1 >/dev/null; then
                    # search for keytool in app directory
                    keytool=$(find "${user_root}" -type f -print -quit 2>/dev/null)
                    if [ "$keytool" == "" ]; then
                        echo "unable to find keytool in path or relative directory, skipping ${user_root}"
                        continue
                    fi
                else
                    # capture keytool path
                    keytool=$(which keytool)
                fi

                # output from find command looking for files named `cacerts`, the usual name for java cert keystores
                while read -r cacert_store; do

                    echo "Found ${app_dir} keystore, checking for NS certs"
                    # changeit is the default password for a number of applications
                    certs=$({ echo changeit; } | keytool -list -keystore "${cacert_store}" && echo >&2 | grep -v password)

                    # for each worklet-attached certificate defined above, load into the found keystores.
                    for tmp_cert in "${tmp_certs[@]}"; do

                        # friendly name based on filename
                        cert_friendly_name=$(basename "${tmp_cert}" | tr '.' '-')

                        # if the friendly-name is already present, then skip else add it
                        if ! grep "${cert_friendly_name}" <<<$certs 2>&1 > /dev/null; then
                            echo "Adding ${cert_friendly_name} certificate to keystore at ${cacert_store}"
                            noout=$({ echo changeit; sleep 1; echo yes; } | keytool -importcert -file "${tmp_cert}" -alias ${cert_friendly_name} -keystore "${cacert_store}" 2>&1 > /dev/null)
                        else
                            echo "Certificate ${cert_friendly_name} already present in target keystore"
                        fi

                    done

                done < <(find "${user_root}" -type f -name cacerts)
            fi

        done
    else
        # it is not a user profile path, check for the full path on disk
        if [ -d "${app_dir}" ]; then
            # output from find command looking for files named `cacerts`, the usual name for java cert keystores
            while read -r cacert_store; do

                if ! which keytool 2>&1 >/dev/null; then
                    # search for keytool in app directory
                    keytool=$(find "${app_dir}" -type f -print -quit 2>/dev/null)
                    if [ "$keytool" == "" ]; then
                        echo "unable to find keytool in path or relative directory, skipping ${app_dir}"
                        continue
                    fi
                else
                    # capture keytool path
                    keytool=$(which keytool)
                fi

                echo "Found ${app_dir} keystore, checking for NS certs"
                certs=$({ echo changeit; } | keytool -list -keystore "${cacert_store}" | grep -v password)

                for tmp_cert in "${tmp_certs[@]}"; do

                    # friendly name based on filename 
                    cert_friendly_name=$(basename "${tmp_cert}" | tr '.' '-')

                    # if the friendly-name is already present, then skip else add it
                    if ! grep "${cert_friendly_name}" <<<$certs 2>&1 > /dev/null; then
                        echo "Adding ${cert_friendly_name} certificate to keystore at ${cacert_store}"
                        noout=$({ echo changeit; sleep 1; echo yes; } | keytool -importcert -file "${tmp_cert}" -alias ${cert_friendly_name} -keystore "${cacert_store}" 2>&1 > /dev/null)
                    else
                        echo "Certificates ${cert_friendly_name} already present in target keystore"
                    fi
                    
                done

            done < <(find "${app_dir}" -type f -name cacerts)
        fi
    fi

  done
}

config_envs

# if worklet-attached certificates have been defined, and there are 
# defined java applications, then run keystore_config
if [ "${tmp_certs}" != "" ] && [ "$java_app_dirs" != "" ]; then
    keystore_config
fi