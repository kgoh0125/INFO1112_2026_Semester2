#!/bin/bash
set -u

# Install any missing dependencies (Alpine only; parent process only).
if [ "${1:-}" != "--handle" ]; then
    _need=""
    for _t in curl html2text socat python3 ifconfig ss; do
        command -v "$_t" >/dev/null 2>&1 || _need=1
    done
    if [ -n "$_need" ] && command -v apk >/dev/null 2>&1; then
        echo "Installing missing dependencies..."
        apk add --no-cache curl html2text socat python3 py3-matplotlib \
            net-tools iproute2 ca-certificates >/dev/null 2>&1
    fi
fi
poi_lookup() {
    local query="${1//[\"\\]/}"          # strip characters that would break JSON
    local radius="${POI_RADIUS:-1000}"   # search radius in metres
 
    awk -F'|' -v q="$query" -v radius="$radius" '
    function rad(x) { return x * 3.14159265358979 / 180 }
    function hav(la1, lo1, la2, lo2,   dla, dlo, a) {
        dla = rad(la2 - la1); dlo = rad(lo2 - lo1)
        a = sin(dla/2)^2 + cos(rad(la1)) * cos(rad(la2)) * sin(dlo/2)^2
        return 12742000 * atan2(sqrt(a), sqrt(1 - a))
    }
    NF == 4 { n++; nm[n] = $1; ct[n] = $2; la[n] = $3 + 0; lo[n] = $4 + 0 }
    END {
        gsub(/^[ \t]+|[ \t]+$/, "", q)
        oname = ""; olat = 0; olon = 0; found = 0; self = 0
        if (q ~ /^-?[0-9]+(\.[0-9]+)?[ \t]*,[ \t]*-?[0-9]+(\.[0-9]+)?$/) {
            split(q, c, /[ \t]*,[ \t]*/)
            olat = c[1] + 0; olon = c[2] + 0; oname = "coordinates"; found = 1
        } else {
            lq = tolower(q)
            for (i = 1; i <= n && !found; i++)
                if (tolower(nm[i]) == lq) { found = 1; self = i }
            for (i = 1; i <= n && !found; i++)
                if (lq != "" && index(tolower(nm[i]), lq)) { found = 1; self = i }
            if (found) { oname = nm[self]; olat = la[self]; olon = lo[self] }
        }
        if (!found) exit 2
 
        m = 0
        for (i = 1; i <= n; i++) {
            if (i == self) continue
            d = hav(olat, olon, la[i], lo[i])
            if (d <= radius) { m++; idx[m] = i; dist[m] = d }
        }
        # sort by distance (insertion sort)
        for (i = 2; i <= m; i++) {
            ti = idx[i]; td = dist[i]; j = i - 1
            while (j >= 1 && dist[j] > td) { idx[j+1] = idx[j]; dist[j+1] = dist[j]; j-- }
            idx[j+1] = ti; dist[j+1] = td
        }
 
        printf "{\n  \"query\": \"%s\",\n", q
        printf "  \"origin\": {\"name\": \"%s\", \"latitude\": %.6f, \"longitude\": %.6f},\n", oname, olat, olon
        printf "  \"radius_m\": %d,\n  \"count\": %d,\n  \"neighbours\": [", radius, m
        for (i = 1; i <= m; i++) {
            k = idx[i]
            printf "%s\n    {\"name\": \"%s\", \"category\": \"%s\", \"latitude\": %.6f, \"longitude\": %.6f, \"distance_m\": %d}", \
                (i > 1 ? "," : ""), nm[k], ct[k], la[k], lo[k], dist[i] + 0.5
        }
        printf "%s]\n}\n", (m ? "\n  " : "")
    }' <<'POI_DATA'
Sydney Opera House|landmark|-33.856800|151.215300
Royal Botanic Garden Sydney|park|-33.864200|151.216600
Sydney Harbour Bridge|landmark|-33.852300|151.210800
Circular Quay|transport|-33.861400|151.210600
The Rocks|neighbourhood|-33.859900|151.209000
Museum of Contemporary Art|museum|-33.859800|151.209300
Customs House|library|-33.862400|151.210800
Government House|landmark|-33.860700|151.215500
Sydney Conservatorium of Music|education|-33.864000|151.213200
Mrs Macquaries Chair|viewpoint|-33.859000|151.222400
Fort Denison|landmark|-33.854800|151.225000
Art Gallery of NSW|museum|-33.868800|151.217400
State Library of NSW|library|-33.865700|151.213300
Hyde Park Barracks|museum|-33.869600|151.213400
St Marys Cathedral|church|-33.871100|151.213200
Hyde Park|park|-33.873100|151.211100
Australian Museum|museum|-33.874500|151.213300
Martin Place|plaza|-33.867800|151.210800
Wynyard Station|transport|-33.866000|151.206000
Strand Arcade|shopping|-33.869700|151.209200
Pitt Street Mall|shopping|-33.870000|151.208500
Sydney Tower Eye|landmark|-33.870500|151.208900
Queen Victoria Building|shopping|-33.871900|151.206700
Sydney Town Hall|landmark|-33.873100|151.207000
Sydney Observatory|museum|-33.859400|151.204600
Barangaroo Reserve|park|-33.860000|151.200800
Cockle Bay Wharf|dining|-33.870000|151.201200
Pyrmont Bridge|landmark|-33.871400|151.200400
Sea Life Sydney Aquarium|attraction|-33.869100|151.202300
Australian National Maritime Museum|museum|-33.869300|151.198300
Darling Harbour|neighbourhood|-33.873100|151.198700
International Convention Centre Sydney|venue|-33.875000|151.199000
Chinatown|neighbourhood|-33.878500|151.204300
Paddys Markets Haymarket|market|-33.879600|151.203400
Powerhouse Museum|museum|-33.878600|151.199300
Central Station|transport|-33.883000|151.206000
University of Sydney|education|-33.888800|151.187300
Luna Park Sydney|attraction|-33.847900|151.210800
Taronga Zoo|attraction|-33.843300|151.241100
POI_DATA
}
 
