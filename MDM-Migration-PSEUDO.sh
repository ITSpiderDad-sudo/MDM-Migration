#!/bin/bash

###############################################################################
# Company Management Enrollment Renewal
# Repair-style PSEUDO / Parameter 5 build
#
# Intended execution:
#   Jamf Pro policy running as root
#
# Requirements:
#   swiftDialog installed at /usr/local/bin/dialog
#
# Workflow:
#   1. Show directions
#   2. Require an allowed Wi-Fi network (Jamf Parameter 4)
#   3. Ensure PSEUDO is installed (Jamf Parameter 5 custom event, if needed)
#   3. Require GlobalProtect VPN to be disconnected by the user
#   4. Verify direct internet access
#   5. Add temporary local admin rights if needed
#   3. Require multiple admin verification checks to pass
#   4. Close the preparation dialog
#   5. Launch the macOS enrollment workflow
#   6. Wait for explicit user confirmation
#   7. Validate enrollment silently
#   8. Remove temporary admin rights
#   9. Verify admin removal
#  10. Display the final result
###############################################################################

PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly DIALOG="/usr/local/bin/dialog"
readonly LOG_FILE="/var/log/management-enrollment-renewal.log"
readonly COMMAND_FILE="/var/tmp/management-enrollment-renewal-dialog.log"
readonly BLOCKED_NETWORKS="${4:-}"
readonly PSEUDO_INSTALL_TRIGGER="${5:-}"
readonly NETWORK_CHECK_URL="https://iprofiles.apple.com"

readonly ADMIN_VERIFY_ATTEMPTS=15
readonly ADMIN_VERIFY_INTERVAL=2

loggedInUser=""
loggedInUID=""
loggedInGID=""

userWasAlreadyAdmin="false"
temporaryAdminAdded="false"
progressDialogPID=""

###############################################################################
# Logging
###############################################################################

logMessage() {
    local message="$1"

    /bin/echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') | ${message}" \
        >> "$LOG_FILE"
}

###############################################################################
# Run a GUI application as the active console user
###############################################################################

runAsUser() {
    /bin/launchctl asuser "$loggedInUID" \
        /usr/bin/sudo -H -u "$loggedInUser" "$@"
}


###############################################################################
# Network Prefix Validation
#
# Parameter 4 examples:
#   10.144.
#   10.144.,10.145.,10.146.
###############################################################################

getCurrentNetworkAddress() {

    /usr/sbin/ipconfig getifaddr en0 2>/dev/null
}

networkPrefixBlocked() {

    local currentIP="$1"
    local blockedPrefix=""
    local oldIFS="$IFS"

    [[ -z "$currentIP" || -z "$BLOCKED_NETWORKS" ]] && return 1

    IFS=','

    for blockedPrefix in $BLOCKED_NETWORKS; do

        blockedPrefix="$(
            /bin/echo "$blockedPrefix" | \
            /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
        )"

        if [[ "$currentIP" == "$blockedPrefix"* ]]; then
            IFS="$oldIFS"
            return 0
        fi
    done

    IFS="$oldIFS"
    return 1
}

waitForAllowedNetwork() {

    local currentIP=""
    local dialogResult=0

    logMessage "Blocked network prefixes: [${BLOCKED_NETWORKS}]"

    if [[ -z "$BLOCKED_NETWORKS" ]]; then
        logMessage "No blocked network prefixes supplied."
        return 0
    fi

    while true; do

        currentIP="$(getCurrentNetworkAddress)"

        logMessage "Detected network address: [${currentIP}]"

        if [[ -z "$currentIP" ]]; then

            showFailureDialog "The current network address could not be determined.

Please verify network connectivity and try again."

            return 1
        fi

        #######################################################################
        # HARD BLOCK
        #######################################################################

        if networkPrefixBlocked "$currentIP"; then

            logMessage "BLOCKED NETWORK DETECTED: ${currentIP}"

            runAsUser "$DIALOG" \
                --title "Network Change Required" \
                --message "Current Network Address:

${currentIP}

This network cannot be used for the management refresh.

Connect to an approved network and select Check Again." \
                --icon "SF=wifi.exclamationmark,color=orange" \
                --button1text "Check Again" \
                --button2text "Cancel" \
                --position "center" \
                >/dev/null 2>&1

            dialogResult=$?

            if [[ "$dialogResult" -ne 0 ]]; then

                logMessage "User canceled while on blocked network."

                return 1
            fi

            /bin/sleep 2

            continue
        fi

        #######################################################################
        # PASSED
        #######################################################################

        logMessage "Network validation passed: ${currentIP}"

        return 0
    done
}

