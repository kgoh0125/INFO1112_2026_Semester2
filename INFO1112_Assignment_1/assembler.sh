#!/bin/bash

# Check that exactly one input file was provided
if [ "$#" -eq 0 ]; then
    echo "usage: no argument is provided"
    exit 1
fi

if [ "$#" -gt 1 ]; then
    echo "usage: more than one arguments are provided"
    exit 1
fi

input_file="$1"

# Check that the input, if it exists, is a regular file (e.g. rejects a directory like ~)
if [ -e "$input_file" ] && [ ! -f "$input_file" ]; then
    echo "usage: input is not a file or it does not exist"
    exit 1
fi

# Check that the input file has the correct extension
if [[ "$input_file" != *.vsc ]]; then
    echo "usage: input does not have the extension .vsc"
    exit 1
fi

# Check that the (.vsc) input file exists
if [ ! -f "$input_file" ]; then
    echo "usage: input is not a file or it does not exist"
    exit 1
fi

# Check that the file is not empty
if [ ! -s "$input_file" ]; then
    echo "usage: the file is empty – no .bin file is produced"
    exit 1
fi

# Create output filename
output="${input_file%.vsc}.bin"

# Read the number of static data values
read -r number_of_data_values < "$input_file"
number_of_data_values=${number_of_data_values//$'\r'/}

# Check that the number is valid
if ! [[ "$number_of_data_values" =~ ^(0|2)$ ]]; then
    echo "Error: Invalid number of data values."
    exit 1
fi

# Store converted data in an array
dataArray=()

# If there are 2 data values, read and check them
if [ "$number_of_data_values" -eq 2 ]; then

    read -r value1 < <(sed -n '2p' "$input_file")
    read -r value2 < <(sed -n '3p' "$input_file")

    value1=${value1//[[:space:]]/}
    value2=${value2//[[:space:]]/}

    if ! [[ "$value1" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid data value '$value1'."
        exit 1
    fi

    if ! [[ "$value2" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid data value '$value2'."
        exit 1
    fi

    if [ "$((10#$value1))" -ge 128 ] || [ "$((10#$value2))" -ge 128 ]; then
        echo "Error: Data value must be between 0 and 127."
        exit 1
    fi

    dataArray[0]=$(printf '%02x' "$((10#$value1))")
    dataArray[1]=$(printf '%02x' "$((10#$value2))")
fi

instruction_start=$((number_of_data_values + 2))
instruction_count=0
instructionArray=()
quit_found=0

# Process instructions
while IFS= read -r line || [ -n "$line" ]; do

    line=${line//$'\r'/}

    # Ignore empty lines
    if [ -z "$line" ]; then
        continue
    fi

    # Check instruction length
    if [ "${#line}" -gt 11 ]; then
        echo "Error: Instruction is too long."
        exit 1
    fi

    IFS=',' read -r instruction register address extra <<< "$line"

    instruction=${instruction//[[:space:]]/}
    register=${register//[[:space:]]/}
    address=${address//[[:space:]]/}
    extra=${extra//[[:space:]]/}

    # Check that there are exactly 3 parts
    if [ -n "$extra" ]; then
        echo "Error: Invalid instruction."
        exit 1
    fi

    case "$instruction" in
        LOAD)
            opcode=1
            ;;

        STORE)
            opcode=2
            ;;

        ADD)
            opcode=3
            ;;

        SUB)
            opcode=4
            ;;

        QUIT)
            opcode=8
            ;;

        PRINT)
            opcode=9
            ;;

        *)
            echo "Error: Unknown instruction '$instruction'."
            exit 1
            ;;
    esac

    # QUIT must be exactly QUIT,0,0
    if [ "$instruction" = "QUIT" ]; then
        if [ "$register" != "0" ] || [ "$address" != "0" ]; then
            echo "Error: Invalid QUIT instruction."
            exit 1
        fi

        instructionArray[$instruction_count]="2000"
        instruction_count=$((instruction_count + 1))
        quit_found=1
        break
    fi

    # Check register
    if ! [[ "$register" =~ ^[0-3]$ ]]; then
        echo "Error: Invalid register '$register'."
        exit 1
    fi

    # Check memory address
    if ! [[ "$address" =~ ^[0-9]+$ ]] || [ "$((10#$address))" -gt 255 ]; then
        echo "Error: Invalid memory address '$address'."
        exit 1
    fi
    address=$((10#$address))

    # Check maximum number of instructions
    if [ "$instruction_count" -ge 100 ]; then
        echo "Error: Too many instructions."
        exit 1
    fi

    instruction_value=$(( (opcode << 10) | (register << 8) | address ))

    # Split the 16-bit instruction into two bytes
    high_byte=$((instruction_value >> 8))
    low_byte=$((instruction_value & 255))

    instructionArray[$instruction_count]=$(printf '%02x%02x' "$high_byte" "$low_byte")

    instruction_count=$((instruction_count + 1))

done < <(tail -n +"$instruction_start" "$input_file")

# QUIT must be present
if [ "$quit_found" -eq 0 ]; then
    echo "Error: QUIT instruction is missing."
    exit 1
fi

# Now create the .bin file
: > "$output"

for value in "${dataArray[@]}"; do
    printf "\\x$value" >> "$output"
done

for value in "${instructionArray[@]}"; do
    printf "\\x${value:0:2}\\x${value:2:2}" >> "$output"
done

# Display result
if [ "$number_of_data_values" -eq 0 ]; then
    echo "It is a QUIT program"
else
    echo "It is an ADD/SUB program"
fi

echo "The content of the .bin file is"
if command -v xxd > /dev/null 2>&1; then
    xxd -p -c 1 "$output"
else
    od -An -v -tx1 "$output" | tr -s ' ' '\n' | sed '/^$/d'
fi