# Handle one client connection.
if [ "${1:-}" = "--handle" ]; then
 
    # Identify the client's IP address.
    CLIENT_IP="${SOCAT_PEERADDR:-unknown}"
    CLIENT_IP="${CLIENT_IP%:*}"
    CLIENT_IP="${CLIENT_IP//[^a-zA-Z0-9_.-]/_}"
 
    # Display the client's IP address and port (as in Fig. 6).
    echo "Connection received on ${SOCAT_PEERADDR:-unknown} ${SOCAT_PEERPORT:-unknown}" >&2

    # Atomically acquire a lock for this client IP.
    LOCK_DIR="/tmp/info1112-lock-${CLIENT_IP}"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '{"error":"Another request from your IP is already being processed."}\n'
        exit 1
    fi
 
    # Release the lock when this handler exits.
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
 
    IFS= read -r REQUEST || exit 1
 
    REQUEST=${REQUEST%$'\r'}
 
    echo "Request: $REQUEST" >&2
 
    case "$REQUEST" in
        assignment|asssignment)
            URL="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"
            SEARCH_KEY="Assignment 2"   # which assessment row to look for on the page
 
            if ! curl -fsSL --max-time 30 "$URL" -o /tmp/assignment.html; then
                printf '{"error":"Could not download assignment webpage."}\n'
                exit 1
            fi
 
            # Convert HTML into readable text.
            if ! html2text -width 120 < /tmp/assignment.html \
                > /tmp/assignment.txt 2>/dev/null; then
                printf '{"error":"Could not convert the webpage to text (html2text)."}\n'
                exit 1
            fi
 
            # Find the assessment row (the title line plus the next two lines).
            LINE_NO=$(grep -n -m1 -- "$SEARCH_KEY" /tmp/assignment.txt | cut -d: -f1)
            if [ -z "$LINE_NO" ]; then
                printf '{"error":"Could not find %s on the unit page."}\n' "$SEARCH_KEY"
                exit 1
            fi
            BLOCK=$(sed -n "${LINE_NO},$((LINE_NO + 2))p" /tmp/assignment.txt)
 
            # Extract each field from the downloaded page (nothing is hardcoded).
            A_TITLE=$(printf '%s\n' "$BLOCK" | grep -o 'Assignment [0-9]\+' | head -n1)
            A_TOPIC=$(printf '%s\n' "$BLOCK" | sed -n 's/.*Programming task - \([A-Za-z]*\).*/\1/p' | head -n1)
            A_POINTS=$(printf '%s\n' "$BLOCK" | grep -o '[0-9]\+%' | head -n1 | tr -d '%')
            A_DUE=$(printf '%s\n' "$BLOCK" \
                | grep -o 'Due date: [0-9]\{1,2\} [A-Za-z]\{3\} [0-9]\{4\} at [0-9]\{1,2\}:[0-9]\{2\}' \
                | head -n1 | sed 's/^Due date: //; s/ at / /')
 
            if [ -z "$A_TITLE" ] || [ -z "$A_TOPIC" ] || [ -z "$A_POINTS" ] || [ -z "$A_DUE" ]; then
                printf '{"error":"Could not extract the assignment details from the page."}\n'
                exit 1
            fi
 
            # Display the assignment information in the server terminal.
            printf '%s\n' "$BLOCK" >&2
 
            # Generate assignment.json from the extracted values.
            printf '{\n    "title" : "%s",\n    "topic" : "%s",\n    "due_date" : "%s",\n    "points" : %s\n}\n' \
                "$A_TITLE" "$A_TOPIC" "$A_DUE" "$A_POINTS" > /tmp/assignment.json
 
            # Send the JSON back through the TCP connection.
            cat /tmp/assignment.json
            ;;
 
 
        population)
            CSV="/tmp/STE_1.csv"
            PNG="/tmp/population.png"
            rm -f "$PNG"

            # Download the latest ABS state and territory data.
            if ! curl -fsSL --max-time 30 \
                "https://dbr.abs.gov.au/processedData/csv/STE_1.csv" \
                -o "$CSV"; then
                printf '{"error":"Could not download population data."}\n'
                exit 1
            fi

            # Read (year,population) from the CSV using Bash/awk.
            # Row 1 holds the year headers; the ERP_P_20 row holds NSW's
            # total population for each year column.
            DATA=$(awk -F',' '
                { gsub(/\r|"/, "") }
                NR == 1 {
                    for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) yr[i] = $i
                    next
                }
                $1 == "ERP_P_20" {
                    for (i = 1; i <= NF; i++)
                        if ((i in yr) && $i ~ /^[0-9.]+$/) printf "%s,%.0f\n", yr[i], $i
                }' "$CSV" | sort -t, -k1,1n)

            if [ -z "$DATA" ]; then
                printf '{"error":"Could not find NSW population data in the CSV."}\n'
                exit 1
            fi

            # Latest (year,population) pair.
            LATEST=$(printf '%s\n' "$DATA" | tail -n1)
            LATEST_YEAR=${LATEST%,*}
            LATEST_POP=${LATEST#*,}

            # Display the latest population in the server terminal.
            echo "Latest NSW population (${LATEST_YEAR}): ${LATEST_POP}" >&2

            # AI ACKNOWLEDGEMENT: The Python (matplotlib) plotting code below was
            # generated with AI assistance (Claude, Anthropic) and reviewed by me.
            # All data extraction (year, population) from the CSV is done in Bash above.
            if ! printf '%s\n' "$DATA" | python3 -c '
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

years, pops = [], []
for line in sys.stdin:
    y, p = line.strip().split(",")
    years.append(int(y))
    pops.append(int(p))

plt.figure(figsize=(9, 5))
plt.plot(years, pops, marker="o")
plt.title("NSW Estimated Resident Population")
plt.xlabel("Year")
plt.ylabel("Population")
plt.grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig(sys.argv[1], dpi=150)
' "$PNG" 2>/tmp/plot.err || [ ! -s "$PNG" ]; then
                echo "Plot error: $(cat /tmp/plot.err)" >&2
                printf '{"error":"Could not generate population graph."}\n'
                exit 1
            fi

            PNG_SIZE=$(wc -c < "$PNG" | tr -d ' ')

            # JSON header (with exact PNG size), then the PNG bytes.
            printf '{"year":%s,"population":%s,"graph":"population.png","image_bytes":%s}\n' \
                "$LATEST_YEAR" "$LATEST_POP" "$PNG_SIZE"
            cat "$PNG"
            ;;


        poi\ *)
            # "poi <name>" or "poi <lat>,<lon>" -- answered from the offline dataset.
            POI_QUERY="${REQUEST#poi }"
 
            if [ -z "$POI_QUERY" ]; then
                printf '{"error":"Usage: poi PLACE or poi LAT,LON"}\n'
                exit 0
            fi
 
            if ! poi_lookup "$POI_QUERY"; then
                printf '{"error":"POI not found: %s"}\n' "${POI_QUERY//[\"\\]/}"
            fi
            ;;
 
        *)
            printf '{"error":"Unknown request."}\n'
            ;;
    esac
 
    exit 0
fi
 
# Discover the container IP address.
SERVER_IP=$(ifconfig eth0 | awk '
/inet addr:/ {sub("addr:", "", $2); print $2; exit}
/inet / && $2 !~ /addr:/ {print $2; exit}
')
 
if [ -z "$SERVER_IP" ]; then
    echo "Error: Could not determine server IP."
    exit 1
fi
 
# Helper: list the TCP ports currently being listened on (ss -ltn).
listening_ports() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null
    else
        netstat -ltn 2>/dev/null
    fi | awk 'NR > 1 { n = split($4, a, ":"); if (a[n] ~ /^[0-9]+$/) print a[n] }' | sort -u
}
 
# Port the listener should ask for (Docker maps 1234 by default; override with
# SERVER_PORT_REQUEST=<port> if needed). The port that is *reported* below is
# not this value -- it is read back from ss -ltn once the server is listening.
REQUESTED_PORT="${SERVER_PORT_REQUEST:-1234}"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo /server.sh)"
 
