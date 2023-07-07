#!/bin/bash --posix

# ---------------------------------------------------------------------
# Copyright (C) 2023 Atrate, Baesili, Cpitao
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>
# ---------------------------------------------------------------------

# --------------
# Version: 1.0.0
# --------------

# ------------------------------------------------------------------------------
# This is a 'simple' bash and dialog-based script to help you deal with Certum
# smartcards without having to pull your remaining hair out. Refer to the README
# for the supported OSes.
# --------------------
# Exit code listing:
#   0: All good
#   1: Unspecified
#   2: Error in environment configuration or arguments
#   3: Runtime requirements not satisfied
# ------------------------------------------------------------------------------

## -----------------------------------------------------
## SECURITY SECTION
## NO EXECUTABLE CODE CAN BE PRESENT BEFORE THIS SECTION
## -----------------------------------------------------

# Set POSIX-compliant mode for security and unset possible overrides
# NOTE: This does not mean that we are restricted to POSIX-only constructs
# ------------------------------------------------------------------------
POSIXLY_CORRECT=1
set -o posix
readonly POSIXLY_CORRECT
export POSIXLY_CORRECT

# Set IFS explicitly. POSIX does not enforce whether IFS should be inherited
# from the environment, so it's safer to set it expliticly
# --------------------------------------------------------------------------
IFS=$' \t\n'
export IFS

# -----------------------------------------------------------------------
# For additional security, you may want to specify hard-coded values for:
#   SHELL, PATH, HISTFILE, ENV, BASH_ENV
# They will be made read-only by set -r later in the script.
# -----------------------------------------------------------------------

# Populate this array with **all** commands used in the script for security.
# The following builtins do not need to be included, POSIX mode handles that:
# break : . continue eval exec exit export readonly return set shift trap unset
# The following keywords are also supposed not to be overridable in bash itself
# ! case  coproc  do done elif else esac fi for function if in
# select then until while { } time [[ ]]
# -----------------------------------------------------------------------------
UTILS=(
    '['
    '[['
    'awk'
    'cat'
    'command'
    'declare'
    'dialog'
    'echo'
    'false'
    'getopt'
    'hash'
    'local'
    'logger'
    'mktemp'
    'pgrep'
    'read'
    'readlink'
    'sudo'
    'tee'
    'true'
    'wget'
)

# Unset all commands used in the script - prevents exported functions
# from overriding them, leading to unexpected behavior
# -------------------------------------------------------------------
for util in "${UTILS[@]}"
do
    \unset -f -- "$util"
done

# Clear the command hash table
# ----------------------------
hash -r

# Set up fd 3 for discarding output, necessary for set -r
# -------------------------------------------------------
exec 3>/dev/null

# ----------------------------------------------------------
# Options description:
#   -o pipefail: exit on error in any part of pipeline
#   -eE:         exit on any error, go through error handler
#   -u:          exit on accessing uninitialized variable
#   -r:          set bash restricted mode for security
# The restricted mode option necessitates the usage of tee
# instead of simple output redirection when writing to files
# ----------------------------------------------------------
set -o pipefail -eEur

## --------------------------------------------
## END OF SECURITY SECTION
## Make sure to populate the $UTILS array above
## --------------------------------------------

# Globals
# -------
DEBUG=${DEBUG:-"false"}
SCRIPTDIR=$(dirname "$(readlink -e -- "$0")")
LIB1="$SCRIPTDIR/../lib/sc30pkcs11-3.0.6.68-MS.so"
LIB2="$SCRIPTDIR/../lib/cryptoCertum3PKCS-3.0.6.65-MS.so"

# Generic error handling
# ----------------------
trap 'error_handler $? $LINENO' ERR

error_handler()
{
    trap - ERR
    err "Error: ($1) occurred on line $2"

    # Print part of code where error occured if DEBUG=true
    # ----------------------------------------------------
    if [ "$DEBUG" = "true" ]
    then
        # Save to variable to split by lines properly
        # shellcheck disable=SC2155,SC2086
        # -------------------------------------------
        local error_in_code=$(awk 'NR>L-4 && NR<L+4 { printf "%-5d%3s%s\n",NR,(NR==L?">>>":""),$0 }' L=$2 $0 )
        debug "$error_in_code"
    fi

    # Exit with caught error code
    # ---------------------------
    exit "$1"
}


