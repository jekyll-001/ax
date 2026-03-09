#!/bin/bash
AXIOM_PATH="$HOME/.axiom"

###################################################################

# needed for axiom-init
create_instance() {
        name="$1"
        image_id="$2"
        size_slug="$3"
        region="$4"
        user_data="$5"

        # get SSH key ID or import it
        sshkey="$(jq -r '.sshkey' "$AXIOM_PATH/axiom.json")"
        sshkey_fingerprint="$(ssh-keygen -l -E md5 -f ~/.ssh/$sshkey.pub | awk '{print $2}' | cut -d : -f 2-)"

        # check if key already exists in Vultr
        keyid=$(vultr-cli ssh-key list -o json | jq -r ".ssh_keys[] | select(.name==\"$sshkey\") | .id")
        if [[ -z "$keyid" ]]; then
            keyid=$(vultr-cli ssh-key create --name "$sshkey" --key "$(cat ~/.ssh/$sshkey.pub)" -o json | jq -r '.ssh_key.id')
        fi

        # create user-data file
        user_data_file=$(mktemp)
        echo "$user_data" > "$user_data_file"

        vultr-cli instance create \
            --label "$name" \
            --snapshot "$image_id" \
            --plan "$size_slug" \
            --region "$region" \
            --ssh-keys "$keyid" \
            --userdata "$(cat $user_data_file)" \
            -o json >/dev/null 2>&1

        rm -f "$user_data_file"
        sleep 260
}

###################################################################

#
delete_instance() {
        name="$1"
        force="$2"
        id="$(instance_id "$name")"

        if [ "$force" != "true" ]; then
            read -p "Are you sure you want to delete instance '$name'? (y/N): " confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                echo "Instance deletion aborted."
                return 1
            fi
        fi

        vultr-cli instance delete "$id"
}

###################################################################

# takes no arguments, outputs JSON object with instances
instances() {
        vultr-cli instance list -o json | jq '[.instances[]?]'
}

# used by axiom-ls axiom-init
instance_ip() {
        name="$1"
        instances | jq -r ".[] | select(.label==\"$name\") | .main_ip"
}

# used by axiom-select axiom-ls
instance_list() {
        instances | jq -r '.[].label'
}

# used by axiom-ls
instance_pretty() {
        data=$(instances)

        # number of instances
        num_instances=$(echo "$data" | jq -r '.[].id' | wc -l)

        header="Instance,Primary Ip,Region,Plan,Status,\$/M"

        # Vultr API doesn't return price directly in instance list,
        # so we attempt to get it from the plans list
        plan_prices=$(vultr-cli plans list -o json 2>/dev/null | jq -r '.plans[]? | "\(.id)|\(.monthly_cost)"')

        totalPrice=0
        output=""

        while read -r inst; do
            label=$(echo "$inst" | jq -r '.label')
            main_ip=$(echo "$inst" | jq -r '.main_ip')
            region=$(echo "$inst" | jq -r '.region')
            plan=$(echo "$inst" | jq -r '.plan')
            status=$(echo "$inst" | jq -r '.status')
            power=$(echo "$inst" | jq -r '.power_status')

            # lookup price from plans table
            price=$(printf '%s\n' "$plan_prices" | awk -F'|' -v p="$plan" '$1 == p {print $2; exit}')
            [ -z "$price" ] && price=0
            price=$(printf "%.2f" "$price")

            totalPrice=$(echo "$totalPrice + $price" | bc)

            combined_status="${status}/${power}"
            output+="$label,$main_ip,$region,$plan,$combined_status,$price"$'\n'
        done < <(echo "$data" | jq -c '.[]')

        totals="_,_,Instances,$num_instances,Total,\$$totalPrice"
        (echo "$header" && echo "$output" | sort -t, -k1 && echo "$totals") | sed 's/"//g' | column -t -s,
}

###################################################################

