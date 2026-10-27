#!/bin/bash

set -u


# ---------------------------------------------------------------------------
# "Where am I?" -- neighbouring points of interest (POIs).
# Works fully offline: a small Sydney POI dataset (name|category|lat|lon) is
# embedded below, so no external map API (e.g. Overpass) is needed.
# The client sends a POI name ("Sydney Opera House") or coordinates
# ("-33.857198,151.215123"); we reply with a JSON list of nearby POIs.
# ---------------------------------------------------------------------------
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

    echo "Request from ${SOCAT_PEERADDR:-unknown}: $REQUEST" >&2

    case "$REQUEST" in
        assignment)
            URL="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"

            if ! curl -fsSL "$URL" -o /tmp/assignment.html; then
                printf '{"error":"Could not download assignment webpage."}\n'
                exit 1
            fi

            # Convert HTML into readable text.
            html2text -width 120 < /tmp/assignment.html \
                > /tmp/assignment.txt

            # Generate assignment.json.
            python3 -c '
import json

with open("/tmp/assignment.txt", encoding="utf-8") as f:
    text = f.read()

with open("/tmp/assignment.json", "w", encoding="utf-8") as f:
    json.dump({"assignment": text}, f, indent=2, ensure_ascii=False)
'

            # Send the JSON back through the TCP connection.
            cat /tmp/assignment.json
            ;;


        population)
            CSV="/tmp/STE_1.csv"
            PNG="/tmp/population.png"

            # Download the latest ABS state and territory data.
            if ! curl -fsSL \
                "https://dbr.abs.gov.au/processedData/csv/STE_1.csv" \
                -o "$CSV"; then
                printf '{"error":"Could not download population data."}\n'
                exit 1
            fi

            # Extract the year headers and total population row.
            python3 - "$CSV" "$PNG" <<'PY'
import csv
import sys
import json
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

csv_path, png_path = sys.argv[1], sys.argv[2]

with open(csv_path, newline="", encoding="utf-8-sig") as f:
    rows = list(csv.reader(f))

headers = rows[0]
population_row = next(
    row for row in rows if row and row[0] == "ERP_P_20"
)

years = []
populations = []

for i, header in enumerate(headers):
    if header.isdigit() and i < len(population_row):
        value = population_row[i].strip()
        if value:
            years.append(int(header))
            populations.append(int(float(value)))

if not years:
    raise SystemExit("No population data found.")

latest_year = years[-1]
latest_population = populations[-1]

plt.figure(figsize=(9, 5))
plt.plot(years, populations, marker="o")
plt.title("Estimated Resident Population")
plt.xlabel("Year")
plt.ylabel("Population")
plt.grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig(png_path, dpi=150)
plt.close()

PY

            if [ ! -f "$PNG" ]; then
                printf '{"error":"Could not generate population graph."}\n'
                exit 1
            fi
            # Calculate the PNG size for the response header.
            PNG_SIZE=$(wc -c < "$PNG" | tr -d ' ')

            # Send a JSON header containing the exact PNG size.
            python3 - "$CSV" "$PNG_SIZE" <<'PY'
import csv
import json
import sys

csv_path, png_size = sys.argv[1], int(sys.argv[2])

with open(csv_path, newline="", encoding="utf-8-sig") as f:
    rows = list(csv.reader(f))

headers = rows[0]
row = next(r for r in rows if r and r[0] == "ERP_P_20")

values = [
    (int(headers[i]), int(float(row[i])))
    for i in range(len(headers))
    if headers[i].isdigit() and i < len(row) and row[i].strip()
]

year, population = values[-1]

# Also show the latest population in the server terminal (stderr).
print(f"Latest NSW population ({year}): {population:,}", file=sys.stderr)

print(json.dumps({
    "year": year,
    "population": population,
    "population_formatted": f"{population:,}",
    "graph": "population.png",
    "image_bytes": png_size 
}))
PY

            # Send the exact number of PNG bytes specified above.
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

# Start the listener in the background; each client connection is passed to
# the handler together with the client's IP address.
socat \
    "TCP-LISTEN:${REQUESTED_PORT},bind=0.0.0.0,reuseaddr,fork" \
    "EXEC:env SOCAT_PEERADDR=\$SOCAT_PEERADDR /bin/bash $SCRIPT_PATH --handle" &
SOCAT_PID=$!
trap 'kill "$SOCAT_PID" 2>/dev/null' EXIT INT TERM

# Wait (up to ~5 s) for the new listening port to appear, then extract it.
SERVER_PORT=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if ! kill -0 "$SOCAT_PID" 2>/dev/null; then
        echo "Error: could not start the server (is port ${REQUESTED_PORT} already in use?)"
        exit 1
    fi
    SERVER_PORT="$(comm -13 <(printf '%s\n' "$PORTS_BEFORE") <(listening_ports) | head -n 1)"
    [ -n "$SERVER_PORT" ] && break
done

if [ -z "$SERVER_PORT" ]; then
    echo "Error: Could not determine the listening port."
    exit 1
fi

echo "Server IP: $SERVER_IP"
echo "Server port: $SERVER_PORT"
echo "Waiting for client requests..."

# Keep running forever, waiting for requests.
wait "$SOCAT_PID"