# Print to stderr and user.debug
# ------------------------------
debug()
{
    if [ "$DEBUG" = "true" ]
    then
        echo "$@" | tee /dev/fd/2 | logger --priority user.debug --tag "$0"
    fi
}


# Print to stderr and user.info
# -----------------------------
inform()
{
    echo "$@" | tee /dev/fd/2 | logger --priority user.info --tag "$0"
}


# Print to stderr and user.warn
# -----------------------------
warn()
{
    echo "$@" | tee /dev/fd/2 | logger --priority user.warning --tag "$0"
}


# Print to stderr and user.err
# ----------------------------
err()
{
    echo "$@" | tee /dev/fd/2 | logger --priority user.err --tag "$0"
}


# Simple yes/no prompt
# --------------------
yes_or_no()
{
    while true
    do
        read -r -p "$* [y/n]: " yn
        case $yn in
            [Yy]*) return 0  ;;
            [Nn]*) err "Aborted" ; return 1 ;;
        esac
    done
}


# Declare variables for Debian 12
# -------------------------------
declare_debian_12()
{
    declare -g TOOLS
    declare -g SMARTCARD_SERVICE
    declare -g INSTALL_CMD
    SMARTCARD_SERVICE="pcscd.service"
    TOOLS=(
        'libacsccid1'
        'opensc'
        'libengine-pkcs11-openssl'
        'pcsc-tools'
    )
    INSTALL_CMD='sudo apt install -y'
    INSTALLED_PKGS="$(sudo apt list --installed 2>&3)"
}


# Choose what to treat the current OS as being like
# -------------------------------------------------
choose_alt_os()
{
    local oses=(
        'Debian 12'
        'Ubuntu 22.10'
        'Ubuntu 22.04'
        'Linux Mint 21'
    )

    echo "Select the OS that most closely resembles your current OS:"
    select os in "${oses[@]}"
    do
        case "$os" in
            'Debian 12')
                OS_ID='debian'
                OS_VERSION_ID='"12"'
                ;;
            'Ubuntu 22.10')
                OS_ID='ubuntu'
                OS_VERSION_ID='"22.10"'
                ;;
            'Ubuntu 22.04')
                OS_ID='ubuntu'
                OS_VERSION_ID='"22.04"'
                ;;
            'Linux Mint 21')
                OS_ID='linuxmint'
                OS_VERSION_ID='"21"'
                ;;

        esac
        break
    done

    return
}

# Check operating system and set variables in accordance with the supported OS
# ----------------------------------------------------------------------------
check_os()
{
    # Get the correct os-release file
    # -------------------------------
    if [ -r /etc/os-release ]
    then
        OS_RELEASE='/etc/os-release'
    elif [ -r /usr/lib/os-release ]
    then
        OS_RELEASE='/usr/lib/os-release'
    else
        err "Failed to get OS information"
        exit 1
    fi

    # Get OS_ID and OS_VERSION_ID from the os-release file
    # -----------------------------------------------------
    declare -g OS_ID
    declare -g OS_VERSION_ID
    OS_ID="$(grep -Po '(?<=^ID=)[^$]+$' < "$OS_RELEASE" || true)"
    OS_VERSION_ID="$(grep -Po '(?<=^VERSION_ID=)[^$]+$' < "$OS_RELEASE" || true)"

    # If grep did not match a variable, set it so -u does not kill the script
    # -----------------------------------------------------------------------
    [ -z "$OS_ID" ] && OS_ID='unsupported'
    [ -z "$OS_VERSION_ID" ] && OS_VERSION_ID='unsupported'

    while : :
    do
        debug "$OS_ID" "$OS_VERSION_ID"

        # Check OS compatibility
        # ----------------------
        case "$OS_ID" in
            "debian")
                case "$OS_VERSION_ID" in
                    '"12"')
                        debug "Detected OS: Debian 12"
                        declare_debian_12
                        break
                        ;;
                    *)
                        err "Unsupported OS version!"
                        if yes_or_no "Do you want to proceed regardless?"
                        then
                            choose_alt_os
                        else
                            exit 2
                        fi
                        ;;
                esac
                ;;
            "ubuntu")
                case "$OS_VERSION_ID" in
                    '"22.04"')
                        debug "Detected OS: Ubuntu 22.04"
                        declare_debian_12
                        break
                        ;;
                    '"22.10"')
                        debug "Detected OS: Ubuntu 22.10"
                        declare_debian_12
                        break
                        ;;
                    *)
                        err "Unsupported OS version!"
                        if yes_or_no "Do you want to proceed regardless?"
                        then
                            choose_alt_os
                        else
                            exit 2
                        fi
                        ;;
                esac
                ;;
            "linuxmint")
                case "$OS_VERSION_ID" in
                    '"21"')
                        debug "Detected OS: Linux Mint 21"
                        declare_debian_12
                        break
                        ;;
                    *)
                        err "Unsupported OS version!"
                        if yes_or_no "Do you want to proceed regardless?"
                        then
                            choose_alt_os
                        else
                            exit 2
                        fi
                        ;;
                esac
                ;;
            *)
                err "Unsupported OS!"
                if yes_or_no "Do you want to proceed regardless?"
                then
                    choose_alt_os
                else
                    exit 2
                fi
                ;;
        esac
    done
}


