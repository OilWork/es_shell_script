# es_shell_script


# install_es.sh
## 가능한 기능
- ssh로 접근 가능하다는 전제
  - Elasticsearch 자동 설치 및 클러스터
  - kibana 자동 설정
- elastic agent 자동 설치
  - policy name 지정 후 각 서버에 agent 자동 설치
  - policy namespace를 기준으로 role 및 space 생성
 
## 사용법
### config.ini 설정은 현재 포맷에서 값만 변경할것
- 명령어 확인 : es_script.sh help
- Elastic Stack Install : es_script.sh stack_install
- agent 설치 및 space, role 생성 : es_script.sh full_step
- agent 설치 : es_script.sh agent_install
- space, role 생성 : es_script.sh space_role
- space 생성 : es_script.sh space
- role 생성 : es_script.sh role

  
