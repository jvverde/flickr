#!/usr/bin/env bash
# generic_launcher.sh - Checks if a command is running and launches it if not.
#
# USAGE: /path/to/launcher.sh <COMMAND_STRING> <LOG_FILE_PATH>

# --- PATH SETUP ---
# Determine the absolute directory where this launcher script resides.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# --- ARGUMENT HANDLING AND VALIDATION ---

if [ "$#" -lt 2 ]; then
    echo "ERROR: Missing arguments."
    echo "Usage: $0 <COMMAND_TO_RUN_IN_SINGLE_QUOTES> <LOG_FILE_PATH>"
    echo ""
    echo "----------------------------------------------------------------------------------"
    echo "Useful Example (For crontab -e):"
    echo "Assumes 'add2groups.pl', 'data/' and 'logs/' are subdirectories of the launcher."
    echo ""
    echo "# Use the absolute path to the interpreter (e.g., /usr/bin/perl) for reliability."
    echo "*/15 * * * * ${SCRIPT_DIR}/generic_launcher.sh '/usr/bin/perl ./add2groups.pl -a 12 -f data/groups.json -s \"Pattern\" -H data/history.json' logs/script.log"
    echo "----------------------------------------------------------------------------------"
    exit 1
fi

# The log file path is the *last* argument.
LOG_FILE_ARG="${!#}"

# The full command to check and run is *all* arguments except the last one.
COMMAND_TO_RUN="${@:1:$#-1}"

# --- 1. RESOLVE LOG FILE PATH ---
# If the log file path is relative, prepend the launcher script's directory.
if [[ "$LOG_FILE_ARG" != /* ]]; then
    LOG_FILE="${SCRIPT_DIR}/${LOG_FILE_ARG}"
else
    LOG_FILE="${LOG_FILE_ARG}"
fi

# 2. Check for running process
if pgrep -f "$COMMAND_TO_RUN" > /dev/null
then
    echo "[$(date)] Already running. Command: '$COMMAND_TO_RUN'. Exiting." >> "$LOG_FILE"
    exit 0
else
    # 3. Launch the script in the background

    echo "[$(date)] NOT running. Launching: '$COMMAND_TO_RUN'..." >> "$LOG_FILE"
    
    # Use PUSHD and POPD to safely manage the working directory.
    # We use a subshell (...) to guarantee the push/pop operation is clean and isolated.
    (
        # Suppress output of pushd/popd commands to keep the log clean
        pushd "$SCRIPT_DIR" &> /dev/null
        
        # Execute the command string with all relative paths correctly resolved.
        # Eval is critical here to properly handle the internal quoting of the COMMAND_TO_RUN string.
        eval "nohup $COMMAND_TO_RUN 2>&1 >> '$LOG_FILE' &"
        
        # Restore original directory (this will execute whether eval succeeds or fails)
        popd &> /dev/null
    )
    
    echo "[$(date)] Command launch complete. Check '$LOG_FILE' for output." >> "$LOG_FILE"
fi