#!/usr/bin/env zsh
# zsh-nanogpt - Use LLM to interpret natural language commands
# https://github.com/nanogpt-community/zsh-nanogpt

# Configuration
ZSH_NANOGPT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh-nanogpt"
ZSH_NANOGPT_CONFIG_FILE="$ZSH_NANOGPT_CONFIG_DIR/config"

# Default values
ZSH_NANOGPT_API_KEY=""
ZSH_NANOGPT_MODEL="zai-org/glm-4.7"
ZSH_NANOGPT_CONFIRM="true"
ZSH_NANOGPT_API_URL="https://nano-gpt.com/api/v1/chat/completions"
ZSH_NANOGPT_TIMEOUT=30

# Dangerous command patterns (glob-style)
ZSH_NANOGPT_DANGEROUS_PATTERNS=(
    '*rm -rf /*'
    '*rm -rf ~*'
    '*rm -rf .*'
    '*mkfs.*'
    '*dd if=*'
    '*> /dev/sd*'
    '*chmod -R 777 /*'
    '*chmod 777 /*'
    '*:(){ :|:& };:*'
)

# Load configuration from file
_nanogpt_load_config() {
    if [[ -f "$ZSH_NANOGPT_CONFIG_FILE" ]]; then
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            
            # Trim whitespace
            key="${key// /}"
            value="${value## }"
            value="${value%% }"
            
            case "$key" in
                api_key)  ZSH_NANOGPT_API_KEY="$value" ;;
                model)    ZSH_NANOGPT_MODEL="$value" ;;
                confirm)  ZSH_NANOGPT_CONFIRM="$value" ;;
                timeout)  ZSH_NANOGPT_TIMEOUT="$value" ;;
            esac
        done < "$ZSH_NANOGPT_CONFIG_FILE"
    fi
}

# Create default config file if it doesn't exist
_nanogpt_init_config() {
    if [[ ! -f "$ZSH_NANOGPT_CONFIG_FILE" ]]; then
        mkdir -p "$ZSH_NANOGPT_CONFIG_DIR"
        
        echo "# zsh-nanogpt configuration" > "$ZSH_NANOGPT_CONFIG_FILE"
        echo "# Get your API key from https://nano-gpt.com/api" >> "$ZSH_NANOGPT_CONFIG_FILE"
        echo "" >> "$ZSH_NANOGPT_CONFIG_FILE"
        echo "api_key=" >> "$ZSH_NANOGPT_CONFIG_FILE"
        echo "model=zai-org/glm-4.7" >> "$ZSH_NANOGPT_CONFIG_FILE"
        echo "confirm=true" >> "$ZSH_NANOGPT_CONFIG_FILE"
        echo "timeout=30" >> "$ZSH_NANOGPT_CONFIG_FILE"
        
        echo "zsh-nanogpt: Created config file at $ZSH_NANOGPT_CONFIG_FILE"
        echo "zsh-nanogpt: Please add your API key from https://nano-gpt.com/api"
    fi
}

# Check if command is dangerous
_nanogpt_check_dangerous() {
    local cmd="$1"
    for pattern in "${ZSH_NANOGPT_DANGEROUS_PATTERNS[@]}"; do
        if [[ "$cmd" == $~pattern ]]; then
            return 0  # Is dangerous
        fi
    done
    # Check for sudo with dangerous commands
    if [[ "$cmd" == *sudo*rm*-rf* ]] || [[ "$cmd" == *sudo*mkfs* ]] || [[ "$cmd" == *sudo*dd* ]]; then
        return 0
    fi
    return 1  # Not dangerous
}

# Get git context if in a git repo
_nanogpt_git_context() {
    if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        local branch=$(git branch --show-current 2>/dev/null)
        local git_changes=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        echo "Git branch: $branch ($git_changes uncommitted changes)"
    fi
}