# Check the environment the script is running in
# ----------------------------------------------
check_environment()
{
    # Check available utilities
    # -------------------------
    for util in "${UTILS[@]}"
    do
        if ! command -v -- "$util" >&3
    then
        err "This script requires $util to be installed and in PATH!"
        if [ "$util" = "dialog" ]
        then
            if yes_or_no "Do you want to install it now?"
            then
                eval "$INSTALL_CMD" dialog
            else
                exit 2
            fi
        else
            exit 2
        fi
    fi
    done

    return 0
}


# Check whether any of the smartcard tools are missing
# ----------------------------------------------------
check_tools_installed()
{
    for tool in "${TOOLS[@]}"
    do
        if ! echo "$INSTALLED_PKGS" | grep "$tool" >&3 2>&3
        then
            warn "Smartcard utilities are not installed correctly"
            return 1
        fi
    done

    debug "All smartcard packages are installed correctly"

    # Check whether the libraries are available
    # -----------------------------------------
    if [ -r "$LIB1" ] && [ -r "$LIB2" ]
    then
        debug "Libraries are installed correctly"
        debug "LIB1: $LIB1"
        debug "LIB2: $LIB2"
    else
        err "Certum libraries cannot be found in $SCRIPTDIR/lib"
        err "Please make sure you have cloned the whole repository"

        dialog --msgbox \
            "Certum libraries were not found in $SCRIPTDIR/../lib.\
            Make sure you have cloned the whole repository." \
            0 0

        exit 2
    fi

    # If we've reached this point, it's all good
    # ------------------------------------------
    debug "All tools are installed correctly"
    return 0
}


# Check whether the smartcard manager service is running
# ------------------------------------------------------
check_tools_running()
{
    # Sysvinit is dead, long live systemd
    # -----------------------------------
    if sudo systemctl --no-pager status "$SMARTCARD_SERVICE" 1>&3
    then
        debug "Smartcard service is running"
        return 0
    else
        warn "Smartcard service is not running"
        return 1
    fi
}


# Ask whether to install certum utilities
# ---------------------------------------
ask_install_tools()
{
    dialog --yesno "Smartcard utilities do not seem to be installed, do you want to install them now?" \
           0 0
    return $?
}


# Ask whether to start certum services
# ------------------------------------
ask_run_tools()
{
    dialog --yesno "Smartcard utilities do not seem to be running, do you want to start them now?" \
           0 0
    return $?
}


# Install the needed smartcard utility packages
# ---------------------------------------------
install_tools()
{
    # Install the required packages
    # -----------------------------
    if ! eval "$INSTALL_CMD" "${TOOLS[*]}"
    then
        return 1
    fi

    # Check whether openssl detects the pkcs11 engine
    # -----------------------------------------------
    openssl engine pkcs11 2>&3 || return 1

    return 0
}