PORTS_BEFORE="$(listening_ports)"
 
# Refuse to start if something (e.g. an older server.sh) already uses the port.
if printf '%s\n' "$PORTS_BEFORE" | grep -qx "$REQUESTED_PORT"; then
    echo "Error: port ${REQUESTED_PORT} is already in use. Is another server.sh still running?"
    echo "Stop it first (Ctrl+C in its terminal, or: pkill socat) and try again."
    exit 1
fi
 
# Start the listener in the background. socat itself exports the client's IP
# address to the handler as $SOCAT_PEERADDR (do not override it here).
socat \
    "TCP-LISTEN:${REQUESTED_PORT},bind=0.0.0.0,reuseaddr,fork" \
    "EXEC:/bin/bash $SCRIPT_PATH --handle" &
SOCAT_PID=$!
trap 'kill "$SOCAT_PID" 2>/dev/null' EXIT INT TERM
 
# Wait (up to ~5 s) for the new listening port to appear, then extract it.
SERVER_PORT=""
sleep 1
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$SOCAT_PID" 2>/dev/null; then
        echo "Error: could not start the server (is port ${REQUESTED_PORT} already in use?)"
        exit 1
    fi
    SERVER_PORT="$(comm -13 <(printf '%s\n' "$PORTS_BEFORE") <(listening_ports) | head -n 1)"
    [ -n "$SERVER_PORT" ] && break
    sleep 0.5
done
 
if [ -z "$SERVER_PORT" ]; then
    echo "Error: Could not determine the listening port."
    exit 1
fi
 
echo "The server is running at $SERVER_IP, port=$SERVER_PORT"
echo "Listening on 0.0.0.0 $SERVER_PORT"
 
# Keep running forever, waiting for requests.
wait "$SOCAT_PID"