logVPNDiagnostics() {
    logMessage "===== VPN DIAGNOSTICS ====="
    {
        /bin/echo "----- scutil --nc list -----"
        /usr/sbin/scutil --nc list
        /bin/echo
        /bin/echo "----- default route -----"
        /sbin/route -n get default
        /bin/echo
        /bin/echo "----- GlobalProtect processes -----"
        /bin/ps -axo pid,user,command | \
            /usr/bin/grep -E '[G]lobalProtect|[P]anGPA|[P]anGPS'
        /bin/echo
        /bin/echo "----- IPv4 utun routes -----"
        /usr/sbin/netstat -rn -f inet | /usr/bin/grep 'utun'
    } >>"$LOG_FILE" 2>&1
    logMessage "===== END VPN DIAGNOSTICS ====="
}

vpnIsConnected() {
    local ncStatus=""
    local defaultInterface=""

    # Check configured Network Configuration VPN services for a connected
    # GlobalProtect/Palo Alto service. The client may remain running while
    # disconnected, so process presence is diagnostic only.
    ncStatus="$(/usr/sbin/scutil --nc list 2>/dev/null)"
    if /bin/echo "$ncStatus" | \
        /usr/bin/grep -Eiq '\(Connected\).*(GlobalProtect|Palo Alto|PaloAlto)|\*(Connected\).*(GlobalProtect|Palo Alto|PaloAlto)'; then
        logMessage "VPN detection: scutil reports a connected GlobalProtect service."
        return 0
    fi

    # A full-tunnel VPN normally installs a utun default route.
    defaultInterface="$(/sbin/route -n get default 2>/dev/null | \
        /usr/bin/awk '/interface:/{print $2; exit}')"
    if [[ "$defaultInterface" == utun* ]]; then
        logMessage "VPN detection: default route uses ${defaultInterface}."
        return 0
    fi

    logMessage "VPN detection: no connected GlobalProtect service or utun default route was found."
    return 1
}

waitForVPNDisconnect() {
    local dialogResult=0

    while true; do
        logVPNDiagnostics
        if ! vpnIsConnected; then
            logMessage "VPN readiness check passed."
            return 0
        fi

        logMessage "VPN readiness check failed because a VPN connection is active."
        runAsUser "$DIALOG" \
            --title "VPN Disconnect Required" \
            --message "GlobalProtect VPN is currently connected.\n\nDisconnect GlobalProtect, remain connected to an approved network, then select **Check Again**.\n\nThe management refresh cannot continue while VPN is active." \
            --icon "SF=lock.shield.fill,color=orange" \
            --button1text "Check Again" \
            --button2text "Cancel" \
            --position "center" \
            >/dev/null 2>&1
        dialogResult=$?
        if [[ "$dialogResult" -ne 0 ]]; then
            logMessage "The user canceled during VPN preflight."
            return 1
        fi
    done
}

verifyInternetAccess() {
    logMessage "Checking direct internet access."
    /usr/bin/curl --silent --show-error --location --head \
        --connect-timeout 10 --max-time 20 "$NETWORK_CHECK_URL" \
        >/dev/null 2>>"$LOG_FILE"
}

###############################################################################
# Create a swiftDialog command file
#
# The dialog runs as the logged-in user, so that user must be able to read the
# command file. A root-owned 600 file can prevent swiftDialog from receiving
# commands such as quit:.
###############################################################################

createDialogCommandFile() {
    /bin/rm -f "$COMMAND_FILE"
    /usr/bin/touch "$COMMAND_FILE"
    /usr/sbin/chown "${loggedInUID}:${loggedInGID}" "$COMMAND_FILE"
    /bin/chmod 600 "$COMMAND_FILE"

    logMessage "Created command file owned by UID ${loggedInUID}, GID ${loggedInGID}."
}

###############################################################################
# Send a command to swiftDialog
###############################################################################

dialogCommand() {
    local command="$1"

    if [[ -f "$COMMAND_FILE" ]]; then
        /bin/echo "$command" >> "$COMMAND_FILE"
    fi
}

###############################################################################
# Close the preparation progress dialog
#
# First requests a graceful close through the command file. If the process is
# still active, it terminates only the PID launched by this script.
###############################################################################

closeProgressDialog() {
    if [[ -f "$COMMAND_FILE" ]]; then
        dialogCommand "quit:"
        /bin/sleep 2
    fi

    if [[ -n "$progressDialogPID" ]] &&
       /bin/kill -0 "$progressDialogPID" 2>/dev/null; then

        logMessage "Progress dialog remained active after quit command. Terminating PID ${progressDialogPID}."

        /bin/kill "$progressDialogPID" 2>/dev/null || true
        /bin/sleep 1
    fi

    progressDialogPID=""
    /bin/rm -f "$COMMAND_FILE"
}

###############################################################################
# Display a failure message
#
# No --ontop option is used.
###############################################################################

