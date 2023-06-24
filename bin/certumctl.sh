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
# Version: 0.0.1
# --------------

# ----------------------------------------------------------------------------
# This is a 'simple' bash and dialog-based script to help you deal with Certum
# smartcards without having to pull your remaining hair out. So far the
# following OSes are supported:
#   Debian 12
# --------------------
# Exit code listing:
#   0: All good
#   1: Unspecified
#   2: Error in environment configuration or arguments
#   3: Runtime requirements not satisfied
# ----------------------------------------------------------------------------

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
DEBUG="true"
# CCTLDIR="$HOME/.local/share/certumctl"
SCRIPTDIR=$(dirname "$(readlink -e -- "$0")")
LIB1="$SCRIPTDIR/lib/sc30pkcs11-3.0.6.68-MS.so"
LIB2="$SCRIPTDIR/lib/cryptoCertum3PKCS-3.0.6.65-MS.so"

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
        exit 2
    fi

    # Get OS_ID and OS_VERSIONI_ID from the os-release file
    # -----------------------------------------------------
    OS_ID="$(grep -Po '(?<=^ID=)[^$]+$' < "$OS_RELEASE")"
    OS_VERSION_ID="$(grep -Po '(?<=^VERSION_ID=)[^$]+$' < "$OS_RELEASE")"

    # If grep did not match a variable, set it so -u does not kill the script
    # -----------------------------------------------------------------------
    [ -z "$OS_ID" ] && OS_ID='unsupported'
    [ -z "$OS_VERSION_ID" ] && OS_VERSION_ID='unsupported'

    debug "$OS_ID" "$OS_VERSION_ID"

    # Check OS compatibility
    # ----------------------
    case "$OS_ID" in
        "debian")
            case "$OS_VERSION_ID" in
                '"12"')
                    debug "Detected OS: Debian 12"
                    declare_debian_12
                    ;;
                *)
                    err "Unsupported OS version!"
                    exit 2
                    ;;
            esac
            ;;
        *)
            err "Unsupported OS!"
            exit 2
            ;;
    esac
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

    # # Make config dir
    # # ---------------
    # if ! mkdir -p "$CCTLDIR"
    # then
        # err "Error making directory: $CCTLDIR, cannot proceed!"
        # return 2
    # fi

    return 0
}


# Check whether any of the smartcard tools are missing
# ----------------------------------------------------
check_tools_installed()
{
    for tool in "${TOOLS[@]}"
    do
        if ! echo "$INSTALLED_PKGS" | grep -q "$tool"
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
        err "Certum libraries cannot be found in $SCRIPTDIR/lib!"
        err "Please make sure you have cloned the whole repository"
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
                       2 "Generate keypair" \
                       3 "Log into the card" \
                       4 "Nothing" \
                       5 "Nothing" \
                       6 "Nothing" \
                       7 "Nothing" \
                       8 "Nothing" \
                       3>&1 1>&2 2>&3 \
                || true)

    debug "Selection: $selection"

    echo "$selection"
    return 0
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
                true
                ;;
            2)
                true
                ;;
            3)
                true
                ;;
            4)
                true
                ;;
            5)
                true
                ;;
            6)
                true
                ;;
            7)
                true
                ;;
            8)
                true
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