#
generate_sshconfig() {
    sshnew="$AXIOM_PATH/.sshconfig.new$RANDOM"
    sshkey=$(jq -r '.sshkey' < "$AXIOM_PATH/axiom.json")
    generate_sshconfig=$(jq -r '.generate_sshconfig' < "$AXIOM_PATH/axiom.json")
    droplets="$(instances)"

    # handle lock/cache mode
    if [[ "$generate_sshconfig" == "lock" ]] || [[ "$generate_sshconfig" == "cache" ]] ; then
        echo -e "${BYellow}Using cached SSH config. No regeneration performed. To revert run:${Color_Off} ax ssh --just-generate"
        return 0
    fi

    # handle private mode
    if [[ "$generate_sshconfig" == "private" ]] ; then
        echo -e "${BYellow}Using instances private Ips for SSH config. To revert run:${Color_Off} ax ssh --just-generate"
    fi

    # create empty SSH config
    echo -n "" > "$sshnew"
    {
        echo -e "ServerAliveInterval 60"
        echo -e "IdentityFile $HOME/.ssh/$sshkey"
    } >> "$sshnew"

    name_count_str=""

    # Helper to get the current count for a given name
    get_count() {
        local key="$1"
        echo "$name_count_str" | grep -oE "$key:[0-9]+" | cut -d: -f2 | tail -n1
    }

    # Helper to set/update the current count for a given name
    set_count() {
        local key="$1"
        local new_count="$2"
        name_count_str="$(echo "$name_count_str" | sed "s/$key:[0-9]*//g")"
        name_count_str="$name_count_str $key:$new_count"
    }

    echo "$droplets" | jq -c '.[]?' 2>/dev/null | while read -r droplet; do
        # extract fields
        name=$(echo "$droplet" | jq -r '.label? // empty' 2>/dev/null)
        public_ip=$(echo "$droplet" | jq -r '.main_ip? // empty' 2>/dev/null)
        private_ip=$(echo "$droplet" | jq -r '.internal_ip? // empty' 2>/dev/null)

        # skip if name is empty
        if [[ -z "$name" ]] ; then
            continue
        fi

        # select IP based on configuration mode
        if [[ "$generate_sshconfig" == "private" ]]; then
            ip="$private_ip"
        else
            ip="$public_ip"
        fi

        # skip if no IP is available
        if [[ -z "$ip" ]] || [[ "$ip" == "0.0.0.0" ]]; then
            continue
        fi

        current_count="$(get_count "$name")"
        if [[ -n "$current_count" ]]; then
            hostname="${name}-${current_count}"
            new_count=$((current_count + 1))
            set_count "$name" "$new_count"
        else
            hostname="$name"
            set_count "$name" 2
        fi

        # add SSH config entry
        echo -e "Host $hostname\n\tHostName $ip\n\tUser op\n\tPort 2266\n" >> "$sshnew"
    done

    # validate and apply the new SSH config
    if ssh -F "$sshnew" null -G > /dev/null 2>&1; then
        mv "$sshnew" "$AXIOM_PATH/.sshconfig"
    else
        echo -e "${BRed}Error: Generated SSH config is invalid. Details:${Color_Off}"
        ssh -F "$sshnew" null -G
        cat "$sshnew"
        rm -f "$sshnew"
        return 1
    fi
}

###################################################################