# Start the smartcard management service
# --------------------------------------
run_tools()
{
    # Sysvinit is dead, long live systemd
    # -----------------------------------
    sudo systemctl start "$SMARTCARD_SERVICE" || return 1
    return 0
}


# Display the main menu of the script
# -----------------------------------
main_menu()
{
    selection=$(dialog --cancel-label "Exit" \
                       --title "Main menu" \
                       --menu "What would you like to do today?" \
                       0 0 0 \
                       1 "Show slots" \
                       2 "List available mechanisms" \
                       3 "Generate keypair" \
		       4 "List keys on card" \
		       5 "Get public key from card" \
                       0 "Delete ALL objects from card" \
                       4>&1 1>&2 2>&4 \
                || true)

    debug "Selection: $selection"

    echo "$selection"
    return 0
}


# Get PIN from user
# -----------------
get_pin()
{
    local password
    password=$(dialog --stdout \
                      --title "Enter PIN" \
                      --insecure \
                      --passwordbox "Please enter your PIN:" 10 10 \
              || return 1)
    echo "$password"
}


# List available slots
# --------------------
list_slots()
{
    dialog --title "Slots" \
           --msgbox "$(pkcs11-tool --module "$LIB1" --list-slots)" \
           0 0 \
    || true

    return
}


# Unlock User PIN for current session
# -----------------------------------
card_login()
{
    local pin
    # Exit to main menu if pin was not provided
    # -----------------------------------------
    if ! pin=$(get_pin)
    then
        return 0
    fi
    pkcs11-tool --module "$LIB1" --unlock-pin --pin "$pin"

    dialog --msgbox "Operation completed successfully!" \
           0 0
}


