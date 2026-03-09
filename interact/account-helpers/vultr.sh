#!/bin/bash
AXIOM_PATH="$HOME/.axiom"
source "$AXIOM_PATH/interact/includes/vars.sh"

token=""
region=""
provider=""
size=""

BASEOS="$(uname)"
case $BASEOS in
'Linux')
    BASEOS='Linux'
    ;;
'FreeBSD')
    BASEOS='FreeBSD'
    alias ls='ls -G'
    ;;
'WindowsNT')
    BASEOS='Windows'
    ;;
'Darwin')
    BASEOS='Mac'
    ;;
'SunOS')
    BASEOS='Solaris'
    ;;
'AIX') ;;
*) ;;
esac

# Check if vultr-cli is installed and at the recommended version
installed_version=$(vultr-cli version 2>/dev/null | grep -oP 'v\K[0-9.]+' | head -1)

if [[ -z "$installed_version" ]] || [[ "$(printf '%s\n' "$installed_version" "${VultrCliVersion:-3.0.0}" | sort -V | head -n 1)" != "${VultrCliVersion:-3.0.0}" ]]; then
    echo -e "${Yellow}vultr-cli is either not installed or version is lower than the recommended version${Color_Off}"
    echo "Installing/updating vultr-cli..."

    if [[ $BASEOS == "Mac" ]]; then
        whereis brew
        if [ ! $? -eq 0 ] || [[ ! -z ${AXIOM_FORCEBREW+x} ]]; then
            echo -e "${BGreen}Installing Homebrew...${Color_Off}"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        else
            echo -e "${BGreen}Checking for Homebrew... already installed.${Color_Off}"
        fi
        echo -e "${BGreen}Installing vultr-cli...${Color_Off}"
        brew install vultr/vultr-cli/vultr-cli

    elif [[ $BASEOS == "Linux" ]]; then
        if uname -a | grep -qi "Microsoft"; then
            OS="UbuntuWSL"
        else
            OS=$(lsb_release -i 2>/dev/null | awk '{ print $3 }')
            if ! command -v lsb_release &> /dev/null; then
                OS="unknown-Linux"
                BASEOS="Linux"
            fi
        fi

        if [[ $OS == "Arch" ]] || [[ $OS == "ManjaroLinux" ]]; then
            echo -e "${BGreen}Installing vultr-cli via AUR...${Color_Off}"
            # vultr-cli can be installed from AUR
            if command -v yay &>/dev/null; then
                yay -S vultr-cli --noconfirm
            else
                echo "Please install vultr-cli manually from AUR"
            fi
        elif [[ $OS == "Ubuntu" ]] || [[ $OS == "Debian" ]] || [[ $OS == "Linuxmint" ]] || [[ $OS == "Parrot" ]] || [[ $OS == "Kali" ]] || [[ $OS == "unknown-Linux" ]] || [[ $OS == "UbuntuWSL" ]]; then
            echo -e "${BGreen}Installing vultr-cli...${Color_Off}"
            VULTR_CLI_VERSION="${VultrCliVersion:-3.0.0}"
            wget -q -O /tmp/vultr-cli.tar.gz "https://github.com/vultr/vultr-cli/releases/download/v${VULTR_CLI_VERSION}/vultr-cli_${VULTR_CLI_VERSION}_linux_amd64.tar.gz"
            tar -xzf /tmp/vultr-cli.tar.gz -C /tmp
            sudo mv /tmp/vultr-cli /usr/local/bin/vultr-cli
            rm -f /tmp/vultr-cli.tar.gz
        elif [[ $OS == "Fedora" ]]; then
            echo "Needs Conversation for Fedora"
        fi
    fi

    echo "vultr-cli installed."
    echo -e "${BGreen}Installing Vultr packer plugin...${Color_Off}"
    packer plugins install github.com/vultr/vultr
fi

function vultrsetup() {

echo -e "${BGreen}Sign up for a Vultr account at: https://www.vultr.com/?ref=9591923"
echo -e "Obtain your API key from: https://my.vultr.com/settings/#settingsapi${Color_Off}"
echo -e -n "${BGreen}Do you already have a Vultr account? y/n ${Color_Off}"
read acc

if [[ "$acc" == "n" ]]; then
    echo -e "${BGreen}Launching browser with signup page...${Color_Off}"
    if [ $BASEOS == "Mac" ]; then
        open "https://www.vultr.com/?ref=9591923"
    else
        sudo apt install xdg-utils -y 2>/dev/null
        xdg-open "https://www.vultr.com/?ref=9591923"
    fi
fi

echo -e -n "${Green}Please enter your Vultr API key (required): \n>> ${Color_Off}"
read token
while [[ "$token" == "" ]]; do
    echo -e "${BRed}Please provide an API key, your entry contained no input.${Color_Off}"
    echo -e -n "${Green}Please enter your Vultr API key (required): \n>> ${Color_Off}"
    read token
done

# Validate the token
status_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $token" https://api.vultr.com/v2/account)
if [[ "$status_code" == "200" ]]; then
    echo -e "${BGreen}API key is valid.${Color_Off}"
else
    echo -e "${BRed}API key provided is invalid (HTTP $status_code). Please check and try again.${Color_Off}"
    vultrsetup
    return
fi

# Configure vultr-cli with the API key
export VULTR_API_KEY="$token"

echo -e -n "${Green}Listing available regions with vultr-cli: \n${Color_Off}"
vultr-cli regions list

default_region=ewr
echo -e -n "${Green}Please enter your default region (you can always change this later with axiom-region select \$region): Default '$default_region', press enter \n>> ${Color_Off}"
read region
if [[ "$region" == "" ]]; then
    echo -e "${Blue}Selected default option '$default_region'${Color_Off}"
    region="$default_region"
fi

echo -e -n "${Green}Please enter your default plan/size (you can always change this later with axiom-sizes select \$size): Default 'vc2-1c-1gb', press enter \n>> ${Color_Off}"
read size
if [[ "$size" == "" ]]; then
    echo -e "${Blue}Selected default option 'vc2-1c-1gb'${Color_Off}"
    size="vc2-1c-1gb"
fi

data="$(echo "{\"vultr_api_key\":\"$token\",\"region\":\"$region\",\"provider\":\"vultr\",\"default_size\":\"$size\"}")"

echo -e "${BGreen}Profile settings below: ${Color_Off}"
echo "$data" | jq '.vultr_api_key = "************************************"'
echo -e "${BWhite}Press enter if you want to save these to a new profile, type 'r' if you wish to start again.${Color_Off}"
read ans

if [[ "$ans" == "r" ]]; then
    $0
    exit
fi

echo -e -n "${BWhite}Please enter your profile name (e.g 'vultr', must be all lowercase/no specials)\n>> ${Color_Off}"
read title

if [[ "$title" == "" ]]; then
    title="vultr"
    echo -e "${BGreen}Named profile 'vultr'${Color_Off}"
fi

echo $data | jq > "$AXIOM_PATH/accounts/$title.json"
echo -e "${BGreen}Saved profile '$title' successfully!${Color_Off}"
$AXIOM_PATH/interact/axiom-account $title

}

vultrsetup
