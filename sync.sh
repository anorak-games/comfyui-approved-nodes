#!/bin/bash
set -e

# Environment type: either 'backend' or 'frontend'
ENV_TYPE="${ENV_TYPE:-frontend}"   # default to frontend if not set

# Directory where custom nodes will be stored (for git clones)
CUSTOM_NODES_DIR="${CUSTOM_NODES_DIR:-./custom_nodes}"
mkdir -p "$CUSTOM_NODES_DIR"

# Function to install a registry node
install_registry_node() {
    local name="$1"
    echo "Installing registry node: $name"
    # Assumes 'comfy' CLI is available and configured
    comfy node install "$name"
}

# Function to clone a git node
clone_git_node() {
    local name="$1"
    local source="$2"
    local recursive="$3"
    local target="$CUSTOM_NODES_DIR/$name"

    if [ -d "$target" ]; then
        echo "Git node $name already exists, pulling updates..."
        cd "$target"
        git pull
        cd - >/dev/null
    else
        echo "Cloning $name from $source ..."
        if [ "$recursive" = "true" ]; then
            git clone --recursive "$source" "$target"
        else
            git clone "$source" "$target"
        fi
    fi
}

# Function to install requirements if needed
install_requirements() {
    local node_dir="$1"
    if [ -f "$node_dir/requirements.txt" ]; then
        echo "Installing requirements from $node_dir/requirements.txt ..."
        pip install --no-cache-dir -r "$node_dir/requirements.txt"
    fi
}

# Function to run custom install command
run_custom_install() {
    local node_dir="$1"
    local cmd="$2"
    echo "Running custom install in $node_dir: $cmd"
    cd "$node_dir"
    eval "$cmd"
    cd - >/dev/null
}

# Parse manifest.yaml
if command -v yq &>/dev/null; then
    # Using yq (assuming yq version 4+ with eval-all)
    nodes=$(yq eval '.nodes[]' manifest.yaml)
else
    # Fallback: parse with Python
    nodes=$(python3 <<EOF
import yaml, sys
with open('manifest.yaml') as f:
    data = yaml.safe_load(f)
for node in data['nodes']:
    print(yaml.dump(node, default_flow_style=False).strip())
EOF
)
fi

# Process each node
echo "$nodes" | while IFS= read -r node_block; do
    # Parse the node block (it's a YAML document per node)
    name=$(echo "$node_block" | grep '^name:' | awk '{print $2}')
    type=$(echo "$node_block" | grep '^type:' | awk '{print $2}')
    envs=$(echo "$node_block" | grep '^envs:' | sed 's/envs://' | tr -d '[]' | tr ',' '\n' | sed 's/^ *//;s/ *$//')
    source=$(echo "$node_block" | grep '^source:' | awk '{print $2}')
    install_requirements=$(echo "$node_block" | grep '^install_requirements:' | awk '{print $2}')
    recursive_install=$(echo "$node_block" | grep '^recursive_install:' | awk '{print $2}')
    custom_install=$(echo "$node_block" | grep '^custom_install:' | sed 's/^custom_install://' | sed 's/^ *//;s/ *$//')

    # Check if this node should be installed in this environment
    should_install=false
    for env in $envs; do
        if [ "$env" = "$ENV_TYPE" ]; then
            should_install=true
            break
        fi
    done

    if [ "$should_install" = false ]; then
        echo "Skipping $name (not for $ENV_TYPE)"
        continue
    fi

    # Process based on type
    if [ "$type" = "registry" ]; then
        install_registry_node "$name"
        # For registry nodes, dependencies are handled by comfy node install
    elif [ "$type" = "git" ]; then
        if [ -z "$source" ]; then
            echo "ERROR: git node $name has no source URL" >&2
            exit 1
        fi
        clone_git_node "$name" "$source" "$recursive_install"
        node_dir="$CUSTOM_NODES_DIR/$name"
        if [ "$install_requirements" = "true" ]; then
            install_requirements "$node_dir"
        fi
        if [ -n "$custom_install" ]; then
            run_custom_install "$node_dir" "$custom_install"
        fi
    else
        echo "WARNING: unknown node type $type for $name, skipping" >&2
    fi
done