#
query_instances() {
    droplets="$(instances)"
    selected=""

    for var in "$@"; do
        if [[ "$var" == "\\*" ]]; then
            var="*"
        fi

        if [[ "$var" == *"*"* ]]; then
            var=$(echo "$var" | sed 's/\*/.*/g')
            matches=$(echo "$droplets" | jq -r '.[].label' | grep -E "^${var}$")
        else
            matches=$(echo "$droplets" | jq -r '.[].label' | grep -w -E "^${var}$")
        fi

        if [[ -n "$matches" ]]; then
            selected="$selected $matches"
        fi
    done

    if [[ -z "$selected" ]]; then
        return 1
    fi

    selected=$(echo "$selected" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    echo -n "${selected}" | xargs
}

###################################################################

# used by axiom-fleet axiom-init
get_image_id() {
        query="$1"
        images=$(vultr-cli snapshot list -o json)
        id=$(echo "$images" | jq -r ".snapshots[]? | select(.description==\"$query\") | .id")
        echo "$id"
}

###################################################################

#
get_snapshots() {
        vultr-cli snapshot list
}

# axiom-images
delete_snapshot() {
        name="$1"
        image_id=$(get_image_id "$name")
        vultr-cli snapshot delete "$image_id"
}

# axiom-images
create_snapshot() {
        instance="$1"
        snapshot_name="$2"
        id=$(instance_id "$instance")
        vultr-cli snapshot create --instance "$id" --description "$snapshot_name"
}

###################################################################

# used by axiom-regions
list_regions() {
    vultr-cli regions list
}

# used for axiom-region
regions() {
    vultr-cli regions list -o json | jq -r '.regions[]?.id'
}

###################################################################

#
poweron() {
    instance_name="$1"
    vultr-cli instance start "$(instance_id "$instance_name")"
}

# axiom-power
poweroff() {
    instance_name="$1"
    vultr-cli instance stop "$(instance_id "$instance_name")"
}

# axiom-power
reboot(){
    instance_name="$1"
    vultr-cli instance restart "$(instance_id "$instance_name")"
}

# axiom-power axiom-images
instance_id() {
        name="$1"
        instances | jq ".[] | select(.label==\"$name\") | .id" | tr -d '"'
}

###################################################################

#
sizes_list() {
    vultr-cli plans list
}

###################################################################

delete_instances() {
    names="$1"
    force="$2"

    # Convert names to an array for processing
    name_array=($names)

    # Make a single call to get all Vultr instances
    all_instances=$(instances)

    # Declare arrays to store instance IDs and names for deletion
    all_instance_ids=()
    all_instance_names=()

    # Iterate over all instances and filter by the provided names
    for name in "${name_array[@]}"; do
        instance_info=$(echo "$all_instances" | jq -r --arg name "$name" '.[] | select(.label == $name)')

        if [ -n "$instance_info" ]; then
            inst_id=$(echo "$instance_info" | jq -r '.id')
            inst_name=$(echo "$instance_info" | jq -r '.label')

            all_instance_ids+=("$inst_id")
            all_instance_names+=("$inst_name")
        else
            echo -e "${BRed}Warning: No Vultr instance found with the name '$name'.${Color_Off}"
        fi
    done

    # Force deletion: Delete all instances without prompting
    if [ "$force" == "true" ]; then
        echo -e "${Red}Deleting: ${all_instance_names[@]}...${Color_Off}"
        for id in "${all_instance_ids[@]}"; do
            vultr-cli instance delete "$id" >/dev/null 2>&1 &
        done
        wait

    # Prompt for each instance if force is not true
    else
        confirmed_instance_ids=()
        confirmed_instance_names=()

        for i in "${!all_instance_ids[@]}"; do
            instance_id="${all_instance_ids[$i]}"
            instance_name="${all_instance_names[$i]}"

            echo -e -n "Are you sure you want to delete $instance_name (Instance ID: $instance_id) (y/N) - default NO: "
            read ans
            if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
                confirmed_instance_ids+=("$instance_id")
                confirmed_instance_names+=("$instance_name")
            else
                echo "Deletion aborted for $instance_name."
            fi
        done

        # Delete confirmed instances
        if [ ${#confirmed_instance_ids[@]} -gt 0 ]; then
            echo -e "${Red}Deleting: ${confirmed_instance_names[@]}...${Color_Off}"
            for id in "${confirmed_instance_ids[@]}"; do
                vultr-cli instance delete "$id" >/dev/null 2>&1 &
            done
            wait
        else
            echo -e "${BRed}No instances were confirmed for deletion.${Color_Off}"
        fi
    fi
}

###################################################################

create_instances() {
    image_id="$1"
    size="$2"
    region="$3"
    user_data="$4"
    timeout="$5"
    disk="$6"
    shift 6
    names=("$@")  # Remaining arguments are instance names

    # Get or import SSH key
    sshkey="$(jq -r '.sshkey' "$AXIOM_PATH/axiom.json")"
    sshkey_fingerprint="$(ssh-keygen -l -E md5 -f ~/.ssh/$sshkey.pub | awk '{print $2}' | cut -d : -f 2-)"

    keyid=$(vultr-cli ssh-key list -o json | jq -r ".ssh_keys[]? | select(.name==\"$sshkey\") | .id")
    if [[ -z "$keyid" ]]; then
        keyid=$(vultr-cli ssh-key create --name "$sshkey" --key "$(cat ~/.ssh/$sshkey.pub)" -o json | jq -r '.ssh_key.id')
    fi

    # Create user-data file
    user_data_file=$(mktemp)
    echo "$user_data" > "$user_data_file"

    # Track instance IDs and names
    instance_ids=()
    instance_names=("${names[@]}")

    # Define batch settings
    batch_size=4
    batch_sleep=15
    count=0

    # Create instances in batches
    for name in "${names[@]}"; do
        vultr_output=$(vultr-cli instance create \
            --label "$name" \
            --snapshot "$image_id" \
            --plan "$size" \
            --region "$region" \
            --ssh-keys "$keyid" \
            --userdata "$(cat "$user_data_file")" \
            -o json 2>&1)

        inst_id=$(echo "$vultr_output" | jq -r '.instance.id // empty' 2>/dev/null)

        if [[ -n "$inst_id" ]]; then
            instance_ids+=("$inst_id")
        else
            >&2 echo "Error creating instance '$name'"
            >&2 echo "$vultr_output"
        fi

        # After every 'batch_size' creations, wait before creating the next batch
        (( count++ ))
        if (( count % batch_size == 0 )); then
            sleep "$batch_sleep"
        fi
    done

    # Clean up temporary file for user data
    rm -f "$user_data_file"

    # Monitor instance statuses
    processed_file=$(mktemp)
    interval=8   # Time between status checks
    elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        all_ready=true

        # Fetch current instance data
        current_data=$(instances)

        for i in "${!instance_ids[@]}"; do
            id="${instance_ids[$i]}"
            name="${instance_names[$i]}"

            status=$(echo "$current_data" | jq -r --arg id "$id" '.[] | select(.id==$id) | .power_status')
            ip=$(echo "$current_data" | jq -r --arg id "$id" '.[] | select(.id==$id) | .main_ip')

            if [[ "$status" == "running" ]] && [[ -n "$ip" ]] && [[ "$ip" != "0.0.0.0" ]]; then
                if ! grep -q "^$name$" "$processed_file"; then
                    echo "$name" >> "$processed_file"
                    >&2 echo -e "${BWhite}Initialized instance '${BGreen}$name${Color_Off}${BWhite}' at '${BGreen}$ip${BWhite}'!"
                    axiom_stats_log_instance "$name" "${ip:-N/A}" "$region" "$size" "$image_id" "$id"
                fi
            else
                all_ready=false
            fi
        done

        if $all_ready; then
            rm -f "$processed_file"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    rm -f "$processed_file"
    return 1
}
