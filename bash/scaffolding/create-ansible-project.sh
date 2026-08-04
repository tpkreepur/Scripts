#!/usr/bin/env bash
set -euo pipefail

# Trap errors and print the line number
trap 'echo "Error on line $LINENO. Aborting." >&2; exit 1' ERR

# Colour output for better readability (optional)
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Colour

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [PROJECT_NAME]

Scaffold a new Ansible project with standard directory structure and Git initialisation.

Options:
  -h, --help     Show this help message and exit.

If PROJECT_NAME is not provided, defaults to "infrastructure-ansible".
EOF
}

# Default project name
PROJECT_NAME="infrastructure-ansible"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            PROJECT_NAME="$1"
            shift
            ;;
    esac
done

# Check for git availability
if ! command -v git &>/dev/null; then
    echo -e "${RED}Error: git is not installed or not in PATH.${NC}" >&2
    exit 1
fi

# Check if project directory already exists
if [[ -d "$PROJECT_NAME" ]]; then
    echo -e "${RED}Error: Directory '$PROJECT_NAME' already exists. Please remove or rename it.${NC}" >&2
    exit 1
fi

echo -e "${GREEN}Creating Ansible project: $PROJECT_NAME${NC}"

# 1. Create root directory and change into it
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# 2. Initialise Git repository
git init --quiet
echo -e "${GREEN}Git repository initialised.${NC}"

# 3. Create base configuration files (touch will create them if they don't exist)
touch README.md ansible.cfg requirements.yml site.yml .gitignore
echo -e "${GREEN}Base configuration files created.${NC}"

# 4. Create directory structure
mkdir -p playbooks
mkdir -p inventory/{production,staging}/{group_vars,host_vars}
mkdir -p roles/{common,web}/{tasks,handlers,templates,files,vars,defaults,meta}
echo -e "${GREEN}Directory structure created.${NC}"

# 5. Create dummy files to ensure Git tracks the empty directories
touch inventory/production/hosts.ini inventory/staging/hosts.ini
touch roles/common/tasks/main.yml roles/web/tasks/main.yml
echo -e "${GREEN}Dummy files created.${NC}"

# 6. Optional: Add a basic .gitignore (common Ansible ignores)
cat > .gitignore <<'EOF'
# Python / virtual environments
venv/
*.pyc
__pycache__/

# Ansible temporary files
*.retry
*.log

# Editor files
*.swp
*.swo
.DS_Store
EOF
echo -e "${GREEN}Basic .gitignore added.${NC}"

# Final success message
echo -e "${GREEN}Ansible project '$PROJECT_NAME' scaffolded successfully!${NC}"
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  Edit your inventory files in inventory/ and roles in roles/"
echo "  Start writing your playbooks"