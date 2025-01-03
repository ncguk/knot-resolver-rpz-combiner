#!/usr/bin/sh

################################################################################
# rpz_blocklist_combiner.sh
# Version: 1.0.8 Knot-resolver (for Ubuntu/Debian)
# An amateurish shell script to download, make consistent, and merge RPZ
# blocklists for Knot Resolver, deleting duplicate entries. Now with user
# allowlisting and user blocklisting, oo-ee.
################################################################################

# Uncomment for debug output
#set -x

# Eat your variables
readonly CURL="/usr/bin/curl"
readonly DATE="/usr/bin/date"
readonly GREP="/usr/bin/grep"
readonly MV="/usr/bin/mv"
readonly SED="/usr/bin/sed"
readonly SORT="/usr/bin/sort"

readonly RESOLVER_CONF_DIR="/etc/knot-resolver/blocklist_combiner"

# More lists can be added in .rpz format, but are not guaranteed to work
readonly LIST_URL_01="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/rpz/ultimate.txt"
readonly LIST_URL_02="https://big.oisd.nl/rpz"
readonly LIST_URL_03="https://raw.githubusercontent.com/badmojr/1Hosts/master/Pro/rpz.txt"
readonly LIST_URL_04="https://urlhaus.abuse.ch/downloads/rpz/"

readonly LIST_TMPFILE="$RESOLVER_CONF_DIR/blocklist_combined.tmp"

readonly USER_ALLOWLIST="$RESOLVER_CONF_DIR/user_allowlist.txt"
readonly USER_BLOCKLIST="$RESOLVER_CONF_DIR/user_blocklist.txt"

readonly LIST_COMBINED="$RESOLVER_CONF_DIR/blocklist_combined.rpz"

# RPZ header serial number = seconds since the UNIX Epoch (1970-01-01 00:00 UTC)
RPZ_HEADER_SERIAL=$($DATE +"%s")
readonly RPZ_HEADER_LINE="\$TTL 300\\n@ SOA localhost. root.localhost. $RPZ_HEADER_SERIAL 43200 3600 86400 120\\n  NS  localhost.\\n"

###########################
## Start doing the thing ##
###########################

# Check if a combined blocklist exists and, if so, make a backup
if test -f "${LIST_COMBINED}"; then
    (>&2 printf "Found existing combined blocklist, making backup...\n")
    "$MV" "${LIST_COMBINED}" "${LIST_COMBINED}.backup"
fi

# Fetch the blocklists
(>&2 printf "Downloading blocklists...\n")
"$CURL" --silent "${LIST_URL_01}" -o "${LIST_TMPFILE}" || { (>&2 printf "%s failed to download, exiting\n" "${LIST_URL_01}") ; exit 1; }
"$CURL" --silent "${LIST_URL_02}" >> "${LIST_TMPFILE}" || { (>&2 printf "%s failed to download, exiting\n" "${LIST_URL_02}") ; exit 1; }
"$CURL" --silent "${LIST_URL_03}" >> "${LIST_TMPFILE}" || { (>&2 printf "%s failed to download, exiting\n" "${LIST_URL_03}") ; exit 1; }
"$CURL" --silent "${LIST_URL_04}" >> "${LIST_TMPFILE}" || { (>&2 printf "%s failed to download, exiting\n" "${LIST_URL_04}") ; exit 1; }
(>&2 printf "Downloads complete...\n")

(>&2 printf "Formatting the combined blocklist...\n")

# Strip comments and any existing RPZ headers
"$SED" -i -E '/^(\;|\@|\$|.*NS).*$/d' ${LIST_TMPFILE} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${LIST_TMPFILE}") ; exit 1; }
# Strip inline comments from urlhaus list
"$SED" -i 's/\ \;\ .*//' ${LIST_TMPFILE} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${LIST_TMPFILE}") ; exit 1; }
"$SED" -i 's/\.\;\ .*/\./' ${LIST_TMPFILE} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${LIST_TMPFILE}") ; exit 1; }

# Add the wildcard domains to the urlhaus list
#if test -f "${LIST_TMPFILE_04}"; then
#    "$GREP" -E -v '^#|^$' ${LIST_TMPFILE_04} | while IFS= read -r URLHAUS_BLOCKLIST_ENTRY; do
#        printf "*.%s\n" "${URLHAUS_BLOCKLIST_ENTRY}" >> ${LIST_TMPFILE_04} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${LIST_TMPFILE_04}") ; exit 1; }
#    done
#fi

# Delete lines longer than 256 character to avoid a bug in Unbound (248 characters + the later added ' CNAME .')
"$SED" -i '/^.\{247\}./d' ${LIST_TMPFILE} || { (>&2 printf "Something went wrong checking line lengths, exiting\n") ; exit 1; }
"$SED" -i '/^\*\..\{247\}./d' ${LIST_TMPFILE} || { (>&2 printf "Something went wrong checking line lengths, exiting\n") ; exit 1; }

# Basic blocklist filtering
if test -f "${USER_BLOCKLIST}"; then
    (>&2 printf "Processing user blocklist...\n")
    "$GREP" -E -v '^#|^$' ${USER_BLOCKLIST} | while IFS= read -r USER_BLOCKLIST_ENTRY; do
        printf "*.%s CNAME .\n" "${USER_BLOCKLIST_ENTRY}" >> ${LIST_TMPFILE} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${USER_BLOCKLIST}") ; exit 1; }
        printf "%s CNAME .\n" "${USER_BLOCKLIST_ENTRY}" >> ${LIST_TMPFILE} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${USER_BLOCKLIST}") ; exit 1; }
    done
fi

# Basic allowlist filtering
if test -f "${USER_ALLOWLIST}"; then
    (>&2 printf "Processing user allowlist...\n")
    "$GREP" -E -v '^#|^$' ${USER_ALLOWLIST} | while IFS= read -r USER_ALLOWLIST_ENTRY; do
        "$SED" -i "/\*\."${USER_ALLOWLIST_ENTRY}"\ CNAME\ \./d" ${LIST_TMPFILE} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${USER_ALLOWLIST}") ; exit 1; }
        "$SED" -i "/"${USER_ALLOWLIST_ENTRY}"\ CNAME\ \./d" ${LIST_TMPFILE} || { (>&2 printf "Something went wrong processing %s, exiting\n" "${USER_ALLOWLIST}") ; exit 1; }
    done
fi

# Sort the list into a rough approximation of alphabetical order
(>&2 printf "Sorting the combined blocklist and removing duplicates...\n")
"$SORT" -o ${LIST_TMPFILE} --buffer-size=50% --parallel=4 -u -f ${LIST_TMPFILE} || { (>&2 printf "Something went wrong sorting the combined blocklist, exiting\n") ; exit 1; }

# Add the RPZ headers at the beginning of the file
(>&2 printf "Adding the RPZ headers...\n")
"$SED" -i "1s/^/$RPZ_HEADER_LINE/" "${LIST_TMPFILE}" || { (>&2 printf "Something went wrong adding the RPZ header, exiting\n") ; exit 1; }

# Move the .tmp file to the specified place
(>&2 printf "Finishing up...\n")
"$MV" "${LIST_TMPFILE}" "${LIST_COMBINED}" || { (>&2 printf "Moving the blocklist .tmp file to its final destination failed, exiting\n") ; exit 1; }