showFailureDialog() {
    local failureMessage="$1"

    runAsUser "$DIALOG" \
        --title "Refresh Needs Attention" \
        --message "$failureMessage" \
        --icon "SF=exclamationmark.triangle.fill,color=orange" \
        --button1text "OK" \
        --position "center" \
        >/dev/null 2>&1
}

###############################################################################
# Log administrator and authentication diagnostics
###############################################################################

logAdminDiagnostics() {
    logMessage "===== ADMINISTRATOR MEMBERSHIP DIAGNOSTICS ====="

    {
        /bin/echo "Console user: ${loggedInUser}"

        /bin/echo
        /bin/echo "----- id -----"
        /usr/bin/id "$loggedInUser"

        /bin/echo
        /bin/echo "----- resolved group names -----"
        /usr/bin/id -Gn "$loggedInUser"

        /bin/echo
        /bin/echo "----- dsmemberutil -----"
        /usr/bin/dsmemberutil \
            checkmembership \
            -U "$loggedInUser" \
            -G admin

        /bin/echo
        /bin/echo "----- dseditgroup -----"
        /usr/sbin/dseditgroup \
            -o checkmember \
            -m "$loggedInUser" \
            admin

        /bin/echo
        /bin/echo "----- local admin GroupMembership -----"
        /usr/bin/dscl . \
            -read /Groups/admin \
            GroupMembership

        /bin/echo
        /bin/echo "----- secure token status -----"
        /usr/sbin/sysadminctl \
            -secureTokenStatus "$loggedInUser"

    } >> "$LOG_FILE" 2>&1

    logMessage "===== END ADMINISTRATOR MEMBERSHIP DIAGNOSTICS ====="
}

###############################################################################
# Administrator check 1: dsmemberutil
#
# Important:
# Do not search only for "is a member", because the result
# "is not a member" contains the same phrase.
###############################################################################

adminCheckDsmemberutil() {
    local result=""

    result=$(
        /usr/bin/dsmemberutil \
            checkmembership \
            -U "$loggedInUser" \
            -G admin 2>/dev/null
    )

    logMessage "dsmemberutil result: ${result}"

    if /bin/echo "$result" |
       /usr/bin/grep -Eiq "is not a member"; then

        return 1
    fi

    /bin/echo "$result" |
        /usr/bin/grep -Eiq "is a member of the group"
}

###############################################################################
# Administrator check 2: dseditgroup
###############################################################################

adminCheckDseditgroup() {
    local result=""

    result=$(
        /usr/sbin/dseditgroup \
            -o checkmember \
            -m "$loggedInUser" \
            admin 2>/dev/null
    )

    logMessage "dseditgroup result: ${result}"

    if /bin/echo "$result" |
       /usr/bin/grep -Eiq "^no|not a member"; then

        return 1
    fi

    /bin/echo "$result" |
        /usr/bin/grep -Eiq "^yes| is a member"
}

###############################################################################
# Administrator check 3: resolved group list
###############################################################################

adminCheckResolvedGroups() {
    /usr/bin/id -Gn "$loggedInUser" 2>/dev/null |
        /usr/bin/tr ' ' '\n' |
        /usr/bin/grep -Fxq "admin"
}

###############################################################################
# Require all administrator checks to succeed
###############################################################################

verifyAdminMembership() {
    local dsmemberutilCheck="failed"
    local dseditgroupCheck="failed"
    local resolvedGroupsCheck="failed"

    if adminCheckDsmemberutil; then
        dsmemberutilCheck="passed"
    fi

    if adminCheckDseditgroup; then
        dseditgroupCheck="passed"
    fi

    if adminCheckResolvedGroups; then
        resolvedGroupsCheck="passed"
    fi

    logMessage "Admin check, dsmemberutil: ${dsmemberutilCheck}"
    logMessage "Admin check, dseditgroup: ${dseditgroupCheck}"
    logMessage "Admin check, resolved groups: ${resolvedGroupsCheck}"

    if [[ "$dsmemberutilCheck" == "passed" ]] &&
       [[ "$dseditgroupCheck" == "passed" ]] &&
       [[ "$resolvedGroupsCheck" == "passed" ]]; then

        return 0
    fi

    return 1
}

###############################################################################
# Verify that all administrator checks report the user is not an admin
###############################################################################

verifyNotAdmin() {
    local stillAdmin="false"

    if adminCheckDsmemberutil; then
        logMessage "Removal check: dsmemberutil still reports admin membership."
        stillAdmin="true"
    fi

    if adminCheckDseditgroup; then
        logMessage "Removal check: dseditgroup still reports admin membership."
        stillAdmin="true"
    fi

    if adminCheckResolvedGroups; then
        logMessage "Removal check: resolved groups still contain admin."
        stillAdmin="true"
    fi

    if [[ "$stillAdmin" == "true" ]]; then
        return 1
    fi

    return 0
}

