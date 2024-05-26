#!/bin/bash

start_time=$(date +%s)
date
## Read config
function read_config() {
    PATH_TO_CONFIG=$(pwd)/config.ini
    AWK_PATH=$(command -v awk)
    A="$($AWK_PATH -F '=' '/^'"$1"'/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' $PATH_TO_CONFIG)"
    CONFIG=$(echo "$A" | tr -d '[]')
    IFS=', ' read -ra CONFIG_ARRAY <<<"$CONFIG"
    echo "${CONFIG_ARRAY[@]}"
}


KB_HOST=$(read_config kbhost)
ES_HOST=$(read_config eshost)
AUTH=""$(read_config user)":"$(read_config pw)""
OUTPUTS=$(read_config outputs)

response=$(curl -XGET \
            -s \
            -o /dev/null \
            -w "%{http_code}" \
            -u $AUTH \
            --url ''"$KB_HOST"'/api/fleet/outputs')

# 상태 코드가 200이 아닌 경우 종료
if [ "$response" != "200" ]; then
    echo "HTTP request failed with status code $response"
    exit 1
fi

echo "test connection status code 200"

if [ "$1" = "prejob" ]; then
    FILE="./output_id.log"

    ######## create new output
    echo ""
    echo "#######################"
    echo "create new output"
    echo "#######################"
    echo ""
    if [ -e "$FILE" ]; then
        echo ""
        echo "new output already created"
        echo ""
        output_id=$(cat "$FILE")
    else
        read -ra ips <<<"$OUTPUTS"
        hosts=""
        for ip in "${ips[@]}"; do
            hosts+="\"$ip\","
        done
        hosts="${hosts%,}"
        OUTPUT=$(curl -POST \
            --url ''"$KB_HOST"'/api/fleet/outputs' \
            -u $AUTH \
            $CACERT \
            -s \
            --header 'Content-Type: application/json' \
            --header 'kbn-xsrf: xx' \
            --data '{
                    "name": "new_output",
                    "type": "elasticsearch",
                    "hosts": [
                    '$(echo "$hosts")'
                    ],
                    "is_default": false,
                    "is_default_monitoring": false,
                    "config_yaml": "",
                    "ca_trusted_fingerprint": "9400b144a69d1d05dfc88bddaf565b16e045644a892da3cd047d7561ddba4958"
                }')
        echo ""
        echo "new output created"
        echo ""
        output_id=$(echo "$OUTPUT" | jq -c -r '.item.id')

        echo $output_id >> output_id.log
    fi


    ######## get policy id
    echo ""
    echo "#######################"
    echo "get policy id"
    echo "#######################"
    echo ""
    original_ids=()
    original_names=()
    description=()
    declare -A original_hash
    ALL_POLICY=$(curl -XGET \
        --url ''"$KB_HOST"'/api/fleet/agent_policies' \
        -u $AUTH \
        $CACERT \
        -s \
        --header 'Content-Type: application/json' \
        --header 'kbn-xsrf: xx')
    while IFS= read -r line; do
        original_ids+=("$(echo "$line" | jq -r '.id')")
        original_names+=("$(echo "$line" | jq -r '.name')")
        description+=("$(echo "$line" | jq -r '.description')")

    done <<<"$(echo "$ALL_POLICY" | jq -c '.items[] | select(.name | test("_by_script") | not)')"

    for ((i = 0; i < ${#original_ids[@]}; i++)); do
        original_hash["${original_ids[i]}"]="${original_names[i]}"
    done


    ######## policy duplicate
    echo ""
    echo "#######################"
    echo "policy duplicate"
    echo "#######################"
    echo ""
    FILE="./duplicated_policy.log"
    touch "$FILE"
    for ((i = 0; i < ${#original_ids[@]}; i++)); do
        if grep -q "${original_ids[i]}" "$FILE" ; then
            echo "${original_names[i]} already duplicated"
        else
            json_data=$(jq -n --arg name "${original_names[i]}_by_script" --arg description "${description[i]}" '{"name": $name, "description": $description}')
            TENP=$(curl -POST \
                --url ''"$KB_HOST"'/api/fleet/agent_policies/'${original_ids[i]}'/copy' \
                -u $AUTH \
                $CACERT \
                -s \
                --header 'Content-Type: application/json' \
                --header 'kbn-xsrf: xx' \
                --data "$json_data")
            echo ${original_ids[i]} >> duplicated_policy.log
            echo "${original_names[i]} duplicat complete"
        fi
        if [ $i -eq 0 ]; then
            read -p "Check ${original_names[i]}_by_script policy before moving on to the next policy"
        fi
    done



    ####### Change Output
    echo ""
    echo "#######################"
    echo "Change Output"
    echo "#######################"
    echo ""
    ALL_POLICY=$(curl -XGET \
        --url ''"$KB_HOST"'/api/fleet/agent_policies' \
        -u $AUTH \
        $CACERT \
        -s \
        --header 'Content-Type: application/json' \
        --header 'kbn-xsrf: xx')
    new_ids=()
    new_names=()
    while IFS= read -r line; do
        new_ids+=("$(echo "$line" | jq -r '.id')")
        new_names+=("$(echo "$line" | jq -r '.name')")
    done <<<"$(echo "$ALL_POLICY" | jq -c '.items[] | select(.name | contains("_by_script"))')"

    FILE="./complete_policy.log"
    touch "$FILE"
    for ((i = 0; i < ${#new_ids[@]}; i++)); do
        if grep -q "${new_ids[i]}" "$FILE" ; then
            echo "${new_names[i]} output already Changed"
        else
            ALL_POLICY=$(curl -XGET \
                --url ''"$KB_HOST"'/api/fleet/agent_policies/'${new_ids[i]}'' \
                -u $AUTH \
                $CACERT \
                -s \
                --header 'Content-Type: application/json' \
                --header 'kbn-xsrf: xx')
            temp=$(curl -XPUT \
                --url ''"$KB_HOST"'/api/fleet/agent_policies/'${new_ids[i]}'' \
                -u $AUTH \
                $CACERT \
                -s \
                --header 'Content-Type: application/json' \
                --header 'kbn-xsrf: xx' \
                --data '{
                        "name": "'"$(echo "$ALL_POLICY" | jq -r '.item.name')"'",
                        "namespace": "'"$(echo "$ALL_POLICY" | jq -r '.item.namespace')"'",
                        "monitoring_output_id": "'$output_id'",
                        "data_output_id" : "'$output_id'"
                }')
            echo ${new_ids[i]} >> complete_policy.log
            echo "${new_names[i]} output Changed"
        fi
        if [ $i -eq 0 ]; then
            read -p "Check ${new_names[i]} policy before moving on to the next policy"

        fi
    done


fi

if [ "$1" = "reassign" ]; then
    ALL_POLICY=$(curl -XGET \
        --url ''"$KB_HOST"'/api/fleet/agent_policies' \
        -u $AUTH \
        $CACERT \
        -s \
        --header 'Content-Type: application/json' \
        --header 'kbn-xsrf: xx')

    declare -A new_hash

    declare -A original_hash

    while IFS= read -r line; do
        original_ids+=("$(echo "$line" | jq -r '.id')")
        original_names+=("$(echo "$line" | jq -r '.name')")
    done <<<"$(echo "$ALL_POLICY" | jq -c '.items[] | select(.name | test("_by_script") | not)')"

    for ((i = 0; i < ${#original_ids[@]}; i++)); do
        original_hash["${original_ids[i]}"]="${original_names[i]}"
    done
    while IFS= read -r line; do
        new_ids+=("$(echo "$line" | jq -r '.id')")
        new_names+=("$(echo "$line" | jq -r '.name')")
    done <<<"$(echo "$ALL_POLICY" | jq -c '.items[] | select(.name | contains("_by_script"))')"

    for ((i = 0; i < ${#new_ids[@]}; i++)); do
        new_hash["${new_names[i]}"]="${new_ids[i]}"
    done


    agent_id=()
    agent_name=()
    agent_policy=()
    agent=$(curl -XGET \
        --url ''"$KB_HOST"'/api/fleet/agents' \
        -u $AUTH \
        $CACERT \
        -s \
        --header 'Content-Type: application/json' \
        --header 'kbn-xsrf: xx')

    while IFS= read -r line; do
        agent_id+=("$(echo "$line" | jq -r '.id')")
        agent_name+=("$(echo "$line" | jq -r '.sort[1]')")
        agent_policy+=("$(echo "$line" | jq -r '.policy_id')")
    done <<<"$(echo "$agent" | jq -c '.list[]')"

    FILE="./complete_agent.log"
    touch "$FILE"
    for ((i = 0; i < ${#agent_id[@]}; i++)); do
        if grep -q "${agent_id[i]}" "$FILE" ; then
            echo "${agent_name[i]} already reassigned"
        else
            read -p "Press Enter to ${agent_name[i]} reassiging agent"
            # echo "id: ${agent_id[i]}, name: ${agent_name[i]}, agent_policy_id:  ${agent_policy[i]}"
            original_agent_policy="${agent_policy[i]}"
            original_name="${original_hash[${original_agent_policy}]}"
            new_policy_name="${original_name}_by_script"
            new_policy_id="${new_hash[${new_policy_name}]}"

            TENP=$(
                curl -POST \
                    --url ''"$KB_HOST"'/api/fleet/agents/'${agent_id[i]}'/reassign' \
                    -u $AUTH \
                    $CACERT \
                    -s \
                    --header 'Content-Type: application/json' \
                    --header 'kbn-xsrf: xx' \
                    --data '{
                    "policy_id" : "'$new_policy_id'"
                }'
            )
            echo ${agent_id[i]} >> complete_agent.log
            echo ""
            echo "${agent_name[i]} reassign complete"
            echo ""
        fi
    done
fi


if [ "$1" = "delete_old" ]; then
    ######## get old output
    echo ""
    echo "#######################"
    echo "get policy id"
    echo "#######################"
    echo ""
    old_ids=()
    old_names=()
    declare -A old_hash
    ALL_POLICY=$(curl -XGET \
        --url ''"$KB_HOST"'/api/fleet/agent_policies' \
        -u $AUTH \
        $CACERT \
        -s \
        --header 'Content-Type: application/json' \
        --header 'kbn-xsrf: xx')

    while IFS= read -r line; do
        old_ids+=("$(echo "$line" | jq -r '.id')")
        old_names+=("$(echo "$line" | jq -r '.name')")
    done <<<"$(echo "$ALL_POLICY" | jq -c '.items[] | select(.name | contains("_by_script"))')"
    # done <<<"$(echo "$ALL_POLICY" | jq -c '.items[] | select(.name | test("_by_script") | not)')"

    ######## delete policy
    echo ""
    echo "#######################"
    echo "delete policy"
    echo "#######################"
    echo ""
    for ((i = 0; i < ${#old_ids[@]}; i++)); do
        TEMP=$(curl -POST \
            --url ''"$KB_HOST"'/api/fleet/agent_policies/delete' \
            -u $AUTH \
            $CACERT \
            -s \
            --header 'Content-Type: application/json' \
            --header 'kbn-xsrf: xx' \
            --data '{
                    "agentPolicyId" : "'${old_ids[i]}'"
                }')
            echo ${old_ids[i]} >> duplicated_policy.log
            echo "${old_names[i]} delete complete"
        # if [ $i -eq 0 ]; then
        #     read -p "Check ${original_names[i]}_by_script policy before moving on to the next policy"
        # fi
    done

fi


end_time=$(date +%s)
duration=$((end_time - start_time))
minutes=$((duration / 60))
seconds=$((duration % 60))
echo "총 소요 시간: ${minutes}분 ${seconds}초"