# ==============================================================================
# Script:  aws-tool.ps1
# Descricao: Ferramenta AWS para devs - Login SSO, tunel RDS, console (Windows)
# Uso:     .\scripts\aws-tool.ps1
# ==============================================================================

$RED = "Red"; $GREEN = "Green"; $YELLOW = "Yellow"
$BLUE = "Cyan"

# ==========================================
# VERIFICAR DEPENDENCIAS
# ==========================================
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Host "AWS CLI nao encontrado." -ForegroundColor $RED
    Write-Host "Instale o AWS CLI para Windows:" -ForegroundColor $YELLOW
    Write-Host "  1) winget install Amazon.AWSCLI  (recomendado)" -ForegroundColor $GREEN
    Write-Host "  Ou baixe manualmente:" -ForegroundColor $GREEN
    Write-Host "  https://awscli.amazonaws.com/AWSCLIV2.msi" -ForegroundColor $GREEN
    Write-Host "`nApos instalar, feche e abra um novo terminal."
    exit 1
}

$PROFILES = @{ "homol" = "sc-homol"; "prod" = "sc-prod" }
$RDS_CLUSTERS = @{ "homol" = "sc-db-cluster-homol"; "prod" = "sc-db-cluster-prod" }
$SSO_ROLE_NAME = "Developers"

$BASTION_TAGS = @("sc-ssm-bastion", "sc-power-bi-gateway")
$BASTION_FALLBACK = "i-0ad191c461e1e8aeb"
$LOCAL_PORT = 5442
$REMOTE_PORT = 5432

function SelecionarAmbiente {
    Write-Host "Selecione o ambiente:"
    Write-Host "1) Homologacao ($($PROFILES.homol)) [PADRAO]"
    Write-Host "2) Producao ($($PROFILES.prod))"
    $opt = Read-Host "Opcao [1-2, Enter=Homologacao]"
    if ($opt -eq "2" -or $opt -eq "prod" -or $opt -ieq $PROFILES.prod) { return "prod" }
    return "homol"
}

function ConfigurarPerfil {
    param([string]$Profile, [string]$AccountId, [string]$Ambiente)
    $configFile = "$env:USERPROFILE\.aws\config"

    Write-Host "Perfil '$Profile' nao encontrado no ~/.aws/config." -ForegroundColor $YELLOW
    Write-Host "Deseja configura-lo automaticamente? (s/N)" -NoNewline
    $criar = Read-Host
    if ($criar -notmatch '^(s|sim|y|yes)$') {
        $custom = Read-Host "Digite o nome do perfil AWS para $Ambiente"
        if ($custom) { $PROFILES[$Ambiente] = $custom; return $PROFILES[$Ambiente] }
        return $Profile
    }

    $null = New-Item -Path "$env:USERPROFILE\.aws" -ItemType Directory -Force -ErrorAction SilentlyContinue

    $roleCustom = Read-Host "SSO Role Name [$SSO_ROLE_NAME]"
    $ssoRole = if ($roleCustom) { $roleCustom } else { $SSO_ROLE_NAME }

    $configContent = @"
[profile $Profile]
sso_session = $Profile
sso_account_id = $AccountId
sso_role_name = $ssoRole
region = us-east-1
output = json

[sso-session $Profile]
sso_start_url = https://d-9067e018c3.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
"@
    Set-Content -Path $configFile -Value $configContent -Encoding ASCII

    Write-Host "Configuracao criada para o perfil '$Profile'" -ForegroundColor $GREEN
    return $Profile
}

function LoginAws {
    param([string]$Ambiente)
    $configFile = "$env:USERPROFILE\.aws\config"
    $profile = $PROFILES[$Ambiente]
    $existingProfiles = aws configure list-profiles 2>$null

    if ($existingProfiles -notcontains $profile) {
        $accountId = if ($Ambiente -eq "prod") { "515966495154" } else { "579871531119" }
        $profile = ConfigurarPerfil -Profile $profile -AccountId $AccountId -Ambiente $Ambiente
    }

    Write-Host "`nVerificando sessao: $profile..." -ForegroundColor $YELLOW
    aws sts get-caller-identity --profile $profile 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Sessao valida" -ForegroundColor $GREEN
    } else {
        Write-Host "Autenticando no navegador..." -ForegroundColor $YELLOW
        aws sso login --profile $profile
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Falha no login SSO" -ForegroundColor $RED
            $reconfig = Read-Host "Deseja recriar o arquivo de configuracao? (s/N)"
            if ($reconfig -match '^(s|sim|y|yes)$') {
                Remove-Item $configFile -Force -ErrorAction SilentlyContinue
            }
            return $false
        }
    }
    $env:AWS_PROFILE = $profile
    return $true
}

function BuscarBastion {
    param([string]$Ambiente)
    $profile = $PROFILES[$Ambiente]
    foreach ($tag in $BASTION_TAGS) {
        $id = aws ec2 describe-instances --region us-east-1 --profile $profile `
            --filters "Name=tag:Name,Values=${tag}-${Ambiente}" "Name=instance-state-name,Values=running" `
            --query "Reservations[0].Instances[0].InstanceId" --output text 2>$null
        if ($id -and $id -ne "None") { return $id }
    }
    Write-Host "Nenhuma instancia bastion encontrada para $Ambiente." -ForegroundColor $YELLOW
    $manual = Read-Host "ID da instancia Bastion [$BASTION_FALLBACK]"
    if ($manual) { return $manual } else { return $BASTION_FALLBACK }
}

