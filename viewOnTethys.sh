#!/bin/bash

# ======================================================================
# CIROH: NextGen In A Box (NGIAB) - Tethys Visualization
# ======================================================================

# Enable debug mode to see what's happening
# set -x

# Color definitions with enhanced palette
BBlack='\033[1;30m'
BRed='\033[1;31m'
BGreen='\033[1;32m'
BYellow='\033[1;33m'
BBlue='\033[1;34m'
BPurple='\033[1;35m'
BCyan='\033[1;36m'
BWhite='\033[1;37m'
UBlack='\033[4;30m'
URed='\033[4;31m'
UGreen='\033[4;32m'
UYellow='\033[4;33m'
UBlue='\033[4;34m'
UPurple='\033[4;35m'
UCyan='\033[4;36m'
UWhite='\033[4;37m'
Color_Off='\033[0m'

# Extended color palette with 256-color support
LBLUE='\033[38;5;39m'  # Light blue
LGREEN='\033[38;5;83m' # Light green 
LPURPLE='\033[38;5;171m' # Light purple
LORANGE='\033[38;5;215m' # Light orange
LTEAL='\033[38;5;87m'  # Light teal

# Background colors for highlighting important messages
BG_Green='\033[42m'
BG_Blue='\033[44m'
BG_Red='\033[41m'
BG_LBLUE='\033[48;5;117m' # Light blue background

# Symbols for better UI
CHECK_MARK="${BGreen}✓${Color_Off}"
CROSS_MARK="${BRed}✗${Color_Off}"
ARROW="${LORANGE}→${Color_Off}"
INFO_MARK="${LBLUE}ℹ${Color_Off}"
WARNING_MARK="${BYellow}⚠${Color_Off}"

# Fix for missing environment variables that might cause display issues
export TERM=xterm-256color

# Constants
CONFIG_FILE="$HOME/.host_data_path.conf"
DOCKER_NETWORK="tethys-network"
TETHYS_CONTAINER_NAME="tethys-ngen-portal"
TETHYS_REPO="awiciroh/tethys-ngiab"
TETHYS_TAG="latest"
MODELS_RUNS_DIRECTORY="$HOME/ngiab_visualizer"
DATASTREAM_DIRECTORY="$HOME/.datastream_ngiab"
VISUALIZER_CONF="$MODELS_RUNS_DIRECTORY/ngiab_visualizer.json"
TETHYS_PERSIST_PATH="/var/lib/tethys_persist"
SKIP_DB_SETUP=false

# Disable error trapping initially so we can catch and report errors
set +e