# Call the NanoGPT API
_nanogpt_call() {
    local prompt="$1"
    
    if [[ -z "$ZSH_NANOGPT_API_KEY" ]]; then
        echo "Error: API key not configured. Edit $ZSH_NANOGPT_CONFIG_FILE" >&2
        return 1
    fi
    
    # Gather context about current environment
    local cwd="$(pwd)"
    local files="$(ls -1 2>/dev/null | head -50 | tr '\n' ', ' | sed 's/,$//')"
    local git_info="$(_nanogpt_git_context)"
    
    local system_prompt="You are a shell command generator. Output ONLY the shell command(s), nothing else - no explanations, no markdown, no code blocks. Use && for multiple commands. IMPORTANT: You will be given the current directory and list of files. Use the EXACT file and folder names provided - do not guess or modify them. If a file is named 'zsh-nanogpt' use exactly that, not 'zsh/nanogpt'."
    
    local context_prompt="Current directory: $cwd | Files here: $files"
    [[ -n "$git_info" ]] && context_prompt="$context_prompt | $git_info"
    context_prompt="$context_prompt | Request: $prompt"
    
    # Escape special characters for JSON
    context_prompt="${context_prompt//\\/\\\\}"  # backslashes
    context_prompt="${context_prompt//\"/\\\"}"  # quotes
    context_prompt="${context_prompt//$'\n'/\\n}" # newlines
    context_prompt="${context_prompt//$'\t'/\\t}" # tabs
    
    local payload="{\"model\": \"$ZSH_NANOGPT_MODEL\", \"messages\": [{\"role\": \"system\", \"content\": \"$system_prompt\"}, {\"role\": \"user\", \"content\": \"$context_prompt\"}], \"temperature\": 0.3, \"max_tokens\": 500}"
    
    local response
    response=$(curl -s -X POST "$ZSH_NANOGPT_API_URL" \
        --max-time "$ZSH_NANOGPT_TIMEOUT" \
        -H "Authorization: Bearer $ZSH_NANOGPT_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1)
    
    local curl_exit=$?
    if [[ $curl_exit -eq 28 ]]; then
        echo "Error: API request timed out after ${ZSH_NANOGPT_TIMEOUT}s" >&2
        return 1
    elif [[ $curl_exit -ne 0 ]]; then
        echo "Error: Failed to connect to API" >&2
        return 1
    fi
    
    # Check for error in response
    local error
    error=$(echo "$response" | grep -o '"error"[[:space:]]*:[[:space:]]*{[^}]*}' | head -1)
    if [[ -n "$error" ]]; then
        echo "API Error: $error" >&2
        return 1
    fi
    
    # Extract content from response
    # Try jq first, fall back to grep/sed
    local content
    if command -v jq &>/dev/null; then
        content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    else
        # Basic extraction without jq
        content=$(echo "$response" | grep -o '"content"[[:space:]]*:[[:space:]]*"[^"]*"' | tail -1 | sed 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi
    
    if [[ -z "$content" ]]; then
        echo "Error: Could not parse API response" >&2
        echo "Response: $response" >&2
        return 1
    fi
    
    # Clean up the content (remove any markdown code blocks if present)
    content=$(echo "$content" | sed 's/^```[a-z]*$//' | sed 's/^```$//' | sed '/^$/d')
    
    echo "$content"
}

# Custom accept-line widget
_nanogpt_accept_line() {
    local cmd="$BUFFER"
    
    # Check if command starts with "# " followed by text
    if [[ "$cmd" =~ ^#[[:space:]]+.+ ]]; then
        # Extract the natural language prompt (everything after "# ")
        local prompt="${cmd#\# }"
        
        echo ""
        echo -n "Thinking..."
        
        # Call the API
        local result
        result=$(_nanogpt_call "$prompt")
        
        # Clear the "Thinking..." line
        echo -ne "\r\033[K"
        
        if [[ $? -ne 0 ]]; then
            echo "Interpreting: $prompt"
            echo "$result"
            BUFFER=""
            zle reset-prompt
            return 1
        fi
        
        echo "Interpreting: $prompt"
        
        # Check for dangerous commands
        if _nanogpt_check_dangerous "$result"; then
            echo "Command: $result"
            echo ""
            echo "WARNING: This command appears dangerous!"
            echo -n "Are you SURE you want to execute? [yes/N] "
            local danger_confirm
            read danger_confirm
            if [[ "$danger_confirm" != "yes" ]]; then
                echo "Cancelled."
                BUFFER=""
                zle reset-prompt
                return 0
            fi
        else
            echo "Command: $result"
        fi
        
        # Check if confirmation is required
        if [[ "$ZSH_NANOGPT_CONFIRM" == "true" ]]; then
            echo -n "[y]es / [n]o / [e]dit > "
            read -k 1 confirm
            echo ""
            
            case "$confirm" in
                y|Y)
                    # Continue to execute
                    ;;
                e|E)
                    # Edit mode - put command in buffer for editing
                    BUFFER="$result"
                    zle reset-prompt
                    return 0
                    ;;
                *)
                    echo "Cancelled."
                    BUFFER=""
                    zle reset-prompt
                    return 0
                    ;;
            esac
        fi
        
        # Add actual command to history (not the # prompt)
        print -s "$result"
        
        # Execute the command
        echo "Executing..."
        echo ""
        BUFFER="$result"
        zle accept-line
    else
        # Normal command, pass through
        zle .accept-line
    fi
}

# Initialize
_nanogpt_init_config
_nanogpt_load_config

# Create the widget and bind it
zle -N accept-line _nanogpt_accept_line
