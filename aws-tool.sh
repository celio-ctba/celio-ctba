#!/bin/bash

# Cores
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

if [[ "${BASH_SOURCE}" == "${0}" ]]; then
    echo -e "${RED}ERRO: Execute com: source $0${NC}"
    exit 1
fi

# ==========================================
# CONFIGURAÇÕES POR AMBIENTE
# ==========================================
unset PROFILES RDS_CLUSTERS ACOES
declare -A PROFILES=( ["homol"]="sc-homol" ["prod"]="sc-prod" )

declare -A RDS_CLUSTERS=( ["homol"]="sc-db-cluster-homol" ["prod"]="sc-db-cluster-prod" )

BASTION_TAGS=("sc-ssm-bastion" "sc-power-bi-gateway")
BASTION_FALLBACK="i-0ad191c461e1e8aeb"

LOCAL_PORT=5442
REMOTE_PORT=5432

# ==========================================
# FUNÇÕES BASE
# ==========================================

selecionar_ambiente() {
    echo -e "Selecione o ambiente:"
    echo "1) Homologação (${PROFILES[homol]}) [PADRÃO]"
    echo "2) Produção (${PROFILES[prod]})"
    read -p "Opção [1-2, Enter=Homologação]: " opt
    case "${opt,,}" in
        2|"${PROFILES[prod],,}"|prod) ENV="prod" ;;
        *) ENV="homol" ;;
    esac
}

configurar_perfil() {
    local profile="$1"
    local account_id="$2"
    local config_file="$HOME/.aws/config"

    echo -e "${YELLOW}Perfil \"$profile\" não encontrado no ~/.aws/config.${NC}"
    echo -e "Deseja configurá-lo automaticamente?"
    read -p "[s/N]: " criar
    if [[ "${criar,,}" != "s" && "${criar,,}" != "sim" && "${criar,,}" != "y" && "${criar,,}" != "yes" ]]; then
        read -p "Digite o nome do perfil AWS para $ENV: " custom
        if [[ -n "$custom" ]]; then
            profile="$custom"
            PROFILES[$ENV]="$profile"
        fi
        return
    fi

    mkdir -p "$HOME/.aws"

    if ! grep -q "\[profile $profile\]" "$config_file" 2>/dev/null; then
        cat >> "$config_file" <<-EOF

[profile $profile]
sso_session = $profile
sso_account_id = $account_id
sso_role_name = AdministratorAccess
region = us-east-1
output = json
EOF
    fi

    if ! grep -q "\[sso-session $profile\]" "$config_file" 2>/dev/null; then
        cat >> "$config_file" <<-EOF

[sso-session $profile]
sso_start_url = https://d-9067e018c3.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
EOF
    fi

    echo -e "${GREEN}Configuração criada para o perfil \"$profile\"${NC}"
}

login_aws() {
    local profile="${PROFILES[$ENV]}"

    if ! grep -qxF "$profile" <<< "$(aws configure list-profiles 2>/dev/null)"; then
        [[ "$ENV" == "prod" ]] && local account_id="515966495154" || local account_id="579871531119"
        configurar_perfil "$profile" "$account_id"
        profile="${PROFILES[$ENV]}"
    fi

    echo -e "\nVerificando sessão: ${YELLOW}$profile${NC}..."
    if aws sts get-caller-identity --profile "$profile" >/dev/null 2>&1; then
        echo -e "${GREEN}Sessão válida${NC}"
    else
        echo -e "Autenticando no navegador..."
        aws sso login --profile "$profile" || {
            echo -e "${RED}Falha no login SSO${NC}"; return 1
        }
    fi
    export AWS_PROFILE="$profile"
}

buscar_bastion() {
    local env="$1" id
    local profile="${PROFILES[$env]}"
    for tag in "${BASTION_TAGS[@]}"; do
        id=$(aws ec2 describe-instances --region us-east-1 --profile "$profile" \
            --filters "Name=tag:Name,Values=${tag}-${env}" "Name=instance-state-name,Values=running" \
            --query "Reservations[0].Instances[0].InstanceId" --output text 2>/dev/null)
        if [[ -n "$id" && "$id" != "None" ]]; then
            echo "$id"
            return 0
        fi
    done
    read -p "ID da instância Bastion [${BASTION_FALLBACK}]: " manual
    echo "${manual:-$BASTION_FALLBACK}"
}