# Function for animated loading with gradient colors
show_loading() {
    local message=$1
    local duration=${2:-3}
    local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local colors=("\033[38;5;39m" "\033[38;5;45m" "\033[38;5;51m" "\033[38;5;87m")
    local end_time=$((SECONDS + duration))
    
    while [ $SECONDS -lt $end_time ]; do
        for (( i=0; i<${#chars}; i++ )); do
            color_index=$((i % ${#colors[@]}))
            echo -ne "\r${colors[$color_index]}${chars:$i:1}${Color_Off} $message"
            sleep 0.1
        done
    done
    echo -ne "\r${CHECK_MARK} $message - Complete!   \n"
}

# Function for section headers
print_section_header() {
    local title=$1
    local width=70
    local padding=$(( (width - ${#title}) / 2 ))
    
    # Create a more visually appealing section header with light blue background
    echo -e "\n\033[48;5;117m$(printf "%${width}s" " ")\033[0m"
    echo -e "\033[48;5;117m$(printf "%${padding}s" " ")${BWhite}${title}$(printf "%${padding}s" " ")\033[0m"
    echo -e "\033[48;5;117m$(printf "%${width}s" " ")\033[0m\n"
}

# Simple banner without complex formatting
print_welcome_banner() {
    clear
    echo -e "\n"
    echo -e "${BBlue}=================================================${Color_Off}"
    echo -e "${BBlue}|  CIROH: NextGen In A Box (NGIAB) - Tethys     |${Color_Off}"
    echo -e "${BBlue}|  Interactive Model Output Visualization       |${Color_Off}"
    echo -e "${BBlue}=================================================${Color_Off}"
    echo -e "\n${INFO_MARK} ${BWhite}Developed by CIROH${Color_Off}\n"
    sleep 1
}

# Function for error handling
handle_error() {
    echo -e "\n${BG_Red}${BWhite} ERROR: $1 ${Color_Off}"
    # Save error to log file
    echo "$(date): ERROR: $1" >> ~/ngiab_tethys_error.log
    
    # Be sure to clean up resources even on error
    tear_down
    exit 1
}

# Function to handle the SIGINT (Ctrl-C)
handle_sigint() {
    echo -e "\n${BG_Red}${BWhite} Operation cancelled by user. Cleaning up... ${Color_Off}"
    tear_down
    exit 1
}

# Set up trap for signal handlers
trap handle_sigint INT TERM
trap 'handle_error "Unexpected error occurred at line $LINENO: $BASH_COMMAND"' ERR

# Detect platform
if uname -a | grep -q 'arm64\|aarch64'; then
    PLATFORM="linux/arm64"
else
    PLATFORM="linux/amd64"
fi

# Main functions
ensure_host_dir() {
    local dir="$1"

    # Create the directory if it doesn't exist
    if [ ! -d "$dir" ]; then
        echo -e "${INFO_MARK} Directory ${BWhite}$dir${Color_Off} doesn't exist — creating it..."
        mkdir -p "$dir" || { echo "Could not create directory $dir"; return 1; }
    fi

    # Get owner UID (portable: Linux uses -c, macOS/BSD uses -f)
    local owner_uid=""
    if owner_uid=$(stat -c '%u' "$dir" 2>/dev/null); then
        :  # GNU stat (Linux)
    elif owner_uid=$(stat -f '%u' "$dir" 2>/dev/null); then
        :  # BSD stat (macOS, Git-Bash)
    fi

    # If the directory is not owned by the current user, try to chown it
    if [[ -n "$owner_uid" && "$owner_uid" != "$(id -u)" ]]; then
        if command -v chown >/dev/null 2>&1; then
            echo -e "${INFO_MARK} ${BYellow}Reclaiming ownership of $dir (sudo may prompt)...${Color_Off}"
            sudo chown -R "$(id -u):$(id -g)" "$dir" || echo -e "${WARNING_MARK} Could not change directory ownership."
        fi
    fi

    # Ensure the current user has rwx on the directory
    chmod u+rwx "$dir" || { echo "Could not set directory permissions on $dir"; return 1; }
    return 0
}

ensure_visualizer_conf_host_file() {
    local file="$1"
    local dir
    dir=$(dirname "$file")

    # Make sure the directory exists and is writable by the user
    if ! ensure_host_dir "$dir"; then
        echo "Failed to ensure directory for config file"
        return 1
    fi

    # Create the file if it doesn't exist, and initialize it
    if [ ! -f "$file" ]; then
        echo -e "${INFO_MARK} Creating configuration file ${BWhite}$file${Color_Off}..."
        echo '{"model_runs":[]}' > "$file" || { echo "Could not create file $file"; return 1; }
    fi

    # Ensure the user can read/write the file
    chmod u+rw "$file" || { echo "Could not set file permissions on $file"; return 1; }
    return 0
}

create_tethys_docker_network() {
    echo -e "${INFO_MARK} Setting up Docker network for Tethys..."
    
    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        echo -e "${BRed}Docker daemon is not running or accessible.${Color_Off}"
        return 1
    fi
    
    # Check if network already exists
    if docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
        echo -e "  ${CHECK_MARK} Network ${BCyan}$DOCKER_NETWORK${Color_Off} already exists."
        return 0
    fi
    
    # Create the network
    if docker network create -d bridge "$DOCKER_NETWORK" >/dev/null 2>&1; then
        echo -e "  ${CHECK_MARK} Network ${BCyan}$DOCKER_NETWORK${Color_Off} created successfully."
        # Add a small delay to ensure network is fully created
        sleep 1
        return 0
    else
        echo -e "  ${CROSS_MARK} ${BRed}Failed to create Docker network.${Color_Off}"
        return 1
    fi
}

check_for_existing_tethys_image() {
    # First check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        echo -e "${BRed}Docker daemon is not running or accessible.${Color_Off}"
        return 1
    fi
    
    # Check if the image exists locally
    local image_exists=false
    if docker image inspect "${TETHYS_REPO}:${TETHYS_TAG}" >/dev/null 2>&1; then
        image_exists=true
    fi
    
    if [ "$image_exists" = true ]; then
        echo -e "  ${CHECK_MARK} ${BGreen}Using local Tethys image: ${TETHYS_REPO}:${TETHYS_TAG}${Color_Off}"
        return 0
    else
        echo -e "  ${INFO_MARK} ${BYellow}Tethys image not found locally. Pulling from registry...${Color_Off}"
        show_loading "Downloading Tethys image" 3
        if ! docker pull "${TETHYS_REPO}:${TETHYS_TAG}"; then
            echo -e "  ${CROSS_MARK} ${BRed}Failed to pull Docker image: ${TETHYS_REPO}:${TETHYS_TAG}${Color_Off}"
            return 1
        fi
        echo -e "  ${CHECK_MARK} ${BGreen}Tethys image downloaded successfully${Color_Off}"
        return 0
    fi
}

choose_port_to_run_tethys() {
    while true; do
        echo -e "${BBlue}Select a port to run Tethys on. [Default: 80] ${Color_Off}"
        read -erp "Port: " nginx_tethys_port

        # Default to 80 if the user just hits <Enter>
        if [[ -z "$nginx_tethys_port" ]]; then
            nginx_tethys_port=80
            echo -e "${ARROW} ${BWhite}Using default port 80 for Tethys.${Color_Off}"
        fi

        # Validate numeric port 1-65535
        if ! [[ "$nginx_tethys_port" =~ ^[0-9]+$ ]] || \
           [ "$nginx_tethys_port" -lt 1 ] || [ "$nginx_tethys_port" -gt 65535 ]; then
            echo -e "${BRed}Invalid port number. Please enter 1-65535.${Color_Off}"
            continue
        fi

        # Check if the port is already in use (skip check if lsof not present)
        if command -v lsof >/dev/null && lsof -i:"$nginx_tethys_port" >/dev/null 2>&1; then
            echo -e "${BRed}Port $nginx_tethys_port is already in use. Choose another.${Color_Off}"
            continue
        fi

        break
    done

    CSRF_TRUSTED_ORIGINS="[\"http://localhost:${nginx_tethys_port}\",\"http://127.0.0.1:${nginx_tethys_port}\"]"
    echo -e "  ${CHECK_MARK} ${BGreen}Port $nginx_tethys_port selected${Color_Off}"

    return 0
}

tear_down() {
    echo -e "\n${ARROW} ${BYellow}Cleaning up resources...${Color_Off}"
    
    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        echo -e "  ${CROSS_MARK} ${BRed}Docker daemon is not running, cannot clean up containers.${Color_Off}"
        return 1
    fi
    
    # Stop the Tethys container if it's running
    if docker ps -q -f name="$TETHYS_CONTAINER_NAME" >/dev/null 2>&1; then
        echo -e "  ${INFO_MARK} Stopping Tethys container..."
        docker stop "$TETHYS_CONTAINER_NAME" >/dev/null 2>&1
        sleep 2
    fi
    
    # Remove the Docker network if it exists
    if docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
        echo -e "  ${INFO_MARK} Removing Docker network..."
        docker network rm "$DOCKER_NETWORK" >/dev/null 2>&1 || true
    fi
    
    echo -e "  ${CHECK_MARK} ${BGreen}Cleanup completed${Color_Off}"
    return 0
}

wait_container() {
    local container_name=$1
    local max_attempts=10
    local attempt_counter=0

    echo -e "\n${ARROW} ${BWhite}Waiting for Tethys container to start...${Color_Off}"
    echo -e "  ${INFO_MARK} This may take a few moments."
    
    # First check if the container is running
    if ! docker ps -q -f name="$container_name" >/dev/null 2>&1; then
        echo -e "  ${CROSS_MARK} ${BRed}Container $container_name is not running${Color_Off}"
        return 1
    fi
    
    # Simple wait to give the container time to initialize
    sleep 5
    
    # Check again if container is still running
    if ! docker ps -q -f name="$container_name" >/dev/null 2>&1; then
        echo -e "  ${CROSS_MARK} ${BRed}Container $container_name stopped unexpectedly${Color_Off}"
        return 1
    fi
    
    echo -e "  ${CHECK_MARK} ${BGreen}Tethys is now running${Color_Off}"
    return 0
}

copy_models_run() {
    local input_path="$1"
    local models_dir="$MODELS_RUNS_DIRECTORY"
    
    # Ensure directory exists with correct permissions
    if ! ensure_host_dir "$models_dir"; then
        echo "Failed to create models directory"
        return 1
    fi

    # Derive the target path
    local base_name
    base_name="$(basename "$input_path")"
    local model_run_path="$models_dir/$base_name"
    
    # Copy logic - simplified to reduce errors
    echo -e "${INFO_MARK} ${BWhite}Copying model data to visualization directory...${Color_Off}"
    
    # Remove existing directory if it exists
    if [ -e "$model_run_path" ]; then
        echo -e "  ${INFO_MARK} ${BYellow}Directory already exists, overwriting...${Color_Off}"
        rm -rf "$model_run_path"
    fi
    
    # Copy the data
    if cp -r "$input_path" "$models_dir/"; then
        echo -e "  ${CHECK_MARK} ${BGreen}Model data copied successfully${Color_Off}"
    else
        echo -e "  ${CROSS_MARK} ${BRed}Failed to copy model data${Color_Off}"
        return 1
    fi
    
    # Output the directory path
    echo "$model_run_path"
}

add_model_run() {
    local input_path="$1"
    local json_file="$VISUALIZER_CONF"

    # Ensure JSON file exists
    if ! ensure_visualizer_conf_host_file "$json_file"; then
        echo "Failed to create config file"
        return 1
    fi

    # Extract the basename for label
    local base_name
    base_name=$(basename "$input_path")

    # Generate a new UUID for the id field - simplified
    local new_uuid="ngiab-$(date +%Y%m%d%H%M%S)-$(( RANDOM % 1000 ))"

    # Current date/time
    local current_time
    current_time=$(date +"%Y-%m-%d:%H:%M:%S")

    # Path for Tethys container
    local final_path="$TETHYS_PERSIST_PATH/ngiab_visualizer/$base_name"
    
    echo -e "${INFO_MARK} ${BWhite}Registering model run in visualization system...${Color_Off}"
    
    # Simplified approach - create a new file
    echo '{"model_runs":[{"label":"'"$base_name"'","path":"'"$final_path"'","date":"'"$current_time"'","id":"'"$new_uuid"'","subset":"","tags":[]}]}' > "$json_file"
    
    if [ $? -eq 0 ]; then
        echo -e "  ${CHECK_MARK} ${BGreen}Model run registered successfully${Color_Off}"
        return 0
    else
        echo -e "  ${CROSS_MARK} ${BRed}Failed to register model run.${Color_Off}"
        return 1
    fi
}

run_tethys() {
    ensure_host_dir "$MODELS_RUNS_DIRECTORY"
    ensure_host_dir "$DATASTREAM_DIRECTORY"
    ensure_visualizer_conf_host_file "$VISUALIZER_CONF"
    
    echo -e "${ARROW} ${BWhite}Launching Tethys container...${Color_Off}"
    
    # First, make sure any existing Tethys containers are stopped
    if docker ps -q -f name="$TETHYS_CONTAINER_NAME" >/dev/null 2>&1; then
        echo -e "  ${INFO_MARK} ${BYellow}Tethys container is already running. Stopping it first...${Color_Off}"
        docker stop "$TETHYS_CONTAINER_NAME" >/dev/null 2>&1
        sleep 3
    fi
    
    # Final check - if container still exists, force removal
    if docker ps -a -q -f name="$TETHYS_CONTAINER_NAME" >/dev/null 2>&1; then
        echo -e "  ${WARNING_MARK} ${BYellow}Forcibly removing container...${Color_Off}"
        docker rm -f "$TETHYS_CONTAINER_NAME" >/dev/null 2>&1 || true
        sleep 2
    fi
    
    # Create new network
    create_tethys_docker_network
    
    # Brief delay before starting
    sleep 1
    echo -e "  ${INFO_MARK} ${BYellow}Starting Tethys container...${Color_Off}"
    
    # Launch container with explicit error handling
    echo -e "  ${INFO_MARK} Running docker command..."
    docker run --rm -d \
        -v "$MODELS_RUNS_DIRECTORY:$TETHYS_PERSIST_PATH/ngiab_visualizer" \
        -v "$DATASTREAM_DIRECTORY:$TETHYS_PERSIST_PATH/.datastream_ngiab" \
        -p "$nginx_tethys_port:$nginx_tethys_port" \
        --network "$DOCKER_NETWORK" \
        --name "$TETHYS_CONTAINER_NAME" \
        --env MEDIA_ROOT="$TETHYS_PERSIST_PATH/media" \
        --env MEDIA_URL="/media/" \
        --env SKIP_DB_SETUP="$SKIP_DB_SETUP" \
        --env DATASTREAM_CONF="$TETHYS_PERSIST_PATH/.datastream_ngiab" \
        --env VISUALIZER_CONF="$TETHYS_PERSIST_PATH/ngiab_visualizer/ngiab_visualizer.json" \
        --env NGINX_PORT="$nginx_tethys_port" \
        --env CSRF_TRUSTED_ORIGINS="$CSRF_TRUSTED_ORIGINS" \
        "${TETHYS_REPO}:${TETHYS_TAG}"
        
    if [ $? -eq 0 ]; then
        echo -e "  ${CHECK_MARK} ${BGreen}Tethys container started successfully.${Color_Off}"
        return 0
    else
        echo -e "  ${CROSS_MARK} ${BRed}Failed to start Tethys container.${Color_Off}"
        return 1
    fi
}

pause_script_execution() {
    echo -e "\n${BG_Blue}${BWhite} Tethys is now running ${Color_Off}"
    echo -e "${INFO_MARK} Access the visualization at: ${UBlue}http://localhost:$nginx_tethys_port/apps/ngiab${Color_Off}"
    echo -e "${INFO_MARK} Press ${BWhite}Ctrl+C${Color_Off} to stop Tethys when you're done."
    
    # Keep script running until user interrupts
    while true; do
        sleep 10
    done
}

# Main script execution
print_welcome_banner

# Check if data path is provided as argument
DATA_FOLDER_PATH="$1"

if [[ -z "$DATA_FOLDER_PATH" ]]; then
    # If no path provided, check if we have a saved path
    if [ -f "$CONFIG_FILE" ]; then
        LAST_PATH=$(cat "$CONFIG_FILE")
        echo -e "${INFO_MARK} Last used data directory: ${BBlue}$LAST_PATH${Color_Off}"
        echo -e "  ${ARROW} Use this path? [Y/n]: "
        echo -ne "\r\033[2A"  # Move up 2 lines
        read -e use_last_path
        echo -e "\033[2B"  # Move down 2 lines
        
        if [[ -z "$use_last_path" || "$use_last_path" =~ ^[Yy] ]]; then
            DATA_FOLDER_PATH="$LAST_PATH"
            echo -e "  ${CHECK_MARK} ${BGreen}Using previously configured path${Color_Off}"
        else
            echo -ne "  ${ARROW} Enter your input data directory path: "
            read -e DATA_FOLDER_PATH
        fi
    else
        echo -e "${INFO_MARK} ${BYellow}No previous configuration found.${Color_Off}"
        echo -ne "  ${ARROW} Enter your input data directory path: "
        read -e DATA_FOLDER_PATH
    fi
    
    # Save the new path
    echo "$DATA_FOLDER_PATH" > "$CONFIG_FILE"
    echo -e "  ${CHECK_MARK} ${BGreen}Path saved for future use.${Color_Off}"
fi

# Validate the directory
if [ ! -d "$DATA_FOLDER_PATH" ]; then
    echo -e "${CROSS_MARK} ${BRed}Directory does not exist: $DATA_FOLDER_PATH${Color_Off}"
    exit 1
fi

print_section_header "PREPARING VISUALIZATION ENVIRONMENT"

# Copy model data to visualization directory
final_dir=$(copy_models_run "$DATA_FOLDER_PATH") || {
    echo -e "${CROSS_MARK} ${BRed}Failed to copy model data. Exiting.${Color_Off}"
    exit 1
}

# Register the model run
add_model_run "$final_dir" || {
    echo -e "${CROSS_MARK} ${BRed}Failed to register model run. Exiting.${Color_Off}"
    exit 1
}

print_section_header "LAUNCHING TETHYS VISUALIZATION"

# Setup and run Tethys
check_for_existing_tethys_image || {
    echo -e "${CROSS_MARK} ${BRed}Failed to prepare Tethys image. Exiting.${Color_Off}"
    exit 1
}
choose_port_to_run_tethys
run_tethys || {
    echo -e "${CROSS_MARK} ${BRed}Failed to start Tethys container. Exiting.${Color_Off}"
    exit 1
}

# Wait for container to be ready
wait_container "$TETHYS_CONTAINER_NAME" || {
    echo -e "${CROSS_MARK} ${BRed}Tethys container failed to start properly. Exiting.${Color_Off}"
    exit 1
}

print_section_header "VISUALIZATION READY"

echo -e "${BG_Green}${BWhite} Your model outputs are now available for visualization! ${Color_Off}\n"
echo -e "${INFO_MARK} Access the visualization at: ${UBlue}http://localhost:$nginx_tethys_port/apps/ngiab${Color_Off}"
echo -e "${INFO_MARK} Login credentials:"
echo -e "  ${ARROW} ${BWhite}Username:${Color_Off} admin"
echo -e "  ${ARROW} ${BWhite}Password:${Color_Off} pass"
echo -e "\n${INFO_MARK} Source code: ${UBlue}https://github.com/CIROH-UA/ngiab-client${Color_Off}"

# Keep the script running
pause_script_execution

exit 0