function BuscarRdsEndpoint {
    param([string]$Ambiente)
    $profile = $PROFILES[$Ambiente]
    $endpoint = aws rds describe-db-clusters --region us-east-1 --profile $profile `
        --db-cluster-identifier $RDS_CLUSTERS[$Ambiente] `
        --query "DBClusters[0].Endpoint" --output text 2>$null
    if (-not $endpoint -or $endpoint -eq "None") {
        $endpoint = Read-Host "Endpoint do RDS"
    }
    return $endpoint
}

function AcaoRdsTunnel {
    param([string]$Ambiente)
    Write-Host "`nConfigurando tunel para $Ambiente..." -ForegroundColor $YELLOW
    $bastionId = BuscarBastion $Ambiente
    $rdsEndpoint = BuscarRdsEndpoint $Ambiente

    Write-Host "====================================================" -ForegroundColor $GREEN
    Write-Host "  TUNEL RDS ATIVO" -ForegroundColor $GREEN
    Write-Host "  Host:    $rdsEndpoint" -ForegroundColor $YELLOW
    Write-Host "  Local:   127.0.0.1:$LOCAL_PORT" -ForegroundColor $GREEN
    Write-Host "  Bastion: $bastionId" -ForegroundColor $BLUE
    Write-Host "  CTRL+C para encerrar" -ForegroundColor $YELLOW
    Write-Host "====================================================`n" -ForegroundColor $GREEN

    $profile = $PROFILES[$Ambiente]
    $params = '{"host":["' + $rdsEndpoint + '"],"portNumber":["' + $REMOTE_PORT + '"],"localPortNumber":["' + $LOCAL_PORT + '"]}'
    aws ssm start-session --target $bastionId --region us-east-1 --profile $profile `
        --document-name AWS-StartPortForwardingSessionToRemoteHost `
        --parameters $params
}

function AcaoConsoleRds {
    param([string]$Ambiente)
    $bastionId = BuscarBastion $Ambiente
    $rdsEndpoint = BuscarRdsEndpoint $Ambiente

    Write-Host "`nConectando shell no bastion..." -ForegroundColor $GREEN

    $profile = $PROFILES[$Ambiente]
    $job = Start-Job -ScriptBlock {
        param($id, $ep, $rport, $lport, $awsProfile)
        $jp = '{"host":["' + $ep + '"],"portNumber":["' + $rport + '"],"localPortNumber":["' + $lport + '"]}'
        aws ssm start-session --target $id --region us-east-1 --profile $awsProfile `
            --document-name AWS-StartPortForwardingSessionToRemoteHost `
            --parameters $jp
    } -ArgumentList $bastionId, $rdsEndpoint, $REMOTE_PORT, $LOCAL_PORT, $profile

    Start-Sleep 2
    Write-Host "Shell interativo no bastion. RDS disponivel em localhost:$LOCAL_PORT`n" -ForegroundColor $GREEN
    aws ssm start-session --target $bastionId --region us-east-1 --profile $profile
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -ErrorAction SilentlyContinue
}

function AcaoCredenciais {
    Write-Host "====================================================" -ForegroundColor $GREEN
    Write-Host "  CREDENCIAIS ATIVAS" -ForegroundColor $GREEN
    Write-Host "  Perfil: $env:AWS_PROFILE" -ForegroundColor $YELLOW
    $account = aws sts get-caller-identity --query "Account" --output text
    Write-Host "  Conta:  $account"
    $arn = aws sts get-caller-identity --query "Arn" --output text
    Write-Host "  Usuario: $($arn -replace '^.*/','')" -ForegroundColor $YELLOW
    Write-Host "====================================================" -ForegroundColor $GREEN
}

# ==========================================
# MENU PRINCIPAL
# ==========================================
Clear-Host
Write-Host "====================================================" -ForegroundColor $BLUE
Write-Host "       Socarrao - AWS Developer Tool (Win)          " -ForegroundColor $BLUE
Write-Host "====================================================" -ForegroundColor $BLUE

$sair = $false
do {
    $ambiente = SelecionarAmbiente
    $loggedIn = LoginAws $ambiente
    if (-not $loggedIn) { continue }

    Write-Host "`nO que deseja fazer?"
    Write-Host "  1) Apenas credenciais AWS (terraform, awscli)"
    Write-Host "  2) Tunel RDS (Acesso ao Banco Postgres)"
    Write-Host "  3) Console RDS (shell no bastion)"
    Write-Host "  0) Sair"

    $opt = Read-Host "Opcao"

    switch ($opt) {
        "1" { AcaoCredenciais }
        "2" { AcaoRdsTunnel $ambiente }
        "3" { AcaoConsoleRds $ambiente }
        "0" { Write-Host "`nSaindo..." -ForegroundColor $YELLOW; $sair = $true }
        Default { Write-Host "Opcao invalida" -ForegroundColor $RED }
    }

    if (-not $sair) {
        Write-Host "`nPressione Enter para voltar ao menu..."
        $null = Read-Host
        Clear-Host
    }
} while (-not $sair)