buscar_rds_endpoint() {
    local env="$1"
    local profile="${PROFILES[$env]}"
    local endpoint
    endpoint=$(aws rds describe-db-clusters --region us-east-1 --profile "$profile" \
        --db-cluster-identifier "${RDS_CLUSTERS[$env]}" \
        --query "DBClusters[0].Endpoint" --output text 2>/dev/null)
    if [[ -z "$endpoint" || "$endpoint" == "None" ]]; then
        read -p "Endpoint do RDS: " endpoint
    fi
    echo "$endpoint"
}

# ==========================================
# AÇÕES
# ==========================================

acao_rds_tunnel() {
    [[ -z "$ENV" ]] && selecionar_ambiente
    login_aws || return 1

    echo -e "\nConfigurando túnel para ${YELLOW}$ENV${NC}..."
    local bastion_id rds_endpoint profile="${PROFILES[$ENV]}"
    bastion_id=$(buscar_bastion "$ENV")
    rds_endpoint=$(buscar_rds_endpoint "$ENV")

    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN}  TÚNEL RDS ATIVO${NC}"
    echo -e "  Host:    ${YELLOW}$rds_endpoint${NC}"
    echo -e "  Local:   ${GREEN}127.0.0.1:$LOCAL_PORT${NC}"
    echo -e "  Bastion: ${BLUE}$bastion_id${NC}"
    echo -e "${YELLOW}  CTRL+C para encerrar${NC}"
    echo -e "${GREEN}====================================================${NC}\n"

    aws ssm start-session --target "$bastion_id" --region us-east-1 --profile "$profile" \
        --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters "{
            \"host\":[\"$rds_endpoint\"],
            \"portNumber\":[\"$REMOTE_PORT\"],
            \"localPortNumber\":[\"$LOCAL_PORT\"]
        }"
}

acao_console_rds() {
    [[ -z "$ENV" ]] && selecionar_ambiente
    login_aws || return 1
    local bastion_id rds_endpoint profile="${PROFILES[$ENV]}"
    bastion_id=$(buscar_bastion "$ENV")
    rds_endpoint=$(buscar_rds_endpoint "$ENV")
    echo -e "\n${GREEN}Conectando shell no bastion...${NC}\n"

    aws ssm start-session --target "$bastion_id" --region us-east-1 --profile "$profile" \
        --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters "{
            \"host\":[\"$rds_endpoint\"],
            \"portNumber\":[\"$REMOTE_PORT\"],
            \"localPortNumber\":[\"$LOCAL_PORT\"]
        }" &

    sleep 2
    echo -e "Shell interativo no bastion. RDS disponível em localhost:${LOCAL_PORT}\n"
    aws ssm start-session --target "$bastion_id" --region us-east-1 --profile "$profile"
}

acao_credenciais() {
    [[ -z "$ENV" ]] && selecionar_ambiente
    login_aws || return 1
    echo -e "\n${GREEN}====================================================${NC}"
    echo -e "${GREEN}  CREDENCIAIS ATIVAS${NC}"
    echo -e "  Perfil: ${YELLOW}$AWS_PROFILE${NC}"
    echo -e "  Conta:  $(aws sts get-caller-identity --query 'Account' --output text)"
    local arn
    arn=$(aws sts get-caller-identity --query 'Arn' --output text)
    echo -e "  Usuário: ${YELLOW}${arn##*/}${NC}"
    echo -e "${GREEN}====================================================${NC}"
}

# ==========================================
# REGISTRO DE AÇÕES (adicione novas aqui)
# ==========================================
declare -A ACOES
ACOES["1"]="acao_credenciais|Apenas credenciais AWS (terraform, awscli)"
ACOES["2"]="acao_rds_tunnel|Túnel RDS (Acesso ao Banco Postgres)"
ACOES["3"]="acao_console_rds|Console RDS (shell no bastion)"

# ==========================================
# MENU PRINCIPAL
# ==========================================
clear
echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}       Socarrao - AWS Developer Tool                ${NC}"
echo -e "${BLUE}====================================================${NC}"

selecionar_ambiente

echo -e "\nO que deseja fazer?"
for key in 1 2 3; do
    IFS='|' read -r fn desc <<< "${ACOES[$key]}"
    echo -e "  ${key}) $desc"
done
echo -e "  0) Sair"
read -p "Opção: " opt

if [[ "$opt" == "0" ]]; then
    echo -e "\n${YELLOW}Saindo...${NC}"
    return 0
fi

if [[ -n "${ACOES[$opt]}" ]]; then
    IFS='|' read -r fn desc <<< "${ACOES[$opt]}"
    $fn
else
    echo -e "${RED}Opção inválida${NC}"
    return 1
fi
