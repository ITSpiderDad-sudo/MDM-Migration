# MDM-Migration
macOS MDM Migration
This project provides an automated, user-guided workflow for repairing or migrating macOS device management enrollment through Jamf Pro.
The script performs preflight network and VPN checks, ensures the required PSEUDO component is available, temporarily grants and verifies local administrator access when necessary, launches the native macOS MDM enrollment renewal workflow, validates the resulting enrollment, restores the user's original administrator state, and hands off to the Platform SSO workflow.
The workflow uses swiftDialog to guide the user through required actions and maintains detailed logging for troubleshooting. It also includes cleanup handling designed to remove temporary administrator privileges if the workflow succeeds, fails, is canceled, or is interrupted, while preserving accounts that were administrators before the process began. ]
Key features
* Jamf Pro policy execution
* User-guided MDM enrollment renewal
* swiftDialog interface
* Configurable blocked network prefixes through Jamf Parameter 4
* GlobalProtect/VPN connectivity checks
* Direct Apple enrollment service connectivity validation
* Automatic PSEUDO installation policy trigger through Parameter 5
* Temporary local administrator elevation
* Multiple independent administrator membership verification methods
* Automatic privilege cleanup and verification
* Native profiles renew -type enrollment workflow
* Post-enrollment MDM status validation
* Jamf username reassignment through inventory update
* Platform SSO configuration readiness detection