###############################################################################
# Wait for administrator membership to become visible
###############################################################################

waitForAdminMembership() {
    local attempt=1

    while (( attempt <= ADMIN_VERIFY_ATTEMPTS )); do
        logMessage "Administrator verification attempt ${attempt} of ${ADMIN_VERIFY_ATTEMPTS}."

        if verifyAdminMembership; then
            logMessage "All administrator membership checks passed."
            return 0
        fi

        /usr/bin/dscacheutil -flushcache >> "$LOG_FILE" 2>&1
        /bin/sleep "$ADMIN_VERIFY_INTERVAL"

        attempt=$((attempt + 1))
    done

    logMessage "ERROR: Administrator membership did not pass all checks."
    logAdminDiagnostics

    return 1
}

###############################################################################
# Add temporary administrator rights
###############################################################################

addTemporaryAdmin() {
    local addExitCode=0
    local fallbackExitCode=0

    logMessage "Adding ${loggedInUser} to the local admin group."

    /usr/sbin/dseditgroup \
        -o edit \
        -a "$loggedInUser" \
        -t user \
        admin >> "$LOG_FILE" 2>&1

    addExitCode=$?

    logMessage "dseditgroup add exit code: ${addExitCode}"

    /usr/bin/dscacheutil -flushcache >> "$LOG_FILE" 2>&1
    /bin/sleep 3

    if waitForAdminMembership; then
        temporaryAdminAdded="true"

        logMessage "Temporary administrator membership was added and verified."
        logAdminDiagnostics

        return 0
    fi

    ###########################################################################
    # Fallback membership method
    ###########################################################################

    logMessage "Primary membership operation did not pass verification."
    logMessage "Attempting explicit admin GroupMembership fallback."

    /usr/bin/dscl . \
        -append /Groups/admin \
        GroupMembership \
        "$loggedInUser" >> "$LOG_FILE" 2>&1

    fallbackExitCode=$?

    logMessage "dscl fallback exit code: ${fallbackExitCode}"

    /usr/bin/dscacheutil -flushcache >> "$LOG_FILE" 2>&1
    /bin/sleep 3

    if waitForAdminMembership; then
        temporaryAdminAdded="true"

        logMessage "Fallback administrator membership was added and verified."
        logAdminDiagnostics

        return 0
    fi

    logMessage "ERROR: Temporary administrator membership could not be verified."

    return 1
}

###############################################################################
# Remove temporary administrator rights
###############################################################################

removeTemporaryAdmin() {
    local removalExitCode=0
    local removalAttempt=1

    if [[ "$temporaryAdminAdded" != "true" ]]; then
        logMessage "No temporary administrator membership requires removal."
        return 0
    fi

    if [[ "$userWasAlreadyAdmin" == "true" ]]; then
        logMessage "The user was originally an administrator. No removal performed."
        temporaryAdminAdded="false"
        return 0
    fi

    if [[ -z "$loggedInUser" ]]; then
        logMessage "ERROR: Console username is unavailable during cleanup."
        return 1
    fi

    logMessage "Removing temporary administrator membership from ${loggedInUser}."

    /usr/sbin/dseditgroup \
        -o edit \
        -d "$loggedInUser" \
        -t user \
        admin >> "$LOG_FILE" 2>&1

    removalExitCode=$?

    logMessage "dseditgroup removal exit code: ${removalExitCode}"

    # Remove an explicitly added GroupMembership value if the fallback was used.
    /usr/bin/dscl . \
        -delete /Groups/admin \
        GroupMembership \
        "$loggedInUser" >> "$LOG_FILE" 2>&1 || true

    /usr/bin/dscacheutil -flushcache >> "$LOG_FILE" 2>&1
    /bin/sleep 3

    while (( removalAttempt <= ADMIN_VERIFY_ATTEMPTS )); do
        logMessage "Administrator removal verification attempt ${removalAttempt} of ${ADMIN_VERIFY_ATTEMPTS}."

        if verifyNotAdmin; then
            temporaryAdminAdded="false"

            logMessage "Temporary administrator membership removal verified."
            logAdminDiagnostics

            return 0
        fi

        /usr/bin/dscacheutil -flushcache >> "$LOG_FILE" 2>&1
        /bin/sleep "$ADMIN_VERIFY_INTERVAL"

        removalAttempt=$((removalAttempt + 1))
    done

    logMessage "ERROR: Temporary administrator removal could not be verified."
    logAdminDiagnostics

    return 1
}


  
###############################################################################
# Cleanup trap
#
# Temporary rights are removed if the script exits, fails, is canceled, or is
# interrupted. Pre-existing administrators are never demoted.
###############################################################################

cleanup() {
    local exitCode=$?

    trap - EXIT INT TERM HUP

    logMessage "Cleanup started with exit code ${exitCode}."

    closeProgressDialog

    if ! removeTemporaryAdmin; then
        logMessage "ERROR: Cleanup could not verify administrator removal."
        exitCode=1
    fi

    /bin/rm -f "$COMMAND_FILE"

    logMessage "Cleanup completed."
    logMessage "============================================================"

    exit "$exitCode"
}

trap cleanup EXIT INT TERM HUP

###############################################################################
# Require root execution
###############################################################################

if [[ "$EUID" -ne 0 ]]; then
    /bin/echo "This script must run as root."
    exit 1
fi

/usr/bin/touch "$LOG_FILE"
/bin/chmod 644 "$LOG_FILE"

logMessage "============================================================"
logMessage "Management enrollment renewal started."

###############################################################################
# Verify swiftDialog
###############################################################################

if [[ ! -x "$DIALOG" ]]; then
    logMessage "ERROR: swiftDialog was not found at ${DIALOG}."
    exit 1
fi

dialogVersion=$("$DIALOG" --version 2>/dev/null)
logMessage "swiftDialog version: ${dialogVersion:-unknown}"

###############################################################################
# Identify the active console user
###############################################################################

loggedInUser=$(
    /usr/sbin/scutil <<< "show State:/Users/ConsoleUser" |
        /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }'
)

case "$loggedInUser" in
    ""|"root"|"loginwindow"|"_mbsetupuser")
        logMessage "ERROR: No eligible interactive user is logged in."
        exit 1
        ;;
esac

loggedInUID=$(/usr/bin/id -u "$loggedInUser" 2>/dev/null)
loggedInGID=$(/usr/bin/id -g "$loggedInUser" 2>/dev/null)

if [[ -z "$loggedInUID" ]] || [[ -z "$loggedInGID" ]]; then
    logMessage "ERROR: Unable to determine UID or GID for ${loggedInUser}."
    exit 1
fi

if ! /usr/bin/id "$loggedInUser" >> "$LOG_FILE" 2>&1; then
    logMessage "ERROR: The console user account could not be resolved."
    exit 1
fi

logMessage "Console user: ${loggedInUser}"
logMessage "Console user UID: ${loggedInUID}"
logMessage "Console user GID: ${loggedInGID}"

###############################################################################
# Initial directions
###############################################################################

runAsUser "$DIALOG" \
    --title "Company Management Refresh" \
    --message "Your Mac needs to refresh its company management registration.

Before continuing:

* Save any open work
* Keep your Mac connected to the internet
* Remain signed in
* Complete every macOS enrollment prompt
* Use your normal Mac username and password if credentials are requested" \
    --icon "SF=gearshape.2.fill,color=accent" \
    --button1text "Continue" \
    --button2text "Later" \
    --position "center" \
    >/dev/null 2>&1

initialDialogResult=$?

if [[ "$initialDialogResult" -ne 0 ]]; then
    logMessage "The user deferred or closed the workflow."
    exit 0
fi

logMessage "The user selected Continue."

###############################################################################
# Ensure PSEUDO is present before enrollment begins
#
# Jamf Parameter 5:
#   Custom event for the policy that installs PSEUDO.
#
# Example:
#   pseudoauto
###############################################################################

logMessage "Verifying Platform SSO workflow availability."

if [[ ! -x "/usr/local/bin/pseudo" ]]; then

    logMessage "PSEUDO is not currently installed."

    ###########################################################################
    # Parameter 5 is required only when PSEUDO is missing.
    ###########################################################################

    if [[ -z "$PSEUDO_INSTALL_TRIGGER" ]]; then
        logMessage "ERROR: PSEUDO is missing and Jamf Parameter 5 is empty."

        showFailureDialog "The Platform SSO component is not installed and its installation policy is not configured.

Please contact the Service Desk for assistance."

        exit 1
    fi

    logMessage "Calling PSEUDO installation policy using custom event: ${PSEUDO_INSTALL_TRIGGER}"

    /usr/local/bin/jamf policy \
        -event "$PSEUDO_INSTALL_TRIGGER" \
        >> "$LOG_FILE" 2>&1

    pseudoInstallExitCode=$?

    logMessage "PSEUDO installation policy exit code: ${pseudoInstallExitCode}"

    if [[ "$pseudoInstallExitCode" -ne 0 ]]; then
        logMessage "ERROR: PSEUDO installation policy returned a nonzero exit code."

        showFailureDialog "The Platform SSO component could not be installed.

Please contact the Service Desk for assistance."

        exit 1
    fi

else

    logMessage "PSEUDO is already installed. Installation policy is not required."

fi

###############################################################################
# Verify PSEUDO installation
###############################################################################

attempt=1

while (( attempt <= 12 )); do

    if [[ -x "/usr/local/bin/pseudo" ]]; then
        logMessage "PSEUDO installation verified."
        break
    fi

    logMessage "Waiting for PSEUDO installation attempt ${attempt} of 12."

    /bin/sleep 5
    attempt=$((attempt + 1))
done

if [[ ! -x "/usr/local/bin/pseudo" ]]; then
    logMessage "ERROR: PSEUDO installation could not be verified."

    showFailureDialog "The Platform SSO component installation could not be verified.

Please contact the Service Desk for assistance."

    exit 1
fi

###############################################################################
# Preflight Validation
###############################################################################

if ! waitForAllowedNetwork; then
    exit 1
fi

if ! waitForVPNDisconnect; then
    exit 1
fi

if ! verifyInternetAccess; then

    logMessage "ERROR: Direct internet validation failed."

    showFailureDialog "The Apple enrollment service could not be reached.

Connect to an approved network and try again."

    exit 1
fi

logMessage "Direct internet validation passed."

###############################################################################
# Record original administrator status
###############################################################################

if verifyAdminMembership; then
    userWasAlreadyAdmin="true"
    logMessage "The user was already a verified local administrator."
else
    userWasAlreadyAdmin="false"
    logMessage "The user was not originally a verified local administrator."
fi

logAdminDiagnostics

###############################################################################
# Start preparation dialog
###############################################################################

createDialogCommandFile

runAsUser "$DIALOG" \
    --title "Preparing Management Refresh" \
    --message "Your Mac is being prepared for the company management refresh." \
    --icon "SF=gearshape.2.fill,color=accent" \
    --progress \
    --progresstext "Preparing your Mac..." \
    --button1disabled \
    --commandfile "$COMMAND_FILE" \
    --position "center" \
    >/dev/null 2>&1 &

progressDialogPID=$!

logMessage "Preparation dialog PID: ${progressDialogPID}"

/bin/sleep 2

###############################################################################
# Add temporary administrator rights
###############################################################################

dialogCommand "progresstext: Preparing your user account..."

if [[ "$userWasAlreadyAdmin" == "false" ]]; then
    if ! addTemporaryAdmin; then
        closeProgressDialog

        showFailureDialog "Your Mac could not be prepared for the company management refresh.

Administrator access could not be verified, so the enrollment process was not started.

Please contact the Service Desk for assistance."

        exit 1
    fi
fi

###############################################################################
# Mandatory pre-enrollment verification
###############################################################################

dialogCommand "progresstext: Verifying system readiness..."

logMessage "===== PRE-ENROLLMENT ADMIN CHECK ====="

if ! waitForAdminMembership; then
    logMessage "ERROR: Final administrator verification failed."
    logMessage "Enrollment will not be launched."
    logMessage "===== END PRE-ENROLLMENT ADMIN CHECK ====="

    closeProgressDialog

    showFailureDialog "Your Mac could not be prepared for the company management refresh.

Administrator access could not be verified, so the enrollment process was not started.

Please contact the Service Desk for assistance."

    exit 1
fi

logAdminDiagnostics

logMessage "All administrator checks passed immediately before enrollment."
logMessage "===== END PRE-ENROLLMENT ADMIN CHECK ====="

###############################################################################
# Close the preparation dialog before enrollment
###############################################################################

dialogCommand "progresstext: Starting the management refresh..."
/bin/sleep 1

closeProgressDialog
/bin/sleep 2

###############################################################################
# Launch enrollment
#
# The user is confirmed as an administrator before this command runs.
###############################################################################

logMessage "Launching profiles renew for ${loggedInUser}."

/bin/launchctl asuser "$loggedInUID" \
    /usr/bin/sudo -H -u "$loggedInUser" \
    /usr/bin/profiles renew -type enrollment \
    >> "$LOG_FILE" 2>&1

profilesExitCode=$?

logMessage "profiles renew launch exit code: ${profilesExitCode}"

if [[ "$profilesExitCode" -ne 0 ]]; then
    showFailureDialog "The management enrollment window could not be opened.

Confirm that your Mac is connected to the internet and try again.

Contact the Service Desk if the issue continues."

    exit 1
fi

###############################################################################
# Allow the enrollment interface to appear
###############################################################################

/bin/sleep 5

###############################################################################
# Wait for explicit user confirmation
#
# This dialog is not always on top and is positioned away from the center.
###############################################################################

runAsUser "$DIALOG" \
    --title "Complete Management Enrollment" \
    --message "Complete every enrollment step shown by macOS.

If credentials are requested:

1. Enter your normal Mac username and password
2. Complete any company sign-in prompts
3. Approve the management enrollment
4. Wait until macOS indicates the process is finished
5. Return to this window
6. Select **Enrollment Complete**

Do not select **Enrollment Complete** until all enrollment prompts are finished." \
    --icon "SF=person.badge.key.fill,color=accent" \
    --button1text "Enrollment Complete" \
    --button2text "Cancel" \
    --infobuttontext "Reopen Enrollment" \
    --position "bottomright" \
    >/dev/null 2>&1

completionDialogResult=$?

###############################################################################
# Reopen enrollment if requested
#
# Common swiftDialog exit codes:
#   0 = Button 1
#   2 = Button 2
#   3 = Info button
###############################################################################

if [[ "$completionDialogResult" -eq 3 ]]; then
    logMessage "The user requested that enrollment be reopened."

    if ! waitForAdminMembership; then
        logMessage "ERROR: Admin verification failed before reopening enrollment."

        showFailureDialog "Administrator access could no longer be verified.

The enrollment window was not reopened. Please contact the Service Desk."

        exit 1
    fi

    /bin/launchctl asuser "$loggedInUID" \
        /usr/bin/sudo -H -u "$loggedInUser" \
        /usr/bin/profiles renew -type enrollment \
        >> "$LOG_FILE" 2>&1

    reopenExitCode=$?

    logMessage "Reopen enrollment exit code: ${reopenExitCode}"

    if [[ "$reopenExitCode" -ne 0 ]]; then
        showFailureDialog "The management enrollment window could not be reopened.

Please contact the Service Desk for assistance."

        exit 1
    fi

    /bin/sleep 5

    runAsUser "$DIALOG" \
        --title "Complete Management Enrollment" \
        --message "Complete every remaining enrollment step.

Use your normal Mac username and password if credentials are requested.

After macOS indicates enrollment is finished, return here and select **Enrollment Complete**." \
        --icon "SF=person.badge.key.fill,color=accent" \
        --button1text "Enrollment Complete" \
        --button2text "Cancel" \
        --position "bottomright" \
        >/dev/null 2>&1

    completionDialogResult=$?
fi

###############################################################################
# Handle cancellation
###############################################################################

if [[ "$completionDialogResult" -ne 0 ]]; then
    logMessage "The user canceled or closed the completion dialog."

    showFailureDialog "The management refresh was not marked complete.

Temporary account changes will now be removed. You can start the refresh again from Self Service."

    exit 1
fi

logMessage "The user confirmed that all enrollment prompts were completed."

###############################################################################
# Reassign User & Location in Jamf
###############################################################################
logMessage "Submitting username back to Jamf."
/usr/local/bin/jamf recon \
-endUsername "$loggedInUser" \
>> "$LOG_FILE" 2>&1
reconExitCode=$?
logMessage "jamf recon exit code: ${reconExitCode}"

###############################################################################
# Validate enrollment silently
#
# No verification dialog is displayed, preventing an orphaned progress window.
###############################################################################

logMessage "Beginning silent enrollment validation."

enrollmentStatus=$(
    /usr/bin/profiles status -type enrollment 2>&1
)

enrollmentStatusExitCode=$?

compactEnrollmentStatus=$(
    /bin/echo "$enrollmentStatus" |
        /usr/bin/tr '\n' ' '
)

logMessage "profiles status exit code: ${enrollmentStatusExitCode}"
logMessage "Enrollment status: ${compactEnrollmentStatus}"

if /bin/echo "$enrollmentStatus" |
    /usr/bin/grep -Eiq 'MDM enrollment:[[:space:]]*Yes'; then

    enrollmentValid="true"
    logMessage "Current MDM enrollment status was verified."
else
    enrollmentValid="false"
    logMessage "ERROR: Current MDM enrollment status could not be verified."
fi

###############################################################################
# Remove temporary administrator rights
###############################################################################

adminRemovalSuccessful="true"

if [[ "$temporaryAdminAdded" == "true" ]]; then
    if ! removeTemporaryAdmin; then
        adminRemovalSuccessful="false"
    fi
fi
###############################################################################
# Launch Platform SSO Workflow
#
# Wait for the Extensible SSO configuration required by PSEUDO, not for
# Platform SSO registration to already be complete. PSEUDO owns registration.
###############################################################################

readonly PSSO_MANAGED_PREFERENCE="/Library/Managed Preferences/com.apple.extensiblesso.plist"
readonly PSSO_PROFILE_ATTEMPTS=60
readonly PSSO_PROFILE_INTERVAL=10

if [[ ! -x "/usr/local/bin/pseudo" ]]; then
    logMessage "ERROR: PSEUDO binary was not found at /usr/local/bin/pseudo."

    showFailureDialog "Your device management migration completed, but the company sign-in component is unavailable.

Please contact the Service Desk for assistance."

    exit 1
fi

logMessage "Waiting for the Platform SSO configuration required by PSEUDO."

