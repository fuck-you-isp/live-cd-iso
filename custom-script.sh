#!/bin/bash

# This script runs in an infinite loop to keep the display updated.

# Add a one-time delay to allow viewing the final boot messages before clearing.
sleep 5

# The main loop to refresh the screen.
while true; do
    # --- GATHER ALL DATA FIRST ---

    # Define the 8-space indent prefix
    INDENT="        "

    # Get all non-loopback and non-docker IPv4 addresses.
    # This filters by excluding interfaces named 'lo' or common docker prefixes.
    ALL_IPS=$(ip -o -4 addr show | awk '$2 != "lo" && $2 !~ /docker/ && $2 !~ /br-/ {print $4}' | cut -d/ -f1)

    # Get the status of all Docker containers, including exited ones.
    DOCKER_STATUS=""
    if docker info > /dev/null 2>&1; then
        # Get the full output of docker ps -a
        PS_OUTPUT=$(docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}")
        # Count the number of lines. If it's 1, only the header exists.
        if [ $(echo "$PS_OUTPUT" | wc -l) -le 1 ]; then
            DOCKER_STATUS="Still waiting for containers to start...."
        else
            DOCKER_STATUS="$PS_OUTPUT"
        fi
    else
        DOCKER_STATUS="Waiting for Docker daemon to become available..."
    fi

    # --- CLEAR AND REDRAW ONLY IF WE HAVE DATA ---

    # Only clear and redraw the screen if we have an IP address.
    # This leaves the boot logs visible until the network is ready.
    if [ -n "$ALL_IPS" ]; then
        clear

        # --- PREPARE THE OUTPUT BUFFER ---
        # We build the entire output in a variable and then indent it all at once.
        
        OUTPUT=""
        # Add more whitespace at the top
        OUTPUT+="\n\n\n\n\n"

        # Add the main banner to the buffer
        OUTPUT+=$(figlet "F*** Your ISP")
        OUTPUT+="\n\n"

        # Add the IP address information to the buffer
        OUTPUT+="Access your dashboard with one of the following URLs:\n"
        OUTPUT+="----------------------------------------------------\n"
        while read -r IP; do
            OUTPUT+="http://$IP\n"
        done <<< "$ALL_IPS"
        OUTPUT+="\n\n"

        # Add the Docker container status to the buffer
        OUTPUT+="Running Services:\n"
        OUTPUT+="\n" # Whitespace between header and status
        OUTPUT+="$DOCKER_STATUS\n"

        # --- PRINT THE INDENTED OUTPUT ---
        # The 'sed' command adds the 8-space indent to every line of the output.
        echo -e "$OUTPUT" | sed "s/^/$INDENT/"
    fi

    # Wait for 5 seconds before the next refresh.
    sleep 5
done