# Delete all keys and other objects from card
# -------------------------------------------
delete_all_objects()
{
    # PlEasE tYpE "IAMsuReWhatIAMdoIng" to COnfIrm
    # --------------------------------------------
    dialog --no-label "No" \
           --yes-label "Yes" \
           --default-button "no" \
           --yesno "Are you sure you want to continue? This will delete ALL objects (keys, certificates) on the card" \
           0 0 \
    || return 0


    local pin
    # Exit to main menu if pin was not provided
    # -----------------------------------------
    if ! pin=$(get_pin)
    then
        return 0
    fi

    # Read labels of all objects to be deleted
    # ----------------------------------------
    declare -a labels
    readarray -t labels < <(pkcs11-tool --module "$LIB1" --list-objects \
                            --pin "$pin" \
                            | grep -E '^\s+label:\s+.+$' \
                            | awk '{for(i=2;i<=NF;++i)printf $i""FS ; print ""}')


    local progress
    progress=0
    # Delete all objects matching the given labels
    # --------------------------------------------
    for label in "${labels[@]}"
    do
        # Progressbar
        # -----------
        echo $(( progress * 100 / ${#labels[@]} )) \
            | dialog --title "Deletion progress" \
                     --gauge "Please wait, deleting objects…" \
                     6 60 0
        progress=$(( progress + 1 ))

        # Cut trailing newlines and spaces
        # --------------------------------
        label=$(echo "$label" | awk '{$1=$1;print}')

        # Delete all possible types of objects with a label
        # -------------------------------------------------
        for type in cert data privkey pubkey secrkey
        do
           pkcs11-tool --delete-object --label="$label" --module="$LIB1" \
                       --pin="$pin" --type="$type" >&3 2>&3 \
           || true
        done
    done

    # All done!
    # ---------
    dialog --msgbox "Operation completed successfully!" \
           0 0
    return 0
}


# Generate keypair
# ----------------
generate_keypair()
{
    # Define dialog fields
    # --------------------
    local fields=(
        "Key type" 1 1 "rsa:2048" 1 30 40 0
        "Label" 2 1 "" 2 30 40 0
    )

    # Display dialog
    # --------------
    exec 4>&1
    params=$(dialog --title "Generate keys" \
                    --form "Parameters" \
                    12 64 0 \
                    "${fields[@]}" \
                    2>&1 1>&4 || true)
    exec 4>&-

    # Get parameters from dialog result, exit to main menu on empty
    # -------------------------------------------------------------
    if ! { read -r key_type && read -r label; } <<< "${params}"
    then
        err "Arguments must be non-empty!"
        dialog --msgbox "Arguments must be non-empty!" \
               0 0
        return 0
    fi

    local pin
    # Exit to main menu if pin was not provided
    # -----------------------------------------
    if ! pin=$(get_pin)
    then
        return 0
    fi

    # Unlock card, perform keypair generation
    # ---------------------------------------
    local output
    if ! output="$(pkcs11-tool --module "$LIB1" --keypair --key-type "$key_type" \
                 --label "$label" --pin "$pin" 2>&1)"
    then
        # Handle "out of space" errors
        # ----------------------------
        if echo "$output" | grep 'CKR_DEVICE_MEMORY'
        then
            err "Card memory full! Please delete something from a slot to free up memory!"
            dialog --msgbox "Card memory full! Please delete something from a slot to free up memory!" \
                   0 0
        else
            err "Unexpected error occured: $output"
            dialog --msgbox "Unexpected error occured: $output" \
                   0 0
        fi
    else
        dialog --msgbox "Operation completed successfully!" \
               0 0
    fi
    return 0
}


# List key types avaiable for current token
# -----------------------------------------
list_key_types()
{
    dialog --title "Available key types" \
           --msgbox "$(pkcs11-tool --module "$LIB1" -M)" \
           0 0 \
    || true

    return
}

# List actual keys stored on the card
# -----------------------------------
list_card_keys()
{
    if ! pin=$(get_pin)
    then
	return 0
    fi

    dialog --title "Keys on card" \
           --msgbox "$(pkcs11-tool --module "$LIB1" --list-objects --pin "$pin")" \
	   0 0 \
    || true

    return
}

# Get specific key
# ----------------
get_pubkey()
{
    # Get PIN and key to show
    # -----------------------
    if ! pin=$(get_pin)
    then
	return 0
    fi

    local label=$(dialog --stdout \
	                 --title "Key label" \
                         --inputbox "Provide key name:" \
                         0 0 \
		 || return 1)

    # Display key value
    # -----------------
    dialog --title "Key value" \
           --msgbox "$(pkcs11-tool --module "$LIB1" --read-object --type pubkey --label "$label")" \
	   0 0 \
    || true

    return
}


# Main program functionality
# --------------------------
main()
{
    # Check-ask-do logic for certum installation
    # ------------------------------------------
    if ! check_tools_installed
    then
        if ask_install_tools
        then
            if ! install_tools
            then
                err "Something went wrong while trying to install smartcard tools"
                exit 1
            fi
        else
            err "Cannot continue without installing smartcard tools!"
            exit 3
        fi
    fi

    # Check-ask-do logic for certum service status
    # --------------------------------------------
    if ! check_tools_running
    then
        if ask_run_tools
        then
            if ! run_tools
            then
                err "Something went wrong trying to run smartcard utilities!"
                exit 1
            fi
        else
            err "Cannot continue without certum service running!"
            exit 3
        fi
    fi

    while : :
        do
        # Check whether reader is available
        # ---------------------------------
        if pcsc_scan -r | grep -q "No reader found."
        then
            dialog --no-label "Abort" \
                   --yes-label "Retry" \
                   --yesno "No card reader detected! Please plug one in and try again!" \
                   0 0 \
            || exit 0

            continue
        fi

        # Check whether a card is available
        # ---------------------------------
        if ! pcsc_scan -c | grep -q "Card inserted"
        then
            dialog --no-label "Abort" \
                   --yes-label "Retry" \
                   --yesno "No card detected! Please insert one and try again!" \
                   0 0 \
            || exit 0

            continue
        fi

        # Show main menu
        # --------------
        case "$(main_menu)" in
            1)
                list_slots
                ;;
            2)
                list_key_types
                ;;
            3)
                generate_keypair
                ;;
	    4)
		list_card_keys
		;;
	    5)
		get_pubkey
		;;
            0)
                delete_all_objects
                ;;
            *)
                exit 0
                ;;
        esac
    done
    return
}

check_os
check_environment
main "$@"


## END OF FILE #################################################################
# vim: set tabstop=4 softtabstop=4 expandtab shiftwidth=4 smarttab:
# End:
