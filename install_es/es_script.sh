#!/bin/bash

set -Eeo pipefail

start_time=$(date +%s)

if [ -z "$1" ] || [ "$1" = "help" ]; then
    echo "주의 : 실행전 config.ini 설정을 확인하고 실행할것"
    echo "설정의 대부분을 사용하기 때문에 비워두지 말것"
    sleep 2
    echo "elasticsearch, kibana 설치 : stack_install"
    echo "agent 설치 및 space, role 생성 : full_step"
    echo "agent 설치 : agent_install"
    echo "space, role 생성 : space_role"
    echo "space 생성 : space"
    echo "role 생성 : role"
    exit 1
fi

## config.ini 읽어오는 함수
function read_config()
{
    PATH_TO_CONFIG=$(pwd)/config.ini
    AWK_PATH=$(command -v awk)
    A="$($AWK_PATH -F '=' '/^'"$1"'/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' $PATH_TO_CONFIG)"
    CONFIG=$(echo "$A" | tr -d '[]')

    IFS=', ' read -ra CONFIG_ARRAY <<< "$CONFIG"
    echo "${CONFIG_ARRAY[@]}"
}

function install_stack()
{
    SSH_PATH=$(read_config ssh_file)
    INSTALL_HOST=$(read_config install_es)
    HOST_NAME=$(read_config es_hostname)
    IFS=' ' read -ra INSTALL_HOST <<< "$INSTALL_HOST"
    IFS=' ' read -ra HOST_NAME <<< "$HOST_NAME"
    # 두 배열의 길이가 같은지 확인
    if [ "${#INSTALL_HOST[@]}" -ne "${#HOST_NAME[@]}" ] && [ "${#HOST_NAME[@]}" -ne 1 ]; then
        echo "Error: IP 주소와 사용자 이름의 수가 일치하지 않습니다."
        echo "만약 동일한 사용자 이름이 아니라면 IP주소의 길이와 맞춰서 입력하세요"
        exit 1
    fi
    if [ "${#INSTALL_HOST[@]}" -ne 1 ]; then
        for ((i=${#HOST_NAME[@]}; i<${#INSTALL_HOST[@]}; i++)); do
            HOST_NAME[i]=${HOST_NAME[0]}
        done
    fi
    VERSION=$(read_config version)
    ES_DATA=$(read_config es_data)
    ES_LOGS=$(read_config es_log)
    if [ "$ES_DATA" = "" ]; then
        ES_DATA="/var/lib/elasticsearch"
    fi
    if [ "$ES_LOGS" = "" ]; then
        ES_LOGS="/var/log/elasticsearch"
    fi
    NODE_TOKEN=""
    KIBANA_TOKEN=""
    ## es 부분
    for ((i=0; i<${#INSTALL_HOST[@]}; i++)); do
        ssh-keyscan -H "${INSTALL_HOST[i]}" >> ~/.ssh/known_hosts 2>/dev/null
        ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab; echo '* hard nproc 65535' | sudo tee -a /etc/security/limits.conf > /dev/null; echo '* soft nproc 65535' | sudo tee -a /etc/security/limits.conf > /dev/null; echo '* hard nofile 65535' | sudo tee -a /etc/security/limits.conf > /dev/null; echo '* soft nofile 65535' | sudo tee -a /etc/security/limits.conf > /dev/null; echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf > /dev/null;"
        OS_INFO=$(ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "cat /etc/os-release;")
        OS_INFO=$(echo "$OS_INFO" | grep '^ID=' | awk -F'=' '{print $2}' | tr -d '"')
        if [ "$i" -eq 0 ]; then
            if [ "$OS_INFO" = "centos" ] || [ "$OS_INFO" = "rocky" ] || [ "$OS_INFO" = "fedora" ] || [ "$OS_INFO" = "rhel" ]; then
                ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "sudo yum install -q -y wget; sudo wget --no-verbose https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$VERSION-x86_64.rpm; sudo rpm --install elasticsearch-$VERSION-x86_64.rpm > /dev/null 2>&1;"
            else
                ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "sudo apt-get install -q -y wget; sudo wget --no-verbose https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$VERSION-amd64.deb; sudo dpkg -i elasticsearch-$VERSION-amd64.deb > /dev/null 2>&1;"
            fi
            ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "sudo mkdir -p /etc/systemd/system/elasticsearch.service.d/; echo '[Service]' | sudo tee -a /etc/systemd/system/elasticsearch.service.d/override.conf > /dev/null; sudo echo 'LimitMEMLOCK=infinity' | sudo tee -a /etc/systemd/system/elasticsearch.service.d/override.conf > /dev/null; sudo systemctl daemon-reload;"
            printf "$(read_config super_pw)\n$(read_config super_pw)" | ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "sudo sed -i 's/^#transport.host: 0.0.0.0/transport.host: 0.0.0.0/' /etc/elasticsearch/elasticsearch.yml; sudo sed -i 's/^#network.host: 192.168.0.1/network.host: 0.0.0.0/' /etc/elasticsearch/elasticsearch.yml; sudo mkdir $ES_DATA; sudo mkdir $ES_LOGS; sudo chown -R elasticsearch:elasticsearch $ES_DATA; sudo chown -R elasticsearch:elasticsearch $ES_LOGS; sudo sed -i 's|^path.data: /var/lib/elasticsearch|path.data: "$ES_DATA"|' /etc/elasticsearch/elasticsearch.yml; sudo sed -i 's|^path.logs: /var/log/elasticsearch|path.logs: "$ES_LOGS"|' /etc/elasticsearch/elasticsearch.yml; sudo systemctl start elasticsearch.service; sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -i -b -u elastic;"
            NODE_TOKEN=$(ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "sudo /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s node")
            KIBANA_TOKEN=$(ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "sudo /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana;")
            echo "************************************************************************"
            echo "install elasticsearch first node on ${HOST_NAME[i]}@${INSTALL_HOST[i]} complete"
            echo "************************************************************************"
        else
            if [ "$OS_INFO" = "centos" ] || [ "$OS_INFO" = "rocky" ] || [ "$OS_INFO" = "fedora" ] || [ "$OS_INFO" = "rhel" ]; then
                ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "sudo yum install -q -y wget; sudo wget --no-verbose https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$VERSION-x86_64.rpm; sudo rpm --install elasticsearch-$VERSION-x86_64.rpm > /dev/null 2>&1;"
            else
                ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "sudo apt-get install -q -y wget; sudo wget --no-verbose https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$VERSION-amd64.deb; sudo dpkg -i elasticsearch-$VERSION-amd64.deb > /dev/null 2>&1;"
            fi
            ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "sudo mkdir -p /etc/systemd/system/elasticsearch.service.d/; echo '[Service]' | sudo tee -a /etc/systemd/system/elasticsearch.service.d/override.conf > /dev/null; sudo echo 'LimitMEMLOCK=infinity' | sudo tee -a /etc/systemd/system/elasticsearch.service.d/override.conf > /dev/null; sudo systemctl daemon-reload;"
            echo -e 'y' | ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "sudo /usr/share/elasticsearch/bin/elasticsearch-reconfigure-node --enrollment-token $NODE_TOKEN;"
            ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "sudo sed -i 's/^#network.host: 192.168.0.1/network.host: 0.0.0.0/' /etc/elasticsearch/elasticsearch.yml; sudo mkdir $ES_DATA; sudo mkdir $ES_LOGS; sudo chown -R elasticsearch:elasticsearch $ES_DATA; sudo chown -R elasticsearch:elasticsearch $ES_LOGS; sudo sed -i 's|^path.data: /var/lib/elasticsearch|path.data: "$ES_DATA"|' /etc/elasticsearch/elasticsearch.yml; sudo sed -i 's|^path.logs: /var/log/elasticsearch|path.logs: "$ES_LOGS"|' /etc/elasticsearch/elasticsearch.yml; sudo systemctl start elasticsearch.service;"
            echo "************************************************************************"
            echo "install elasticsearch rest node on ${HOST_NAME[i]}@${INSTALL_HOST[i]} complete"
            echo "************************************************************************"
        fi
    done
    ## kb 부분
    ssh-keyscan -H "$(read_config install_kb)" >> ~/.ssh/known_hosts 2>/dev/null
    OS_INFO=$(ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" "$(read_config kb_hostname)@$(read_config install_kb)" "cat /etc/os-release;")
    OS_INFO=$(echo "$OS_INFO" | grep '^ID=' | awk -F'=' '{print $2}' | tr -d '"')
    if [ "$OS_INFO" = "centos" ] || [ "$OS_INFO" = "rocky" ] || [ "$OS_INFO" = "fedora" ] || [ "$OS_INFO" = "rhel" ]; then
        ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" "$(read_config kb_hostname)@$(read_config install_kb)" "sudo yum install -q -y wget; sudo wget --no-verbose https://artifacts.elastic.co/downloads/kibana/kibana-$VERSION-x86_64.rpm; sudo rpm --install kibana-$VERSION-x86_64.rpm > /dev/null 2>&1;"
    else
        ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" "$(read_config kb_hostname)@$(read_config install_kb)" "sudo apt-get install -q -y wget; sudo wget --no-verbose https://artifacts.elastic.co/downloads/kibana/kibana-$VERSION-amd64.deb; sudo dpkg -i kibana-$VERSION-amd64.deb > /dev/null 2>&1;"
    fi
    echo -e 'y' | ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" "$(read_config kb_hostname)@$(read_config install_kb)" 'sudo systemctl start kibana; sudo /usr/share/kibana/bin/kibana-setup -t '$KIBANA_TOKEN'; sudo systemctl restart kibana;'
    ssh -o ConnectTimeout=9999 -o BatchMode=yes -i "$SSH_PATH" "$(read_config kb_hostname)@$(read_config install_kb)" "sudo sed -i 's/^#server.host: \"localhost\"/server.host: \"0.0.0.0\"/' /etc/kibana/kibana.yml;"
    echo "************************************************************************"
    echo "install kibana on $(read_config kb_hostname)@$(read_config install_kb) complete"
    echo "************************************************************************"
    exit 1
}

KB_HOST=$(read_config kbhost)
ES_HOST=$(read_config eshost)
AUTH=""$(read_config user)":"$(read_config pw)""
POLICY_ID=""
POLICY_NAMESPACE=""
ENROLLMENT_TOKEN=""
CACERT=""
## policy id 획득
if [ "$1" != "stack_install" ]; then
    OS_INFO=$(cat /etc/os-release;)
    OS_INFO=$(echo "$OS_INFO" | grep '^ID=' | awk -F'=' '{print $2}' | tr -d '"')
    if [ "$OS_INFO" = "centos" ]; then
        echo "jq install"
        sudo yum install -q -y jq;
    else
        echo "jq install"
        sudo apt-get install -q -y jq;
    fi
    if [ "$CACERT" != "" ]; then
        CACERT="--cacert $(read_config curl_cert)"
    fi
    ALL_POLICY=$(curl -XGET \
    --url ''"$KB_HOST"'/api/fleet/agent_policies' \
    -u $AUTH \
    $CACERT \
    -s \
    --header 'Content-Type: application/json' \
    --header 'kbn-xsrf: xx')
    POLICEIS=$(echo $ALL_POLICY | jq .items)
    POLICY_NAME=$(read_config policy_name)
    ID="none"
    while IFS= read -r line; do
        if [[ "$(echo "${line}" | jq -r '.name')" == "$(echo "$POLICY_NAME" | sed 's/"//g')" ]]; then
            ID=$line
        fi
    done <<< "$(echo "${POLICEIS}" | jq -c '.[]')"
    POLICY_ID=$(echo $ID | jq .id)
    POLICY_NAMESPACE=$(echo $ID | jq .namespace)
fi
## enroll token 획득
function get_token()
{
    ALL_TOKENS=$(curl -XGET \
    --url ''"$KB_HOST"'/api/fleet/enrollment_api_keys' \
    -u $AUTH \
    -s \
    --header 'Content-Type: application/json' \
    --header 'kbn-xsrf: xx' \
    $CACERT)
    TOKENS=$(echo $ALL_TOKENS | jq .items)
    TOKEN="none"
    while IFS= read -r line; do
        if [[ "$(echo "${line}" | jq -r '.policy_id')" == "$(echo "$POLICY_ID" | sed 's/"//g')" ]]; then
            TOKEN=$line
        fi
    done <<< "$(echo "${TOKENS}" | jq -c '.[]')"
    ENROLLMENT_TOKEN=$(echo $TOKEN | jq .api_key)
}


# agent 설치
function install_agent()
{
    INSTALL_HOST=$(read_config install_policy)
    HOST_NAME=$(read_config install_hostname)
    SSH_PATH=$(read_config ssh_file)
    IFS=' ' read -ra INSTALL_HOST <<< "$INSTALL_HOST"
    IFS=' ' read -ra HOST_NAME <<< "$HOST_NAME"
    # 두 배열의 길이가 같은지 확인
    if [ "${#INSTALL_HOST[@]}" -ne "${#HOST_NAME[@]}" ] && [ "${#HOST_NAME[@]}" -ne 1 ]; then
        echo "Error: IP 주소와 사용자 이름의 수가 일치하지 않습니다."
        echo "만약 동일한 사용자 이름이 아니라면 IP주소의 길이와 맞춰서 입력하세요"
        exit 1
    fi
    if [ "${#INSTALL_HOST[@]}" -ne 1 ]; then
        for ((i=${#HOST_NAME[@]}; i<${#INSTALL_HOST[@]}; i++)); do
            HOST_NAME[i]=${HOST_NAME[0]}
        done
    fi
    for ((i=0; i<${#INSTALL_HOST[@]}; i++)); do
        echo "install server host : ${HOST_NAME[i]}@${INSTALL_HOST[i]}"
        ## agent 설치 부분
        echo -e "y" | ssh -i "$SSH_PATH" ${HOST_NAME[i]}@${INSTALL_HOST[i]} "curl -L -O https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-8.11.0-linux-x86_64.tar.gz; tar xzf elastic-agent-8.11.0-linux-x86_64.tar.gz; cd elastic-agent-8.11.0-linux-x86_64; sudo ./elastic-agent install --url=https://57abe83a16394a4f999271d3e7385517.fleet.ap-northeast-2.aws.elastic-cloud.com:443 --enrollment-token=$(echo "$ENROLLMENT_TOKEN" | sed 's/"//g');" &
        pid=$!
        wait $pid
        ## enroll 확인 부분
        CHECK_RESPONSE=""
        CHECK_ENROLL=""
        CHECK_INCOME_DATA=""
        AGENT_ID=""
        while [ "$CHECK_ENROLL" != "Running" ]; do
            CHECK_RESPONSE=$(curl -XGET \
                --url ""$KB_HOST"/api/fleet/agents?kuery=fleet-agents.policy_id%3A%22$(echo "$POLICY_ID" | sed 's/"//g')%22%20and%20not%20(_exists_%3A%22fleet-agents.unenrolled_at%22)%20and%20fleet-agents.enrolled_at%20%3E%3D%20now-10m&showInactive=false" \
                --header 'kbn-xsrf: xx' \
                -s \
                -u $AUTH \
                $CACERT)
            wait $!
            CHECK_ENROLL=$(echo $CHECK_RESPONSE | jq .list | jq -c '.[]' | jq .last_checkin_message | sed 's/"//g' )
            CHECK_ENROLL=$(echo ${CHECK_ENROLL[0]} | sed 's/ .*//')
            echo "agent status : $CHECK_ENROLL" 
            sleep 3
        done
        ## AGENT ID를 통해 DATA INCOME 확인
        AGENT_ID=$(echo $CHECK_RESPONSE | jq .list | jq -c '.[]' | jq .id | sed 's/"//g' )
        AGENT_ID=$(echo ${AGENT_ID[0]} | sed 's/ .*//')
        while [ "$CHECK_INCOME_DATA" != "true" ]; do
            CHECK_RESPONSE=$(curl -XGET \
            --url ""$KB_HOST"/api/fleet/agent_status/data?agentsIds=$(echo "$AGENT_ID" | sed 's/"//g')" \
            --header 'kbn-xsrf: xx' \
            -s \
            -u $AUTH \
            $CACERT)
            CHECK_INCOME_DATA=$(echo $CHECK_RESPONSE | jq .items | jq -c '.[]' | jq --arg key "$AGENT_ID" '.[$key].data' | sed 's/"//g' )
            echo "Incomeing data : $CHECK_INCOME_DATA"
            sleep 2
        done
        echo "************************************************************************"
        echo "install agent on ${HOST_NAME[i]}@${INSTALL_HOST[i]} complete"
        echo "************************************************************************"
    done
}

## space 생성
function create_space()
{
    temp=$(curl -XPOST \
    --url ''"$KB_HOST"'/api/spaces/space' \
    -u $AUTH \
    --header 'kbn-xsrf: xxx' \
    --header 'Content-Type: application/json' \
    -s \
    $CACERT \
    --data '{
    "id": "'"$(read_config space_id)"'",
    "name": "'"$(read_config space_name)"'",
    "description" : "'"$(read_config description)"'",
    "color": "'"$(read_config color)"'",
    "initials": "'"$(read_config initials)"'",
    "disabledFeatures": ['"$(read_config disabledFeatures | sed 's/\([^ ]\+\)/"\1",/g' | sed 's/,$//')"']
    }'
    )
    echo "space name : $(read_config space_name)"
    echo "************************************************************************"
    echo "create space complete"
    echo "************************************************************************"
}


## role 생성
function create_role()
{
    curl -XPUT \
    --url ''"$KB_HOST"'/api/security/role/'$(read_config role_name)'' \
    -u $AUTH \
    --header 'kbn-xsrf: xxx' \
    --header 'Content-Type: application/json' \
    -s \
    $CACERT \
    --data '{
    "elasticsearch": {
        "cluster": [
        "all"
        ],
        "indices": [
        {
            "names": [
            "*'$(echo "$POLICY_NAMESPACE" | sed 's/"//g')'*"
            ],
            "privileges": [
            "'$(read_config indices_privileges)'"
            ]
        }
        ]
    },
    "kibana": [
        {
        "base": [
            "'"$(read_config role_base)"'"
        ],
        "feature": {},
        "spaces": [
            "'"$(read_config space_id)"'"
        ]
        }
    ]
    }'
    echo "role name : $(read_config role_name)"
    echo "************************************************************************"
    echo "create role complete"
    echo "************************************************************************"
}



## 실제 작동부


case $1 in
    "stack_install")
        install_stack;
        ;;
    "full_step")
        get_token;
        install_agent;
        create_space;
        create_role;
        ;;
    "agent_install")
        get_token;
        install_agent;
        ;;
    "space_role")
        create_space;
        create_role;
        ;;
    "space")
        create_space;
        ;;
    "role")
        create_role;
        ;;
    *)
        echo "Command Error"
        echo "Check help"
        ;;
esac
end_time=$(date +%s)
duration=$((end_time - start_time))
minutes=$((duration / 60))
seconds=$((duration % 60))
echo "총 소요 시간: ${minutes}분 ${seconds}초"