attempt=1
extensionIdentifier=""
authenticationMethod=""
accountDisplayName=""

while (( attempt <= PSSO_PROFILE_ATTEMPTS )); do

    extensionIdentifier=""
    authenticationMethod=""
    accountDisplayName=""

    if [[ -r "$PSSO_MANAGED_PREFERENCE" ]]; then

        extensionIdentifier=$(
            /usr/bin/plutil -extract ExtensionIdentifier raw \
                "$PSSO_MANAGED_PREFERENCE" 2>/dev/null || true
        )

        authenticationMethod=$(
            /usr/bin/plutil -extract PlatformSSO.AuthenticationMethod raw \
                "$PSSO_MANAGED_PREFERENCE" 2>/dev/null || true
        )

        accountDisplayName=$(
            /usr/bin/plutil -extract PlatformSSO.AccountDisplayName raw \
                "$PSSO_MANAGED_PREFERENCE" 2>/dev/null || true
        )
    fi

    logMessage "Platform SSO profile attempt ${attempt} of ${PSSO_PROFILE_ATTEMPTS}: preferencePresent=$([[ -r "$PSSO_MANAGED_PREFERENCE" ]] && /bin/echo true || /bin/echo false), extensionIdentifier=[${extensionIdentifier}], authenticationMethod=[${authenticationMethod}], accountDisplayName=[${accountDisplayName}]."

    if [[ -n "$extensionIdentifier" ]] &&
       [[ -n "$authenticationMethod" ]] &&
       [[ -n "$accountDisplayName" ]]; then

        logMessage "Platform SSO configuration required by PSEUDO is available."
        break
    fi

    if (( attempt == 1 ||
          attempt == 15 ||
          attempt == 30 ||
          attempt == 45 ||
          attempt == PSSO_PROFILE_ATTEMPTS )); then

        logMessage "Capturing Platform SSO diagnostics at profile attempt ${attempt}."

        {
            /bin/echo "===== MANAGED PREFERENCE ====="

            if [[ -r "$PSSO_MANAGED_PREFERENCE" ]]; then
                /usr/bin/plutil -p "$PSSO_MANAGED_PREFERENCE"
            else
                /bin/echo "Managed preference is not present."
            fi

            /bin/echo
            /bin/echo "===== APP-SSO STATE ====="
            /usr/bin/app-sso platform -s 2>&1
            /bin/echo "===== END PLATFORM SSO DIAGNOSTICS ====="
        } >> "$LOG_FILE" 2>&1
    fi

    /bin/sleep "$PSSO_PROFILE_INTERVAL"
    attempt=$((attempt + 1))
done

if [[ -z "$extensionIdentifier" ]] ||
   [[ -z "$authenticationMethod" ]] ||
   [[ -z "$accountDisplayName" ]]; then

    logMessage "ERROR: Platform SSO configuration required by PSEUDO did not become available."
    logMessage "PSEUDO was not launched because ExtensionIdentifier, AuthenticationMethod, or AccountDisplayName was unavailable."

    showFailureDialog "Your device management migration completed, but the company sign-in configuration has not finished installing.

Please run this tool again from Self Service. Contact the Service Desk if the issue continues."

    exit 1
fi

logMessage "Launching Platform SSO workflow as root."

/usr/local/bin/pseudo \
    >> "$LOG_FILE" 2>&1

pseudoExitCode=$?

logMessage "Platform SSO workflow exited with code ${pseudoExitCode}."

if [[ "$pseudoExitCode" -ne 0 ]]; then
    logMessage "ERROR: Platform SSO workflow returned a nonzero exit code."

    showFailureDialog "Your device management migration completed, but company sign-in setup could not be completed.

Please run this tool again from Self Service. Contact the Service Desk if the issue continues."

    exit 1
fi

###############################################################################
# Final Success Dialog
###############################################################################

if [[ "$enrollmentValid" == "true" ]] &&
   [[ "$adminRemovalSuccessful" == "true" ]]; then

    logMessage "Management enrollment workflow completed successfully."

    runAsUser "$DIALOG" \
        --title "Refresh Complete" \
        --message "Your company management registration is active.


You may continue working normally." \
        --icon "SF=checkmark.circle.fill,color=green" \
        --button1text "OK" \
        --position "center" \
        >/dev/null 2>&1

    exit 0
fi


if [[ "$adminRemovalSuccessful" != "true" ]]; then
    logMessage "ERROR: Temporary administrator removal requires attention."

    showFailureDialog "The management refresh finished, but account cleanup could not be verified.

Please contact the Service Desk for assistance."

    exit 1
fi

logMessage "ERROR: Enrollment could not be validated."

showFailureDialog "The management enrollment could not be verified.

Confirm that your Mac is connected to the internet and try again.

Contact the Service Desk if the issue continues."

exit 1
