#!/usr/bin/env bash
#===============================================================================
# install-monit-ilert.sh
#
# Instalador do Monit integrado ao ilert (Events API + Heartbeat).
#
# O QUE FAZ:
#   1. Detecta a distro e instala dependencias (monit, curl)
#   2. Pergunta/recebe as chaves do ilert e grava em /etc/ilert.env (chmod 600)
#   3. Instala /usr/local/bin/ilert.sh e /usr/local/bin/ilert-beat.sh
#   4. Escreve o monitrc base (com backup do existente)
#   5. Calcula limiares a partir do hardware real (nproc, RAM, tamanho dos discos)
#   6. Detecta servicos instalados e pergunta quais monitorar:
#        mariadb/mysql, postgresql, docker, apache2/httpd, nginx, php*-fpm
#   7. Gera os checks em conf.d, valida com `monit -t` e sobe o servico
#   8. Envia um evento de teste e pinga o heartbeat
#
# USO INTERATIVO:
#   sudo ./install-monit-ilert.sh
#
# USO NAO-INTERATIVO (Ansible/cloud-init):
#   sudo ./install-monit-ilert.sh --yes \
#        --key il1a2b... --heartbeat-key il1hbt... \
#        --env prod --services nginx,mariadb,php8.2-fpm
#
# OUTRAS FLAGS:
#   --key-file ARQ      le a integration key de um arquivo (nao vaza em ps)
#   --heartbeat-key V   key OU URL completa do heartbeat monitor
#   --env AMBIENTE      valor do label 'env' (default prod)
#   --services LISTA    servicos a monitorar, separados por virgula
#   --beat-url URL      base do ping de heartbeat, sem a chave
#                       (default: https://api.ilert.com/api/v1/heartbeats)
#   --no-heartbeat      nao configura heartbeat
#   --gateway IP        host para o check de conectividade ICMP
#   --swap-warn N       % de swap para warning (default 10)
#   --swap-crit N       % de swap para critical (default 30)
#   --warn-priority P   LOW (default) ou HIGH para warnings de recurso
#   --auto-restart MODO safe (default) = reinicia nginx/apache/php-fpm/redis
#                       all = inclui bancos e docker | none = so alerta.
#                       Em qualquer modo o Monit desiste apos 3 restarts em
#                       20 ciclos e escala SEV1 via ilert-giveup.sh.
#   --resolve-name NOME nome usado no teste de resolucao (default google.com)
#   --connectivity MODO auto (default) = testa ICMP e usa TCP 443 se bloqueado
#                       icmp | tcp | none
#   --ping-target IP    alvo externo de ICMP e DNS (default 1.1.1.1).
#                       Use IP, nao nome: ping por nome vira dois testes num so.
#   --ports LISTA       servicos TCP a checar. Formato de cada item:
#                         nome:porta                  (host 127.0.0.1)
#                         nome:host:porta
#                         nome:porta:protocolo
#                         nome:host:porta:protocolo
#                       ex: "app:8080,api:3000:http,db:10.0.0.5:5432:pgsql"
#                       sem a flag, detecta portas publicadas do Docker
#   --host NOME         nome do host nos alertas (default: hostname)
#   --dry-run           mostra o que faria, sem escrever nada
#   --uninstall         remove tudo que este script instalou
#   --help
#
# REQUISITOS: root, systemd, bash 4+
#===============================================================================
set -euo pipefail

SCRIPT_VERSION="2.16.1"
BIN_DIR="/usr/local/bin"
ENV_FILE="/etc/ilert.env"
API_URL="https://api.ilert.com/api/events"
# ATENCAO - erro comum: a "Integration key" que aparece na tela do ALERT SOURCE
# do tipo Heartbeat (prefixo il1hb2...) NAO e pingavel. Ela so identifica o
# destino do alerta. A chave que se pinga vem do HEARTBEAT MONITOR, criado em
# Alert sources -> Heartbeat monitors, e aparece na tela de detalhes dele.
# Usar a chave do alert source devolve HTTP 400.
#   heartbeat monitor      -> https://beat.ilert.com/api/pings/<key>       (default)
#   heartbeat alert source -> https://api.ilert.com/api/v1/heartbeats/<il1hbt...>
BEAT_URL="${ILERT_BEAT_URL:-https://beat.ilert.com/api/pings}"
STAMP="$(date +%Y%m%d-%H%M%S)"

# defaults sobrescritos por flags
ASSUME_YES=0
DRY_RUN=0
DO_UNINSTALL=0
WANT_HEARTBEAT=1
# Chaves tambem podem vir do ambiente (preferivel a --key, que aparece em
# `ps` e no history do shell).
ILERT_KEY="${ILERT_KEY:-}"
ILERT_HEARTBEAT_KEY="${ILERT_HEARTBEAT_KEY:-}"
ILERT_ENV="${ILERT_ENV:-prod}"
SERVICES_ARG=""
GATEWAY=""
ILERT_SWAP_WARN="${ILERT_SWAP_WARN:-}"
ILERT_SWAP_CRIT="${ILERT_SWAP_CRIT:-}"
PORTS_ARG=""
PING_TARGET="${ILERT_PING_TARGET:-1.1.1.1}"
# Auto-restart: 'safe' = web/php/cache (stateless, restart barato)
#               'all'  = inclui bancos e docker (leia o README antes)
#               'none' = so alerta
RESTART_MODE="${ILERT_RESTART_MODE:-safe}"
# Warnings de recurso (load/mem/swap/disco/cpu) saem como LOW: registram no
# ilert sem acionar a escalation policy. Sem isso, disco em 86% e em 96% geram
# DOIS alertas HIGH do mesmo assunto, acordando alguem duas vezes pelo mesmo
# problema. Falhas de disponibilidade (processo caido, porta fora) seguem HIGH.
WARN_PRIO="${ILERT_WARN_PRIORITY:-LOW}"
# auto  = testa ICMP na instalacao e cai para TCP 443 quando bloqueado
# icmp  = forca ICMP | tcp = forca TCP 443 | none = sem check de rede
CONNECTIVITY="${ILERT_CONNECTIVITY:-auto}"
# Nome usado para validar a resolucao. Prefira um dominio de terceiro, estavel
# e sem CDN geolocalizada esquisita.
RESOLVE_NAME="${ILERT_RESOLVE_NAME:-google.com}"
RESTART_LIMIT="${ILERT_RESTART_LIMIT:-3}"
RESTART_WINDOW="${ILERT_RESTART_WINDOW:-20}"
ILERT_HOST="${ILERT_HOST:-}"
ILERT_HEARTBEAT_URL="${ILERT_HEARTBEAT_URL:-}"
ILERT_RESOLVE_DELAY="${ILERT_RESOLVE_DELAY:-}"

#------------------------------------------------------------------------------
# saida
#------------------------------------------------------------------------------
c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_red=$'\033[31m'
c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_blu=$'\033[36m'
[ -t 1 ] || { c_reset=; c_bold=; c_red=; c_grn=; c_yel=; c_blu=; }

info()  { printf '%s==>%s %s\n' "$c_blu" "$c_reset" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn()  { printf '%s  !!%s %s\n' "$c_yel" "$c_reset" "$*" >&2; }
die()   { printf '%s ERRO%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }
head1() { printf '\n%s%s%s\n' "$c_bold" "$*" "$c_reset"; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# Backups NAO ficam ao lado do original: em /etc/monit/conf.d isso e inofensivo,
# mas em /usr/local/bin gera arquivos executaveis no PATH que confundem
# auditoria e ficam para sempre. Todos vao para um diretorio proprio.
BACKUP_DIR="/var/backups/monit-ilert"

backup_path() { # backup_path <arquivo> -> caminho do backup
  printf '%s/%s.bak-%s' "$BACKUP_DIR" "$(printf '%s' "${1#/}" | tr '/' '_')" "$STAMP"
}

write_file() { # write_file <path> <mode>  (conteudo via stdin)
  local path="$1" mode="$2" tmp bak
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] escreveria %s (%s)\n' "$path" "$mode"
    cat >/dev/null
    return
  fi
  tmp="$(mktemp)"
  cat >"$tmp"
  # Idempotencia: se o conteudo nao mudou, nao reescreve nem cria backup.
  # Sem isso, cada re-execucao acumula um .bak inutil.
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    ok "inalterado $path"
    return
  fi
  if [ -f "$path" ]; then
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    bak="$(backup_path "$path")"
    cp -a "$path" "$bak"
    warn "backup: $bak"
  fi
  install -o root -g root -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  WRITTEN+=("$path")
  ok "escrito $path"
}

#------------------------------------------------------------------------------
# argumentos
#------------------------------------------------------------------------------
# Imprime o cabecalho inteiro, delimitado pelas duas reguas '#====='. Faixa
# fixa de linhas quebrava em silencio a cada flag nova: o help truncava no meio
# e as ultimas opcoes sumiam sem ninguem perceber.
usage() {
  awk 'NR>1 && /^#={10,}/ {n++; next} n==1 {print}' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)          ASSUME_YES=1 ;;
    --key)             ILERT_KEY="${2:?}"; shift ;;
    --key-file)        ILERT_KEY="$(tr -d '[:space:]' < "${2:?}")"; shift ;;
    --heartbeat-key)   case "${2:?}" in http*) ILERT_HEARTBEAT_URL="$2" ;;
                                        *) ILERT_HEARTBEAT_KEY="$2" ;; esac; shift ;;
    --beat-url)        BEAT_URL="${2:?}"; shift ;;
    --env)             ILERT_ENV="${2:?}"; shift ;;
    --services)        SERVICES_ARG="${2:?}"; shift ;;
    --gateway)         GATEWAY="${2:?}"; shift ;;
    --ping-target)     PING_TARGET="${2:?}"; shift ;;
    --connectivity)    CONNECTIVITY="${2:?}"; shift ;;
    --resolve-name)    RESOLVE_NAME="${2:?}"; shift ;;
    --auto-restart)    RESTART_MODE="${2:?}"; shift ;;
    --warn-priority)   WARN_PRIO="${2:?}"; shift ;;
    --swap-warn)       ILERT_SWAP_WARN="${2:?}"; shift ;;
    --swap-crit)       ILERT_SWAP_CRIT="${2:?}"; shift ;;
    --ports)           PORTS_ARG="${2:?}"; shift ;;
    --host)            ILERT_HOST="${2:?}"; shift ;;
    --no-heartbeat)    WANT_HEARTBEAT=0 ;;
    --dry-run)         DRY_RUN=1 ;;
    --uninstall)       DO_UNINSTALL=1 ;;
    --help|-h)         usage ;;
    *) die "argumento desconhecido: $1 (use --help)" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "execute como root (sudo $0)"

#------------------------------------------------------------------------------
# deteccao de distro
#------------------------------------------------------------------------------
detect_distro() {
  [ -r /etc/os-release ] || die "/etc/os-release ausente; distro nao suportada"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"
  case "$OS_ID $OS_LIKE" in
    *debian*|*ubuntu*) PKG=apt;  MONIT_DIR=/etc/monit;    CONF_D=/etc/monit/conf.d ;;
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*)
                       PKG=dnf;  MONIT_DIR=/etc;          CONF_D=/etc/monit.d ;;
    *alpine*)          PKG=apk;  MONIT_DIR=/etc;          CONF_D=/etc/monit.d ;;
    *suse*)            PKG=zypper; MONIT_DIR=/etc;        CONF_D=/etc/monit.d ;;
    *) die "distro nao suportada: $OS_ID" ;;
  esac
  MONITRC="$MONIT_DIR/monitrc"
  ok "distro: ${PRETTY_NAME:-$OS_ID} | pkg: $PKG | conf.d: $CONF_D"
}

install_deps() {
  head1 "1. Dependencias"
  local missing=()
  command -v curl  >/dev/null || missing+=(curl)
  command -v monit >/dev/null || missing+=(monit)
  if [ ${#missing[@]} -eq 0 ]; then ok "curl e monit ja presentes"; return; fi
  info "instalando: ${missing[*]}"
  case "$PKG" in
    apt)
      run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
      run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
      ;;
    dnf)
      if [[ " ${missing[*]} " == *" monit "* ]]; then
        rpm -q epel-release >/dev/null 2>&1 || run dnf install -y -q epel-release
      fi
      run dnf install -y -q "${missing[@]}"
      ;;
    apk)    run apk add --no-cache "${missing[@]}" bash ;;
    zypper) run zypper -n install "${missing[@]}" ;;
  esac
  ok "dependencias instaladas"
}

#------------------------------------------------------------------------------
# prompts
#------------------------------------------------------------------------------
# Com 'curl ... | bash', o stdin e o proprio script, entao testar '-t 0' daria
# falso negativo e o instalador cairia em modo nao-interativo. O que importa e
# haver um terminal em /dev/tty, que e de onde as respostas sao lidas.
# '[ -r /dev/tty ]' so checa permissao: o arquivo pode existir e a abertura
# falhar com ENXIO (container sem terminal). Por isso o teste e abrir mesmo.
have_tty() { { : < /dev/tty; } 2>/dev/null; }

ask() { # ask <pergunta> <default>  -> stdout
  local q="$1" def="${2:-}" ans
  if [ "$ASSUME_YES" -eq 1 ] || ! have_tty; then printf '%s' "$def"; return; fi
  printf '%s%s: ' "$q" "${def:+ [$def]}" > /dev/tty
  read -r ans < /dev/tty || printf '\n' > /dev/tty
  printf '%s' "${ans:-$def}"
}

confirm() { # confirm <pergunta> <default y|n>
  local q="$1" def="${2:-y}" ans
  if [ "$ASSUME_YES" -eq 1 ] || ! have_tty; then [ "$def" = y ]; return; fi
  printf '%s [%s]: ' "$q" "$( [ "$def" = y ] && echo 'S/n' || echo 's/N')" > /dev/tty
  read -r ans < /dev/tty || printf '\n' > /dev/tty
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[sSyY] ]]
}

collect_keys() {
  head1 "2. Credenciais ilert"
  # Reexecucao precisa PRESERVAR o que o operador ajustou a mao no env
  # (URL de heartbeat, delay, nome do host). Sem isso, reinstalar quebraria
  # de novo o que ja tinha sido consertado.
  # Precedencia: flag/ambiente desta execucao > valor no arquivo > default.
  local f_key="$ILERT_KEY" f_hb="$ILERT_HEARTBEAT_KEY" f_env="$ILERT_ENV"
  local f_host="$ILERT_HOST" f_beat="$BEAT_URL"
  if [ -r "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    ok "configuracao existente lida de $ENV_FILE"
  fi
  ILERT_KEY="${f_key:-${ILERT_KEY:-}}"
  ILERT_HEARTBEAT_KEY="${f_hb:-${ILERT_HEARTBEAT_KEY:-}}"
  ILERT_ENV="${f_env:-${ILERT_ENV:-prod}}"
  ILERT_HOST="${f_host:-${ILERT_HOST:-}}"
  BEAT_URL="${f_beat:-${ILERT_BEAT_URL:-$BEAT_URL}}"
  ILERT_HEARTBEAT_URL="${ILERT_HEARTBEAT_URL:-}"
  ILERT_RESOLVE_DELAY="${ILERT_RESOLVE_DELAY:-300}"
  # URL completa preenchida dispensa a chave separada
  [ -n "$ILERT_HEARTBEAT_URL" ] && { ILERT_HEARTBEAT_KEY="${ILERT_HEARTBEAT_KEY:-}"; \
    WANT_HEARTBEAT=1; ok "heartbeat via URL completa preservada"; }
  local tries=0
  while [ -z "$ILERT_KEY" ]; do
    if [ "$ASSUME_YES" -eq 1 ] || ! have_tty; then
      die "modo nao-interativo sem integration key. Use --key, --key-file ou ILERT_KEY=..."
    fi
    # Sem este limite, um EOF (Ctrl-D) faria 'ask' devolver vazio para sempre e
    # o laco giraria infinitamente imprimindo o prompt.
    tries=$((tries + 1))
    [ "$tries" -le 3 ] || die "integration key nao informada apos 3 tentativas"
    echo "  Crie um alert source do tipo API/Webhook no ilert e copie a integration key."
    ILERT_KEY="$(ask '  Integration key' '')"
    [ -n "$ILERT_KEY" ] || warn "a chave e obrigatoria"
  done
  if [ "$WANT_HEARTBEAT" -eq 1 ] && [ -z "$ILERT_HEARTBEAT_KEY" ] \
     && [ -z "$ILERT_HEARTBEAT_URL" ]; then
      echo "  Em Alert sources -> Heartbeat monitors, crie um MONITOR (nao um"
    echo "  alert source) com intervalo de 15 min. Cole aqui a URL de integracao"
    echo "  INTEIRA ou so a key - o script aceita os dois."
    echo "  A key do alert source (il1hb2...) NAO funciona para ping."
    echo "  Deixe vazio para pular o heartbeat."
    ILERT_HEARTBEAT_KEY="$(ask '  Heartbeat URL ou key' '')"
    # Colar a URL inteira no campo de key era o erro mais facil de cometer:
    # o script concatenava base + URL e recebia 404. Detecta e corrige.
    case "$ILERT_HEARTBEAT_KEY" in
      http://*|https://*)
        ILERT_HEARTBEAT_URL="$ILERT_HEARTBEAT_KEY"
        ILERT_HEARTBEAT_KEY=""
        ok "URL completa detectada - usando como ILERT_HEARTBEAT_URL"
        ;;
    esac
    [ -n "$ILERT_HEARTBEAT_KEY$ILERT_HEARTBEAT_URL" ] || WANT_HEARTBEAT=0
  fi
  ILERT_ENV="$(ask '  Ambiente (prod/staging/dev)' "$ILERT_ENV")"
  ILERT_HOST="$(ask '  Nome do host nos alertas' "${ILERT_HOST:-$(hostname)}")"
  ok "ambiente: $ILERT_ENV | heartbeat: $( [ "$WANT_HEARTBEAT" -eq 1 ] && echo sim || echo nao)"
}

#------------------------------------------------------------------------------
# scripts de integracao
#------------------------------------------------------------------------------
install_scripts() {
  head1 "3. Scripts de integracao"

  write_file "$ENV_FILE" 0600 <<EOF
# Gerado por install-monit-ilert.sh v$SCRIPT_VERSION em $(date -Iseconds)
# Segredos do ilert. NAO versionar. chmod 600.
ILERT_KEY=$ILERT_KEY
ILERT_HEARTBEAT_KEY=$ILERT_HEARTBEAT_KEY
# Base do ping de heartbeat, SEM a chave no final. Ajuste aqui se a tela do
# monitor no ilert mostrar outra URL - nao precisa mexer no script.
ILERT_BEAT_URL=$BEAT_URL
# Alternativa mais segura: cole aqui a integration URL COMPLETA que aparece na
# tela do monitor no ilert (com a chave). Se preenchida, tem prioridade.
${ILERT_HEARTBEAT_URL:+ILERT_HEARTBEAT_URL=$ILERT_HEARTBEAT_URL}
ILERT_ENV=$ILERT_ENV
# Nome do host nos alertas. Vazio = usa o hostname do sistema.
ILERT_HOST=$ILERT_HOST
# Segundos que o servico precisa ficar estavel antes do RESOLVE ser enviado.
# Protege contra crash loop virar enxurrada de alertas. 0 = envio imediato.
ILERT_RESOLVE_DELAY=$ILERT_RESOLVE_DELAY
EOF

  write_file "$BIN_DIR/ilert.sh" 0700 <<EOF
#!/bin/bash
#===============================================================================
# ilert.sh - envia eventos do Monit para o ilert Events API
# Gerado por install-monit-ilert.sh v$SCRIPT_VERSION
#
# DEPENDENCIA: apenas curl (JSON montado em bash puro de proposito, para nao
# depender de jq no caminho de alerta).
#
# USO: ilert.sh <ALERT|ACCEPT|RESOLVE> [PRIORITY] [SEVERITY] [SUFFIX]
#   PRIORITY: HIGH (escala) | LOW (registra sem escalar)
#   SEVERITY: 1..5 (1 = mais grave)
#   SUFFIX:   token SEM ESPACO; compoe o alertKey host/servico/sufixo.
#             O RESOLVE precisa repetir o MESMO sufixo do ALERT.
#
# TESTE MANUAL:
#   MONIT_HOST=\$(hostname) MONIT_SERVICE=teste MONIT_DESCRIPTION="ping manual" \\
#   MONIT_EVENT=Test MONIT_DATE="\$(date)" $BIN_DIR/ilert.sh ALERT HIGH 3 manual
#
# ILERT_SUPERSEDE=0 desliga o fechamento automatico do warning quando o
# critico do mesmo assunto abre (convencao <algo>-warn / <algo>-crit).
#
# LOGS DE FALHA: journalctl -t ilert
#===============================================================================
set -u
# O arquivo de env sobrescreveria variaveis passadas na linha de comando, o que
# quebraria o ilert-flush.sh (ele forca ILERT_RESOLVE_DELAY=0 para despachar na
# hora). Por isso: snapshot do ambiente antes, restauracao depois.
_ovr_delay="\${ILERT_RESOLVE_DELAY:-}"
_ovr_host="\${ILERT_HOST:-}"
_ovr_env="\${ILERT_ENV:-}"
[ -r $ENV_FILE ] && . $ENV_FILE
[ -n "\$_ovr_delay" ] && ILERT_RESOLVE_DELAY="\$_ovr_delay"
[ -n "\$_ovr_host" ]  && ILERT_HOST="\$_ovr_host"
[ -n "\$_ovr_env" ]   && ILERT_ENV="\$_ovr_env"
KEY="\${ILERT_KEY:?ILERT_KEY ausente em $ENV_FILE}"
API="$API_URL"
EVT="\${1:?uso: ilert.sh <ALERT|ACCEPT|RESOLVE> [PRIO] [SEV] [SUFFIX]}"
PRIO="\${2:-HIGH}"; SEV="\${3:-2}"; SUFFIX="\${4:-}"
ENVN="\${ILERT_ENV:-prod}"

: "\${MONIT_HOST:=\$(hostname)}"
# Nome exibido no ilert (alertKey e label 'host'). Default: hostname do
# sistema; sobrescreva com ILERT_HOST em $ENV_FILE quando o hostname nao for
# descritivo (ex.: ip-10-0-3-14 em nuvem).
_REAL_HOST="\$MONIT_HOST"          # nome que o Monit usa nos checks
MONIT_HOST="\${ILERT_HOST:-\$MONIT_HOST}"   # nome exibido no ilert
: "\${MONIT_SERVICE:=unknown}"
: "\${MONIT_DESCRIPTION:=sem descricao}"
: "\${MONIT_EVENT:=unknown}"
: "\${MONIT_DATE:=\$(date -Iseconds)}"

AKEY="\$MONIT_HOST/\$MONIT_SERVICE\${SUFFIX:+/\$SUFFIX}"

esc() { local s=\$1
  s=\${s//\\\\/\\\\\\\\}; s=\${s//\\"/\\\\\\"}
  s=\${s//\$'\n'/\\\\n}; s=\${s//\$'\r'/\\\\r}; s=\${s//\$'\t'/\\\\t}
  printf '%s' "\$s"; }

# Formato UNICO em toda a lista: "<host> / <servico>: <descricao>".
# O 'check system' usa o hostname como nome do check, o que produziria
# "db-01 / db-01:"; nesse caso o rotulo vira 'sistema'. Comparar com os dois
# nomes porque, com ILERT_HOST configurado, o nome exibido difere do nome do
# check e a comparacao simples deixaria passar.
if [ "\$MONIT_SERVICE" = "\$MONIT_HOST" ] || [ "\$MONIT_SERVICE" = "\$_REAL_HOST" ]; then
  SVC_LABEL="sistema"
else
  SVC_LABEL="\$MONIT_SERVICE"
fi
SUMMARY="\$MONIT_HOST / \$SVC_LABEL: \$MONIT_DESCRIPTION"

BODY="{\\"integrationKey\\":\\"\$KEY\\",
 \\"eventType\\":\\"\$EVT\\",
 \\"alertKey\\":\\"\$(esc "\$AKEY")\\",
 \\"summary\\":\\"\$(esc "\$SUMMARY")\\",
 \\"details\\":\\"\$(esc "\$MONIT_EVENT em \$MONIT_DATE")\\",
 \\"priority\\":\\"\$PRIO\\",
 \\"severity\\":\$SEV,
 \\"labels\\":{\\"env\\":\\"\$(esc "\$ENVN")\\",
              \\"host\\":\\"\$(esc "\$MONIT_HOST")\\",
              \\"service\\":\\"\$(esc "\$MONIT_SERVICE")\\",
              \\"source\\":\\"monit\\"}}"

# --- Anti-flapping -----------------------------------------------------------
# Um servico em crash loop geraria pares ALERT/RESOLVE: cada RESOLVE fecha o
# alerta, e o ALERT seguinte abre um NOVO (a dedupe por alertKey so vale
# enquanto o alerta esta aberto). Resultado: N alertas, N notificacoes.
# Solucao: o RESOLVE nao e enviado na hora. Fica pendente por
# ILERT_RESOLVE_DELAY segundos e so e despachado pelo ilert-flush.sh se o
# servico continuar de pe. Se cair de novo antes disso, o ALERT cancela o
# pendente e o alerta original segue aberto, acumulando eventos na timeline.
STATE_DIR="\${ILERT_STATE_DIR:-/var/lib/ilert/pending}"
DELAY="\${ILERT_RESOLVE_DELAY:-300}"
[[ "\$DELAY" =~ ^[0-9]+\$ ]] || DELAY=300
MARKER="\$STATE_DIR/\$(printf '%s' "\$AKEY" | tr -c 'a-zA-Z0-9_.-' '_')"
mkdir -p "\$STATE_DIR" 2>/dev/null || true

if [ "\$EVT" = RESOLVE ] && [ "\$DELAY" -gt 0 ]; then
  # Uma linha por campo; quebras de linha viram espaco para nao corromper o
  # formato. O leitor (ilert-flush.sh) faz parsing literal, sem interpretar.
  _d="\${MONIT_DESCRIPTION//\$'\n'/ }"; _d="\${_d//\$'\r'/ }"
  { printf 'PRIO=%s\n' "\$PRIO"
    printf 'SEV=%s\n' "\$SEV"
    printf 'SUFFIX=%s\n' "\$SUFFIX"
    printf 'HOST=%s\n' "\$MONIT_HOST"
    printf 'SERVICE=%s\n' "\$MONIT_SERVICE"
    printf 'DESC=%s\n' "\$_d"; } > "\$MARKER" 2>/dev/null && exit 0
  # se nao conseguiu gravar o marcador, envia agora (falhar aberto e pior)
fi
[ "\$EVT" = ALERT ] && rm -f "\$MARKER" 2>/dev/null

# --- Escalonamento: o critico absorve o warning ---------------------------
# Convencao de sufixos: <algo>-warn e <algo>-crit descrevem o MESMO assunto em
# dois niveis. Quando o critico abre, o warning virou ruido: o operador ja foi
# acordado pelo HIGH e o LOW so ocupa espaco na lista. Entao o ALERT do critico
# fecha o warning correspondente.
# O warning reaparece sozinho depois: o teste do Monit continua casando e o
# 'repeat every' reemite dentro da janela, entao nada se perde de vista.
if [ "\$EVT" = ALERT ] && [ "\${ILERT_SUPERSEDE:-1}" = 1 ]; then
  case "\$SUFFIX" in
    *-crit)
      _warn_sfx="\${SUFFIX%-crit}-warn"
      _warn_marker="\$STATE_DIR/\$(printf '%s' "\$MONIT_HOST/\$MONIT_SERVICE/\$_warn_sfx" \\
                     | tr -c 'a-zA-Z0-9_.-' '_')"
      rm -f "\$_warn_marker" 2>/dev/null
      ILERT_SUPERSEDE=0 ILERT_RESOLVE_DELAY=0 \\
      MONIT_DESCRIPTION="superado pelo alerta critico" \\
      MONIT_EVENT="Escalonado para critico" \\
        "\$0" RESOLVE "\$PRIO" "\$SEV" "\$_warn_sfx" >/dev/null 2>&1 || true
      ;;
  esac
fi

CODE=\$(curl -sS -m 10 --retry 3 --retry-delay 2 -o /dev/null -w '%{http_code}' \\
  -X POST "\$API" -H 'Content-Type: application/json' --data-binary "\$BODY" 2>/dev/null)
if [[ "\$CODE" =~ ^2 ]]; then
  exit 0
else
  logger -t ilert "falha HTTP \$CODE ao enviar \$EVT para \$AKEY"
  exit 1
fi
EOF

  local MONIT_BIN_PATH
  MONIT_BIN_PATH="$(command -v monit 2>/dev/null || echo /usr/bin/monit)"
  write_file "$BIN_DIR/ilert-giveup.sh" 0700 <<EOF
#!/bin/bash
# Chamado pelo Monit quando um servico excede o limite de restarts.
# Gerado por install-monit-ilert.sh v$SCRIPT_VERSION
#
# Reiniciar em loop e pior que nao reiniciar: mascara a causa, consome I/O e
# pode corromper estado. Aqui a politica e desistir e escalar para um humano.
#
# uso: ilert-giveup.sh <nome-do-check>
set -u
SVC="\${1:?uso: ilert-giveup.sh <servico>}"

MONIT_SERVICE="\$SVC" \\
MONIT_DESCRIPTION="reiniciado varias vezes sem estabilizar - monitoramento suspenso, precisa de intervencao manual" \\
MONIT_EVENT="Restart limit atingido" \\
ILERT_RESOLVE_DELAY=0 \\
  $BIN_DIR/ilert.sh ALERT HIGH 1 restartloop || true

# 'monit unmonitor' fala com o proprio Monit pela interface HTTP local. Roda
# destacado e com atraso para nao reentrar no ciclo que disparou este exec
# (o Monit espera o programa terminar, com programTimeout de 30s).
# Caminho absoluto: o Monit executa programas com PATH minimo.
MONIT_BIN="$MONIT_BIN_PATH"
[ -x "\$MONIT_BIN" ] || MONIT_BIN="\$(command -v monit 2>/dev/null || echo /usr/bin/monit)"
# O atraso e essencial nas duas variantes: sem ele o unmonitor reentra no
# ciclo que acabou de disparar este exec. Argumentos via "\$1"/"\$2" para nao
# depender de escaping em nome de servico.
if command -v setsid >/dev/null 2>&1; then
  setsid bash -c 'sleep 10; "\$1" unmonitor "\$2"' _ "\$MONIT_BIN" "\$SVC" \\
    >/dev/null 2>&1 < /dev/null &
else
  ( sleep 10; "\$MONIT_BIN" unmonitor "\$SVC" ) >/dev/null 2>&1 < /dev/null &
fi
disown 2>/dev/null || true
exit 0
EOF

  write_file "$BIN_DIR/ilert-dns.sh" 0700 <<EOF
#!/bin/bash
# Testa a RESOLUCAO DE NOMES pelo caminho real do sistema.
# Gerado por install-monit-ilert.sh v$SCRIPT_VERSION
#
# Por que nao "ping google.com": o ping junta resolucao e rota num teste so -
# quando falha voce nao sabe qual dos dois quebrou. E por que nao basta
# consultar 1.1.1.1 direto: isso testa o servidor remoto, nao o resolver DESTE
# host (/etc/resolv.conf, systemd-resolved, nsswitch). 'getent hosts' passa
# exatamente pelo mesmo caminho que a sua aplicacao usa.
set -u
NAME="\${1:-$RESOLVE_NAME}"
IP="\$(getent hosts "\$NAME" 2>/dev/null | awk '{print \$1; exit}')"
if [ -n "\$IP" ]; then
  echo "\$NAME -> \$IP"
  exit 0
fi
# stdout vira a descricao do alerta no ilert
echo "falha ao resolver \$NAME - verifique /etc/resolv.conf ou systemd-resolved"
exit 1
EOF

  write_file "$BIN_DIR/ilert-flush.sh" 0700 <<EOF
#!/bin/bash
# Despacha os RESOLVE pendentes cujo servico ficou estavel.
# Gerado por install-monit-ilert.sh v$SCRIPT_VERSION
#
# Chamado pelo Monit a cada ciclo. Cada marcador em ILERT_STATE_DIR foi criado
# por um RESOLVE adiado; se sobreviveu ILERT_RESOLVE_DELAY segundos sem que um
# novo ALERT o apagasse, o servico esta estavel e o RESOLVE pode ir embora.
set -u
[ -r $ENV_FILE ] && . $ENV_FILE
STATE_DIR="\${ILERT_STATE_DIR:-/var/lib/ilert/pending}"
DELAY="\${ILERT_RESOLVE_DELAY:-300}"
[ -d "\$STATE_DIR" ] || exit 0
NOW=\$(date +%s); RC=0

for f in "\$STATE_DIR"/*; do
  [ -e "\$f" ] || continue
  AGE=\$(( NOW - \$(stat -c %Y "\$f" 2>/dev/null || echo "\$NOW") ))
  [ "\$AGE" -ge "\$DELAY" ] || continue
  PRIO=HIGH; SEV=2; SUFFIX=""; HOST=""; SERVICE=""; DESC=""
  # NUNCA use '. \$f' aqui: o marcador contem MONIT_DESCRIPTION, texto vindo do
  # servico monitorado. Uma descricao como 'space usage > 85%' viraria redirect,
  # e '\$(cmd)' viraria execucao de comando como root. Parsing puro, sem eval.
  while IFS='=' read -r _k _v; do
    case "\$_k" in
      PRIO)    PRIO="\$_v" ;;
      SEV)     SEV="\$_v" ;;
      SUFFIX)  SUFFIX="\$_v" ;;
      HOST)    HOST="\$_v" ;;
      SERVICE) SERVICE="\$_v" ;;
      DESC)    DESC="\$_v" ;;
    esac
  done < "\$f"
  [ -n "\$HOST" ] && [ -n "\$SERVICE" ] || { rm -f "\$f"; continue; }
  [[ "\$SEV" =~ ^[1-5]$ ]] || SEV=2
  case "\$PRIO" in HIGH|LOW) ;; *) PRIO=HIGH ;; esac
  if ILERT_RESOLVE_DELAY=0 MONIT_HOST="\$HOST" MONIT_SERVICE="\$SERVICE" \\
     MONIT_DESCRIPTION="\$DESC" MONIT_EVENT="Recovery confirmada apos \${DELAY}s" \\
     MONIT_DATE="\$(date -Iseconds)" \\
     $BIN_DIR/ilert.sh RESOLVE "\$PRIO" "\$SEV" "\$SUFFIX"; then
    rm -f "\$f"
  else
    RC=1   # mantem o marcador para tentar no proximo ciclo
  fi
done
exit \$RC
EOF

  if [ "$WANT_HEARTBEAT" -eq 1 ]; then
    write_file "$BIN_DIR/ilert-beat.sh" 0700 <<EOF
#!/bin/bash
# Ping de liveness do Monit -> ilert Heartbeat.
# Gerado por install-monit-ilert.sh v$SCRIPT_VERSION
# Chamado pelo 'check program ilert-heartbeat'. Exit != 0 gera alerta local.
#
# IMPORTANTE: o endpoint aceita GET e POST, NAO HEAD. Um 'curl -I' aqui
# devolve erro mesmo com a chave correta.
#
# A chave de heartbeat (il1hbt...) e diferente da integration key do alert
# source (il1api.../il1ins...) e e UMA POR SERVIDOR.
#
# TESTE MANUAL:  $BIN_DIR/ilert-beat.sh && echo ok
set -u
[ -r $ENV_FILE ] && . $ENV_FILE
KEY="\${ILERT_HEARTBEAT_KEY:-}"
[ -n "\$KEY\${ILERT_HEARTBEAT_URL:-}" ] || \
  { echo "defina ILERT_HEARTBEAT_KEY ou ILERT_HEARTBEAT_URL em $ENV_FILE"; exit 1; }
# Prioridade: URL completa (copiada da tela do monitor) > base + chave.
# Existem varios tipos de heartbeat no ilert, cada um com endpoint proprio:
#   heartbeat monitor      -> https://beat.ilert.com/api/pings/<key>
#   heartbeat alert source -> https://api.ilert.com/api/v1/heartbeats/<il1hbt...>
# NAO use a integration key do alert source (il1hb2...) - ela nao e pingavel.
URL="\${ILERT_HEARTBEAT_URL:-\${ILERT_BEAT_URL:-$BEAT_URL}/\$KEY}"
OUT=\$(curl -sS -m 10 --retry 2 --retry-delay 2 -w '\nHTTP:%{http_code}' "\$URL" 2>&1)
CODE="\${OUT##*HTTP:}"
if [[ "\$CODE" =~ ^2 ]]; then
  exit 0
fi
# stdout e capturado pelo Monit e vira a descricao do alerta no ilert:
# sem isso o alerta chega como "status failed (1) -- no output".
echo "ping falhou HTTP=\$CODE key=\${KEY:0:9}... resp=\${OUT%%\$'\n'HTTP:*}"
logger -t ilert "heartbeat HTTP \$CODE em \$URL"
exit 1
EOF
  fi
}

#------------------------------------------------------------------------------
# calculo de limiares a partir do hardware
#------------------------------------------------------------------------------
compute_thresholds() {
  head1 "4. Limiares calculados para este host"
  CORES="$(nproc 2>/dev/null || echo 1)"
  LOAD_WARN="$CORES"
  LOAD_CRIT="$((CORES * 2))"

  RAM_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
  # RAM pequena => folga menor em percentual absoluto
  if [ "$RAM_MB" -lt 2048 ]; then MEM_WARN=80; MEM_CRIT=92
  elif [ "$RAM_MB" -lt 8192 ]; then MEM_WARN=85; MEM_CRIT=94
  else MEM_WARN=88; MEM_CRIT=95; fi

  # Swap e sinal, nao recurso: o que importa e swap que NAO volta, por isso o
  # debounce longo no warning. Ajustavel para frotas com perfil diferente.
  SWAP_WARN="${ILERT_SWAP_WARN:-10}"
  SWAP_CRIT="${ILERT_SWAP_CRIT:-30}"
  # Valores vindos de flag/env chegam sem garantia nenhuma. Um valor nao
  # numerico produziria 'if swap usage > abc%', que so falharia la na frente no
  # 'monit -t'; e warn >= crit geraria dois alertas simultaneos sempre.
  [[ "$SWAP_WARN" =~ ^[0-9]+$ ]] && [ "$SWAP_WARN" -ge 1 ] && [ "$SWAP_WARN" -le 99 ] \
    || { warn "swap warn invalido ($SWAP_WARN) - usando 10"; SWAP_WARN=10; }
  [[ "$SWAP_CRIT" =~ ^[0-9]+$ ]] && [ "$SWAP_CRIT" -ge 1 ] && [ "$SWAP_CRIT" -le 100 ] \
    || { warn "swap crit invalido ($SWAP_CRIT) - usando 30"; SWAP_CRIT=30; }
  if [ "$SWAP_WARN" -ge "$SWAP_CRIT" ]; then
    warn "swap warn ($SWAP_WARN%) >= crit ($SWAP_CRIT%) - ajustando para 10/30"
    SWAP_WARN=10; SWAP_CRIT=30
  fi
  HAS_SWAP=0
  if [ -n "$(swapon --show --noheadings 2>/dev/null || true)" ]; then HAS_SWAP=1; fi

  printf '  cores=%s -> loadavg(5min) warn>%s crit>%s\n' "$CORES" "$LOAD_WARN" "$LOAD_CRIT"
  printf '  RAM=%s MB -> memoria warn>%s%% crit>%s%%\n' "$RAM_MB" "$MEM_WARN" "$MEM_CRIT"
  if [ "$HAS_SWAP" -eq 1 ]; then
    printf '  swap ativo -> warn>%s%% crit>%s%%\n' "$SWAP_WARN" "$SWAP_CRIT"
  else
    printf '  swap ativo: nao\n'
  fi
}

# limiares de disco derivados do tamanho: percentual + valor absoluto
# regra: warn livre = 10%% do disco (min 2G, max 20G); crit = 3%% (min 1G, max 8G)
# $1 = tamanho em GB -> "pct_warn pct_crit mb_warn mb_crit"
#
# Em MB, nao GB: um piso fixo de 2 GB fazia /boot (tipicamente 1-2 GB) alertar
# desde o primeiro dia, sem nunca representar um problema real. Os limiares
# absolutos agora escalam com o volume, com pisos pensados no uso pratico:
# 512 MB no warning cobre a instalacao de um kernel novo; 256 MB no critico
# e o ponto em que a proxima atualizacao falha.
disk_thresholds() {
  local size="$1" size_mb mw mc
  size_mb=$(( size * 1024 ))
  mw=$(( size_mb / 5 ))    # 20%
  mc=$(( size_mb / 10 ))   # 10%
  if [ "$size" -le 10 ]; then
    # volumes pequenos (/boot, /boot/efi): piso pequeno mas util
    [ "$mw" -lt 512 ] && mw=512
    [ "$mc" -lt 256 ] && mc=256
    echo "80 90 $mw $mc"
  else
    # volumes grandes: teto para nao exigir centenas de GB livres
    mw=$(( size_mb / 10 )); [ "$mw" -gt 20480 ] && mw=20480
    mc=$(( size_mb / 33 )); [ "$mc" -gt 8192 ]  && mc=8192
    [ "$mw" -lt 2048 ] && mw=2048
    [ "$mc" -lt 1024 ] && mc=1024
    if [ "$size" -le 200 ]; then echo "85 93 $mw $mc"
    else echo "88 95 $mw $mc"; fi
  fi
}

#------------------------------------------------------------------------------
# monitrc base
#------------------------------------------------------------------------------
write_monitrc() {
  head1 "5. monitrc base"
  run mkdir -p "$CONF_D"

  # Debian mantem um segundo diretorio (conf-enabled). Sobrescrever o monitrc
  # sem reincluir desativaria em silencio todos os checks que o usuario ja tinha.
  EXTRA_INCLUDE=""
  if [ -d "$MONIT_DIR/conf-enabled" ]; then
    EXTRA_INCLUDE="include $MONIT_DIR/conf-enabled/*"
    warn "preservando include de $MONIT_DIR/conf-enabled"
  fi
  if [ -f "$MONITRC" ] && grep -qE '^\s*(check|include)' "$MONITRC" 2>/dev/null; then
    warn "monitrc atual tem conteudo proprio - backup em $(backup_path "$MONITRC")"
    if ! confirm "  Sobrescrever o monitrc?" y; then
      warn "monitrc mantido; apenas os arquivos de $CONF_D serao gerados"
      return
    fi
  fi

  write_file "$MONITRC" 0700 <<EOF
###############################################################################
# monitrc - gerado por install-monit-ilert.sh v$SCRIPT_VERSION em $(date -Iseconds)
# Backup do original (se havia) em $BACKUP_DIR
###############################################################################

# Ciclo de 60s: em todo conf.d, "N cycles" == N minutos.
set daemon 60 with start delay 30

set log /var/log/monit.log
set idfile /var/lib/monit/id
set statefile /var/lib/monit/state

# Necessario para 'monit status', 'monit reload' e 'monit summary'.
# Somente localhost - nao exponha esta porta.
set httpd port 2812 and
  use address localhost
  allow localhost

# Nenhum 'set alert' aqui de proposito: sem 'set mailserver' configurado o
# Monit registra erro de envio a cada ciclo. Se quiser fallback por e-mail,
# descomente as duas linhas abaixo e ajuste o relay.
#   set mailserver localhost
#   set alert root@localhost not on { instance, action }

# Limites do proprio Monit
set limits {
  programOutput:     512 B
  sendExpectBuffer:  256 B
  fileContentBuffer: 512 B
  networkTimeout:    5 seconds
  programTimeout:    30 seconds
}

include $CONF_D/*.conf
$EXTRA_INCLUDE
EOF
  run mkdir -p /var/lib/monit
}

#------------------------------------------------------------------------------
# helpers de geracao de checks
#------------------------------------------------------------------------------
# Politica de auto-restart. Monit tenta reiniciar sozinho e DESISTE se o
# servico nao estabilizar - loop de restart mascara a causa e queima I/O.
# A desistencia chama ilert-giveup.sh, que escala SEV1 e suspende o check.
emit_restart_policy() { # emit_restart_policy <nome-do-check>
  local svc="$1"
  echo "  # auto-restart: tenta reerguer, mas desiste se virar loop"
  echo "  if does not exist for 3 cycles then restart"
  echo "  if $RESTART_LIMIT restarts within $RESTART_WINDOW cycles"
  echo "    then exec \"$BIN_DIR/ilert-giveup.sh $svc\""
}

# Nomes de check ja usados na configuracao que preservamos (conf-enabled e
# arquivos de terceiros em conf.d). O Monit exige nomes unicos em TODA a
# configuracao; colidir aborta o 'monit -t' com "Service name conflict".
EXISTING_NAMES=""
SANDBOX_DROPIN=0
collect_existing_names() {
  local managed='00-system|01-filesystem|02-network|03-heartbeat|04-flush|10-services|15-ports'
  # 'find -L': o Debian popula conf-enabled com SYMLINKS para conf-available
  # (mesmo esquema do Apache). Sem o -L, '-type f' encontra zero arquivos e a
  # deteccao de conflito falha justamente onde ela e mais necessaria.
  # O monitrc tambem entra: se o operador recusou sobrescreve-lo, os checks
  # dele continuam valendo.
  EXISTING_NAMES=" $(
    { find -L "$CONF_D" -maxdepth 1 -name '*.conf' -type f 2>/dev/null \
        | grep -vE "/($managed)\.conf$"
      find -L "$MONIT_DIR/conf-enabled" -maxdepth 1 -type f 2>/dev/null
      [ -f "$MONITRC" ] && printf '%s\n' "$MONITRC"
    } | xargs -r grep -hoE '^[[:space:]]*check[[:space:]]+(process|system|filesystem|host|program|file|directory|fifo|network)[[:space:]]+[^[:space:]]+' 2>/dev/null \
      | awk '{print $3}' | sort -u | tr '\n' ' ' || true
  ) "
  [ "$EXISTING_NAMES" = "  " ] && EXISTING_NAMES=""
  [ -n "$EXISTING_NAMES" ] && warn "checks ja definidos fora do instalador:${EXISTING_NAMES}"
  return 0
}

# Devolve um nome livre. Se ja existir, sufixa com -ilert em vez de falhar la
# na validacao - o operador fica com os dois checks e decide o que remover.
# NOTA: roda em subshell ($(uniq_name ...)), entao nao da para acumular estado
# aqui. O registro do nome escolhido fica por conta de register_name, chamado
# pelo gerador - assim dois arquivos nossos tambem nao colidem entre si
# (um filesystem 'cache' e uma porta 'cache', por exemplo).
uniq_name() {
  local n="$1"
  case "$EXISTING_NAMES" in
    *" $n "*) warn "nome '$n' ja existe - usando '${n}-ilert'"; printf '%s-ilert' "$n" ;;
    *) printf '%s' "$n" ;;
  esac
}

register_name() { EXISTING_NAMES="${EXISTING_NAMES:- }$1 "; }

# emite par ALERT/RESOLVE
emit_pair() { # emit_pair <condicao> <prio> <sev> <sufixo> [repeat_cycles]
  local cond="$1" prio="$2" sev="$3" sfx="$4" rep="${5:-}"
  printf '  %s\n' "$cond"
  if [ -n "$rep" ]; then
    printf '    then exec "%s/ilert.sh ALERT %s %s %s" repeat every %s cycles\n' \
      "$BIN_DIR" "$prio" "$sev" "$sfx" "$rep"
  else
    printf '    then exec "%s/ilert.sh ALERT %s %s %s"\n' "$BIN_DIR" "$prio" "$sev" "$sfx"
  fi
  printf '    else if succeeded then exec "%s/ilert.sh RESOLVE %s %s %s"\n' \
    "$BIN_DIR" "$prio" "$sev" "$sfx"
}

# descobre o pidfile de um servico via systemd ou lista de candidatos
find_pidfile() { # find_pidfile <unit> <candidato>...
  local unit="$1"; shift
  local p
  p="$(systemctl show -p PIDFile --value "$unit" 2>/dev/null || true)"
  if [ -n "$p" ] && [ "$p" != "" ]; then echo "$p"; return 0; fi
  for p in "$@"; do
    # aceita glob
    for g in $p; do [ -e "$g" ] && { echo "$g"; return 0; }; done
  done
  return 1
}

unit_exists() { systemctl list-unit-files "$1" >/dev/null 2>&1 && \
                systemctl list-unit-files --no-legend "$1" | grep -q .; }

# Resolve aliases: no Debian, mysql.service e mysqld.service sao apelidos de
# mariadb.service. Sem isso o instalador gera 3 checks para o MESMO processo
# e uma queda unica abre 3 alertas.
canonical_unit() {
  local id
  id="$(systemctl show -p Id --value "$1" 2>/dev/null || true)"
  [ -n "$id" ] && printf '%s' "${id%.service}" || printf '%s' "${1%.service}"
}

#------------------------------------------------------------------------------
# checks de sistema (load, cpu, memoria, swap, disco, rede, heartbeat)
#------------------------------------------------------------------------------
gen_system_checks() {
  head1 "6. Checks de sistema"
  # O Monit aceita um unico 'check system'. Se ja existe um nos arquivos que
  # preservamos (conf-enabled, 20-custom.conf), usar '$HOST' de novo aborta o
  # 'monit -t' com "Service name conflict".
  local sysname='$HOST' existing=""
  existing="$(grep -rlE '^[[:space:]]*check[[:space:]]+system' \
              "$CONF_D" "$MONIT_DIR/conf-enabled" 2>/dev/null \
              | grep -v '00-system.conf' | head -1 || true)"
  if [ -n "$existing" ]; then
    sysname="\$HOST-recursos"
    warn "ja existe 'check system' em $existing"
    warn "usando o nome '$sysname' para evitar conflito"
  fi
  {
    echo "# 00-system.conf - gerado em $(date -Iseconds)"
    echo "# cores=$CORES RAM=${RAM_MB}MB"
    echo
    echo "check system $sysname"
    echo
    echo "  # ---- LOAD (5min; a de 1min dispara em qualquer apt upgrade) ----"
    emit_pair "if loadavg (5min) > $LOAD_CRIT for 3 cycles" HIGH 1 load-crit 30
    emit_pair "if loadavg (5min) > $LOAD_WARN for 5 cycles" "$WARN_PRIO" 3 load-warn 60
    echo
    echo "  # ---- CPU (system e iowait dizem mais que 'user') ----"
    emit_pair "if cpu usage (system) > 40% for 5 cycles" "$WARN_PRIO" 3 cpu-sys 60
    emit_pair "if cpu usage (wait) > 30% for 5 cycles" "$WARN_PRIO" 3 cpu-wait 60
    echo
    echo "  # ---- MEMORIA (o Monit ja desconta buffers/cache) ----"
    emit_pair "if memory usage > ${MEM_CRIT}% for 3 cycles" HIGH 1 mem-crit 30
    emit_pair "if memory usage > ${MEM_WARN}% for 5 cycles" "$WARN_PRIO" 3 mem-warn 60
    if [ "$HAS_SWAP" -eq 1 ]; then
      echo
      echo "  # ---- SWAP (sinal, nao recurso: debounce longo de proposito) ----"
      emit_pair "if swap usage > ${SWAP_CRIT}% for 3 cycles" HIGH 1 swap-crit 30
      emit_pair "if swap usage > ${SWAP_WARN}% for 10 cycles" "$WARN_PRIO" 3 swap-warn 60
    fi
  } > /tmp/00-system.conf
  write_file "$CONF_D/00-system.conf" 0600 < /tmp/00-system.conf
  rm -f /tmp/00-system.conf
}

gen_filesystem_checks() {
  head1 "7. Filesystems"
  local out=/tmp/01-filesystem.conf
  : > "$out"
  echo "# 01-filesystem.conf - gerado em $(date -Iseconds)" >> "$out"
  echo "# limiares derivados do tamanho de cada volume" >> "$out"
  echo >> "$out"

  local dev mnt size_gb name th pw pc gw gc
  while read -r dev size_gb mnt; do
    case "$mnt" in
      /snap/*|/var/lib/docker/*|/proc*|/sys*|/run*|/dev*) continue ;;
    esac
    [ "$size_gb" -ge 1 ] 2>/dev/null || continue
    name="$(uniq_name "$(echo "$mnt" | sed 's|^/$|root|; s|^/||; s|/|_|g')")"
    register_name "$name"
    th="$(disk_thresholds "$size_gb")"
    read -r pw pc gw gc <<< "$th"
    printf '  %s (%sG) -> warn >%s%% ou <%sMB | crit >%s%% ou <%sMB\n' \
      "$mnt" "$size_gb" "$pw" "$gw" "$pc" "$gc"
    {
      echo "check filesystem $name with path $mnt"
      emit_pair "if space free < ${gc} MB for 2 cycles" HIGH 1 "disk-abs-crit" 30
      emit_pair "if space usage > ${pc}% for 2 cycles"  HIGH 1 "disk-pct-crit" 30
      emit_pair "if space free < ${gw} MB for 5 cycles" "$WARN_PRIO" 3 "disk-abs-warn" 120
      emit_pair "if space usage > ${pw}% for 5 cycles"  "$WARN_PRIO" 3 "disk-pct-warn" 120
      echo "  # inodes enchem sozinhos, com o disco 'vazio'"
      emit_pair "if inode usage > 90% for 3 cycles" HIGH 1 "inode" 60
      echo
    } >> "$out"
  done < <(df --output=source,fstype,size,target 2>/dev/null | tail -n +2 | \
           awk '$2 ~ /^(ext[234]|xfs|btrfs|zfs|jfs|ufs|reiserfs)$/ \
                {printf "%s %d %s\n", $1, $3/1048576, $4}')

  write_file "$CONF_D/01-filesystem.conf" 0600 < "$out"
  rm -f "$out"
}

# ICMP nao e o teste que importa: a aplicacao fala TCP, nao ping. Em nuvem
# (EC2, GCP) e em rede corporativa o ICMP costuma ser bloqueado enquanto o
# HTTPS passa - gerando alerta permanente de "sem internet" num host saudavel.
# Por isso o instalador TESTA antes de decidir qual check gerar.
probe_icmp() { ping -c 2 -W 2 "$1" >/dev/null 2>&1; }
probe_tcp()  { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

gen_network_checks() {
  head1 "8. Conectividade"
  local ext_mode=""

  if [ "$CONNECTIVITY" = icmp ] || [ "$CONNECTIVITY" = auto ]; then
    if probe_icmp "$PING_TARGET"; then
      ext_mode=icmp; ok "ICMP para $PING_TARGET responde"
    elif [ "$CONNECTIVITY" = icmp ]; then
      ext_mode=icmp; warn "ICMP nao responde, mas foi pedido explicitamente"
    fi
  fi
  if [ -z "$ext_mode" ] && [ "$CONNECTIVITY" != none ]; then
    if probe_tcp "$PING_TARGET" 443; then
      ext_mode=tcp
      [ "$CONNECTIVITY" = auto ] && warn "ICMP bloqueado - usando TCP 443, que e o caminho real da aplicacao"
    else
      warn "nem ICMP nem TCP 443 alcancam $PING_TARGET - sem check externo"
    fi
  fi

  # gateway: so vale onde ha rede propria E ele responde. Em nuvem, o roteador
  # virtual normalmente ignora ICMP e o alerta seria permanente e inutil.
  if [ -z "$GATEWAY" ] && [ "$CONNECTIVITY" != none ]; then
    if command -v ip >/dev/null 2>&1; then
      GATEWAY="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}' || true)"
    elif command -v route >/dev/null 2>&1; then
      GATEWAY="$(route -n 2>/dev/null | awk '/^0\.0\.0\.0/{print $2; exit}' || true)"
    fi
    if [ -n "$GATEWAY" ] && ! probe_icmp "$GATEWAY"; then
      warn "gateway $GATEWAY nao responde a ICMP (normal em nuvem) - pulando"
      GATEWAY=""
    elif [ -n "$GATEWAY" ] && [ "$ASSUME_YES" -eq 0 ]; then
      GATEWAY="$(ask '  Gateway para check ICMP (vazio = pular)' "$GATEWAY")"
    fi
  fi

  if [ -z "$ext_mode" ] && [ -z "$GATEWAY" ]; then
    warn "nenhum check de rede gerado"; return
  fi

  {
    echo "# 02-network.conf - gerado em $(date -Iseconds)"
    echo "# Só entra o que respondeu durante a instalacao."
    echo
    if [ -n "$GATEWAY" ]; then
      echo "check host gateway with address $GATEWAY"
      emit_pair "if failed ping count 3 with timeout 5 seconds for 3 cycles" HIGH 1 icmp 30
      echo
    fi
    if [ "$ext_mode" = icmp ]; then
      echo "# Alvo por IP: nome misturaria falha de DNS com falha de rede."
      echo "check host internet with address $PING_TARGET"
      emit_pair "if failed ping count 3 with timeout 5 seconds for 5 cycles" HIGH 2 icmp 60
      echo
    elif [ "$ext_mode" = tcp ]; then
      echo "# TCP 443 em vez de ICMP: independe de ICMP liberado no firewall."
      echo "check host internet with address $PING_TARGET"
      emit_pair "if failed port 443 type tcp with timeout 5 seconds for 5 cycles" HIGH 2 tcp443 60
      echo
    fi
    if [ -n "$ext_mode" ]; then
      echo "# Servidor DNS remoto responde? (nao testa o resolver local)"
      echo "check host dns with address $PING_TARGET"
      emit_pair "if failed port 53 type udp protocol dns for 5 cycles" HIGH 2 dns 60
      echo
    fi
    # Resolucao de nomes: por ICMP quando disponivel (mais direto e o que o
    # operador espera ver), com o teste via getent como complemento. Onde o
    # ICMP e bloqueado, o getent e a UNICA forma de validar o resolver.
    if [ "$ext_mode" = icmp ]; then
      echo "# Resolve E alcanca o nome? Com o check 'internet' acima por IP,"
      echo "# uma falha SO aqui aponta para resolucao de nomes."
      echo "# Verificado no Monit 5.33: nome nao resolvivel NAO impede o"
      echo "# carregamento da configuracao - a resolucao ocorre em runtime."
      echo "check host resolucao with address $RESOLVE_NAME"
      emit_pair "if failed ping count 3 with timeout 5 seconds for 5 cycles" HIGH 2 pingname 60
      echo
    fi
    echo "# O RESOLVER DESTE HOST funciona? Testa /etc/resolv.conf,"
    echo "# systemd-resolved e nsswitch - o caminho que a aplicacao usa."
    echo "# Resolve em tempo de execucao, entao nao impede o monit de carregar"
    echo "# a configuracao se o DNS estiver fora no momento do reload."
    echo "check program dns-resolver with path \"$BIN_DIR/ilert-dns.sh\""
    echo "  every 5 cycles"
    emit_pair "if status != 0 for 3 cycles" HIGH 2 resolver 60
  } > /tmp/02-network.conf
  write_file "$CONF_D/02-network.conf" 0600 < /tmp/02-network.conf
  rm -f /tmp/02-network.conf
  ok "externo: ${ext_mode:-nenhum} | gateway: ${GATEWAY:-nenhum}"
}


# systemd com ProtectSystem=strict/full monta /run e /var somente-leitura para
# o servico. Duas consequencias silenciosas:
#   1. connect() em socket unix falha (exige escrita no arquivo do socket),
#      gerando "Connection failed" com o servico saudavel;
#   2. o ilert.sh nao consegue gravar os marcadores de resolve adiado, e o
#      anti-flapping para de funcionar sem avisar.
ensure_monit_sandbox() {
  local prot
  prot="$(systemctl show monit -p ProtectSystem --value 2>/dev/null || true)"
  case "$prot" in
    strict|full|yes) ;;
    *) return 0 ;;
  esac
  head1 "9c. Sandbox do systemd"
  warn "monit roda com ProtectSystem=$prot (/run e /var somente-leitura)"

  # Os diretorios sao extraidos dos checks JA GERADOS, nao de uma lista fixa:
  # um pool php-fpm ou um Redis com 'listen' fora do padrao ficaria de fora.
  # O prefixo '-' torna cada caminho OPCIONAL: sem ele, um diretorio que nao
  # exista no momento do start impede o monit de iniciar
  # ("Failed to set up mount namespacing"). Sockets em /run somem no boot.
  local -a rw=("-/var/lib/ilert")
  local d
  while read -r d; do
    [ -n "$d" ] && rw+=("-$d")
  done < <(grep -horE 'unixsocket[[:space:]]+[^[:space:]]+' "$CONF_D"/*.conf 2>/dev/null \
           | awk '{print $2}' | xargs -r -n1 dirname 2>/dev/null | sort -u || true)
  # sockets que o Monit acessa sem a palavra 'unixsocket' (docker, protocolos)
  for d in /run/php /run/mysqld /run/postgresql /run/redis /var/run/docker.sock; do
    [ -e "$d" ] && rw+=("-$(dirname "$d/x")")
  done
  mapfile -t rw < <(printf '%s\n' "${rw[@]}" | sort -u)

  run mkdir -p /var/lib/ilert/pending /etc/systemd/system/monit.service.d
  write_file /etc/systemd/system/monit.service.d/ilert.conf 0644 <<EOF
# Gerado por install-monit-ilert.sh v$SCRIPT_VERSION
# Sem isto, com ProtectSystem=$prot, o Monit nao conecta em sockets unix e o
# anti-flapping do ilert nao consegue gravar seus marcadores.
[Service]
ReadWritePaths=${rw[*]}
EOF
  run systemctl daemon-reload
  SANDBOX_DROPIN=1
  ok "ReadWritePaths: ${rw[*]}"
  # O restart NAO acontece aqui: a configuracao ainda nao passou pelo
  # 'monit -t'. Se ela estiver quebrada, o monit nao subiria e a culpa cairia
  # no drop-in, que seria removido sem motivo. Quem reinicia e valida o
  # resultado e o validate_and_start, depois da configuracao aprovada.
}

gen_flush_check() {
  head1 "9b. Flush de resolves pendentes"
  {
    echo "# 04-flush.conf - gerado em $(date -Iseconds)"
    echo "# Roda todo ciclo: despacha RESOLVE adiado quando o servico se manteve"
    echo "# estavel. E o que impede crash loop de virar enxurrada de alertas."
    echo
    echo "check program ilert-flush with path \"$BIN_DIR/ilert-flush.sh\""
    echo "  every 1 cycles"
    emit_pair "if status != 0 for 5 cycles" HIGH 2 flush 60
  } > /tmp/04-flush.conf
  write_file "$CONF_D/04-flush.conf" 0600 < /tmp/04-flush.conf
  rm -f /tmp/04-flush.conf
  run mkdir -p /var/lib/ilert/pending
  run chmod 700 /var/lib/ilert /var/lib/ilert/pending
}

gen_heartbeat_check() {
  [ "$WANT_HEARTBEAT" -eq 1 ] || return 0
  head1 "9. Heartbeat"
  {
    echo "# 03-heartbeat.conf - gerado em $(date -Iseconds)"
    echo "# Ping a cada 5 ciclos (5 min). Configure o monitor no ilert com 15 min:"
    echo "# margem de 3x absorve um ciclo perdido sem alarme falso."
    echo "# O timer do ilert so comeca a contar apos o PRIMEIRO ping."
    echo
    echo "check program ilert-heartbeat with path \"$BIN_DIR/ilert-beat.sh\""
    echo "  every 5 cycles"
    emit_pair "if status != 0 for 3 cycles" HIGH 2 beat 60
  } > /tmp/03-heartbeat.conf
  write_file "$CONF_D/03-heartbeat.conf" 0600 < /tmp/03-heartbeat.conf
  rm -f /tmp/03-heartbeat.conf
}

#------------------------------------------------------------------------------
# deteccao e geracao dos checks de servico
#------------------------------------------------------------------------------
declare -a DETECTED=()
declare -a CHOSEN=()

detect_services() {
  head1 "10. Servicos"
  local u
  for u in nginx apache2 httpd mariadb mysql mysqld postgresql postgresql@* \
           docker redis redis-server valkey valkey-server; do
    unit_exists "${u}.service" && DETECTED+=("$(canonical_unit "${u}.service")")
  done
  # php-fpm em qualquer versao
  while read -r u; do
    [ -n "$u" ] && DETECTED+=("${u%.service}")
  done < <(systemctl list-unit-files --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}')

  # --services tem precedencia: funciona mesmo onde a deteccao falha
  # (container sem systemd, unit com nome fora do padrao).
  if [ -n "$SERVICES_ARG" ]; then
    IFS=',' read -r -a CHOSEN <<< "$SERVICES_ARG"
    ok "servicos por flag: ${CHOSEN[*]}"
    return
  fi

  if [ ${#DETECTED[@]} -eq 0 ]; then
    warn "nenhum servico conhecido detectado"
    return
  fi
  # dedupe (guarda contra array vazio sob set -u em bash < 4.4)
  mapfile -t DETECTED < <(printf '%s\n' ${DETECTED[@]+"${DETECTED[@]}"} | awk 'NF' | sort -u)
  # No Debian, postgresql.service e um wrapper que apenas aciona a instancia
  # postgresql@NN-main.service. Monitorar os dois gera dois checks para o mesmo
  # processo - e o Monit recusa por conflito de nome. A instancia vence.
  if printf '%s\n' "${DETECTED[@]}" | grep -q '@'; then
    mapfile -t DETECTED < <(printf '%s\n' "${DETECTED[@]}" | grep -v '^postgresql$' || true)
  fi

  echo "  Detectados: ${DETECTED[*]}"
  echo
  local s
  for s in "${DETECTED[@]}"; do
    if confirm "  Monitorar $s?" y; then CHOSEN+=("$s"); fi
  done
  [ ${#CHOSEN[@]} -gt 0 ] && ok "selecionados: ${CHOSEN[*]}" || warn "nenhum servico selecionado"
}

# Arquivos escritos nesta execucao, para rollback em caso de erro.
declare -a WRITTEN=()

rollback() {
  local f reload=0
  for f in ${WRITTEN[@]+"${WRITTEN[@]}"}; do
    case "$f" in */systemd/*) reload=1 ;; esac
    if [ -f "$(backup_path "$f")" ]; then
      mv -f "$(backup_path "$f")" "$f"
      warn "restaurado $f"
    else
      rm -f "$f"
      warn "removido $f (nao existia antes)"
    fi
  done
  # Apagar o drop-in nao basta: o systemd mantem a unit em memoria ate o
  # daemon-reload. Sem isto, um 'systemctl restart monit' feito depois ainda
  # aplicaria o ReadWritePaths que acabamos de remover.
  if [ "$reload" -eq 1 ]; then
    systemctl daemon-reload 2>/dev/null || true
    warn "systemd recarregado apos remover o drop-in"
  fi
}

# Espera o servico ficar ativo E respondendo. 'is-active' sozinho mente: o
# systemd marca ativo antes de o Monit abrir a interface HTTP local, e um
# 'monit status' logo em seguida devolveria "Connection refused".
wait_monit_ready() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active --quiet monit && monit summary >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  systemctl is-active --quiet monit
}

gen_service_checks() {
  [ ${#CHOSEN[@]} -gt 0 ] || return 0
  local out=/tmp/10-services.conf
  {
    echo "# 10-services.conf - gerado em $(date -Iseconds)"
    echo "# Cada servico com sufixos distintos no alertKey (pid/port/socket),"
    echo "# senao o recovery de um teste fecharia o alerta de outro."
    echo
  } > "$out"

  # quais servicos podem se reerguer sozinhos
  restart_ok() {
    case "$RESTART_MODE" in
      none) return 1 ;;
      all)  return 0 ;;
      *)    case "$1" in
              nginx|apache2|httpd|php*-fpm|redis|redis-server|valkey|valkey-server)
                return 0 ;;
              *) return 1 ;;
            esac ;;
    esac
  }

  local s pid cn
  for s in "${CHOSEN[@]}"; do
    cn="$(uniq_name "$s")"; register_name "$cn"
    case "$s" in
      nginx)
        pid="$(find_pidfile nginx.service /run/nginx.pid /var/run/nginx.pid)" || pid=""
        {
          if [ -n "$pid" ]; then echo "check process nginx with pidfile $pid"
          else echo "check process nginx matching \"nginx: master\""; fi
          echo "  start program = \"/bin/systemctl start nginx\" with timeout 60 seconds"
          echo "  stop  program = \"/bin/systemctl stop nginx\" with timeout 30 seconds"
          emit_pair "if does not exist for 2 cycles" HIGH 1 pid
          restart_ok "$s" && emit_restart_policy "$cn"
          emit_pair "if failed port 80 protocol http request \"/\" for 3 cycles" HIGH 2 http 30
          emit_pair "if cpu > 80% for 10 cycles" "$WARN_PRIO" 3 cpu 120
          echo
        } >> "$out"
        ;;
      apache2|httpd)
        pid="$(find_pidfile "${s}.service" /run/apache2/apache2.pid /run/httpd/httpd.pid \
               /var/run/apache2/apache2.pid)" || pid=""
        {
          if [ -n "$pid" ]; then echo "check process $cn with pidfile $pid"
          else echo "check process $cn matching \"$s\""; fi
          echo "  start program = \"/bin/systemctl start $s\" with timeout 60 seconds"
          echo "  stop  program = \"/bin/systemctl stop $s\" with timeout 30 seconds"
          emit_pair "if does not exist for 2 cycles" HIGH 1 pid
          restart_ok "$s" && emit_restart_policy "$cn"
          emit_pair "if failed port 80 protocol http request \"/\" for 3 cycles" HIGH 2 http 30
          emit_pair "if children > 250 for 5 cycles" "$WARN_PRIO" 3 children 120
          echo
        } >> "$out"
        ;;
      mariadb|mysql|mysqld)
        pid="$(find_pidfile "${s}.service" /run/mysqld/mysqld.pid /var/run/mysqld/mysqld.pid \
               /var/lib/mysql/*.pid)" || pid=""
        {
          if [ -n "$pid" ]; then echo "check process $cn with pidfile $pid"
          else echo "check process $cn matching \"mysqld\""; fi
          echo "  start program = \"/bin/systemctl start $s\" with timeout 90 seconds"
          echo "  stop  program = \"/bin/systemctl stop $s\" with timeout 90 seconds"
          echo "  # banco: nunca reinicie sozinho. Alerta e humano decide."
          emit_pair "if does not exist for 2 cycles" HIGH 1 pid
          restart_ok "$s" && emit_restart_policy "$cn"
          emit_pair "if failed host 127.0.0.1 port 3306 protocol mysql for 3 cycles" HIGH 1 port 30
          emit_pair "if memory > 70% for 10 cycles" "$WARN_PRIO" 3 mem 120
          echo
        } >> "$out"
        ;;
      postgresql|postgresql@*)
        local pgname
        pgname="$(uniq_name "$(printf '%s' "$s" | tr -c 'a-zA-Z0-9_' '_')")"
        register_name "$pgname"
        pid="$(find_pidfile postgresql.service /var/run/postgresql/*.pid \
               /var/lib/pgsql/data/postmaster.pid /var/lib/postgresql/*/main/postmaster.pid)" || pid=""
        {
          if [ -n "$pid" ]; then echo "check process $pgname with pidfile $pid"
          else echo "check process $pgname matching \"postgres.*checkpointer\""; fi
          echo "  start program = \"/bin/systemctl start $s\" with timeout 90 seconds"
          echo "  stop  program = \"/bin/systemctl stop $s\" with timeout 90 seconds"
          emit_pair "if does not exist for 2 cycles" HIGH 1 pid
          # $pgname, nao $cn: o unmonitor precisa mirar o nome real do check
          restart_ok "$s" && emit_restart_policy "$pgname"
          emit_pair "if failed host 127.0.0.1 port 5432 protocol pgsql for 3 cycles" HIGH 1 port 30
          emit_pair "if memory > 70% for 10 cycles" "$WARN_PRIO" 3 mem 120
          echo
        } >> "$out"
        ;;
      docker)
        pid="$(find_pidfile docker.service /run/docker.pid /var/run/docker.pid)" || pid=""
        {
          if [ -n "$pid" ]; then echo "check process docker with pidfile $pid"
          else echo "check process docker matching \"dockerd\""; fi
          echo "  start program = \"/bin/systemctl start docker\" with timeout 90 seconds"
          echo "  stop  program = \"/bin/systemctl stop docker\" with timeout 60 seconds"
          echo "  # sem restart automatico: derrubaria todos os containers"
          emit_pair "if does not exist for 2 cycles" HIGH 1 pid
          restart_ok "$s" && emit_restart_policy "$cn"
          emit_pair "if failed unixsocket /var/run/docker.sock for 3 cycles" HIGH 1 socket 30
          echo
        } >> "$out"
        ;;
      php*-fpm)
        local ver c
        ver="$(echo "$s" | sed 's/php\(.*\)-fpm/\1/')"
        pid="$(find_pidfile "${s}.service" "/run/php/php${ver}-fpm.pid" \
               "/run/php-fpm/php-fpm.pid" "/var/run/php/php${ver}-fpm.pid")" || pid=""

        # Um php-fpm pode ter VARIOS pools, cada um com seu socket ou porta.
        # Adivinhar "/run/php/phpX.Y-fpm.sock" gera falso positivo quando os
        # pools usam nomes proprios. A fonte da verdade sao os arquivos de pool.
        local -a psocks=() pports=()
        local pooldir="/etc/php/${ver}/fpm/pool.d"
        [ -d "$pooldir" ] || pooldir="/etc/php-fpm.d"
        if [ -d "$pooldir" ]; then
          while read -r lv; do
            case "$lv" in
              /*)            [ -S "$lv" ] && psocks+=("$lv") ;;
              *:[0-9]*)      pports+=("${lv##*:}") ;;
              [0-9]*)        pports+=("$lv") ;;
            esac
          done < <(grep -hE '^[[:space:]]*listen[[:space:]]*=' "$pooldir"/*.conf 2>/dev/null \
                   | sed 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*//; s/[[:space:]]*$//' \
                   | sort -u || true)
        fi
        # fallback: caminhos convencionais, se nenhum pool foi lido
        if [ ${#psocks[@]} -eq 0 ] && [ ${#pports[@]} -eq 0 ]; then
          for c in "/run/php/php${ver}-fpm.sock" "/var/run/php/php${ver}-fpm.sock" \
                   "/run/php-fpm/www.sock"; do
            [ -S "$c" ] && { psocks+=("$c"); break; }
          done
        fi
        {
          if [ -n "$pid" ]; then echo "check process $cn with pidfile $pid"
          else echo "check process $cn matching \"php-fpm.*master.*${ver}\""; fi
          echo "  start program = \"/bin/systemctl start $s\" with timeout 60 seconds"
          echo "  stop  program = \"/bin/systemctl stop $s\" with timeout 30 seconds"
          emit_pair "if does not exist for 2 cycles" HIGH 1 pid
          restart_ok "$s" && emit_restart_policy "$cn"
          local sname n=0
          for c in ${psocks[@]+"${psocks[@]}"}; do
            n=$((n + 1))
            # printf sem newline: 'tr' converteria a quebra de linha num '_'
            # extra, gerando sufixos como "sock_php8_2_fpm_".
            sname="$(printf '%s' "$(basename "$c" .sock)" | tr -c 'a-zA-Z0-9_' '_')"
            echo "  # pool: $c"
            emit_pair "if failed unixsocket $c for 3 cycles" HIGH 1 "sock_${sname}" 30
          done
          for c in ${pports[@]+"${pports[@]}"}; do
            echo "  # pool TCP: porta $c"
            emit_pair "if failed host 127.0.0.1 port $c type tcp for 3 cycles" \
              HIGH 1 "tcp_${c}" 30
          done
          if [ "$n" -eq 0 ] && [ ${#pports[@]} -eq 0 ]; then
            echo "  # nenhum socket/porta de pool encontrado - so o PID e checado."
            echo "  # Verifique 'listen =' em $pooldir/*.conf e adicione a mao."
          fi
          emit_pair "if children > 200 for 5 cycles" "$WARN_PRIO" 3 children 120
          emit_pair "if total memory > 60% for 10 cycles" "$WARN_PRIO" 3 mem 120
          echo
        } >> "$out"
        ;;
      redis|redis-server|valkey|valkey-server)
        pid="$(find_pidfile "${s}.service" /run/redis/redis-server.pid \
               /run/redis/redis.pid /var/run/redis/redis-server.pid \
               /run/valkey/valkey.pid /var/lib/redis/redis.pid)" || pid=""
        local rsock=""
        for c in /run/redis/redis-server.sock /run/redis/redis.sock \
                 /var/run/redis/redis.sock; do
          [ -S "$c" ] && { rsock="$c"; break; }
        done
        {
          if [ -n "$pid" ]; then echo "check process $cn with pidfile $pid"
          else echo "check process $cn matching \"redis-server|valkey-server\""; fi
          echo "  start program = \"/bin/systemctl start $s\" with timeout 60 seconds"
          echo "  stop  program = \"/bin/systemctl stop $s\" with timeout 60 seconds"
          echo "  # sem restart automatico: se usado como cache com persistencia,"
          echo "  # reiniciar as cegas pode perder dados nao salvos no RDB/AOF"
          emit_pair "if does not exist for 2 cycles" HIGH 1 pid
          restart_ok "$s" && emit_restart_policy "$cn"
          emit_pair "if failed host 127.0.0.1 port 6379 type tcp protocol redis for 3 cycles" \
            HIGH 1 port 30
          if [ -n "$rsock" ]; then
            emit_pair "if failed unixsocket $rsock for 3 cycles" HIGH 2 socket 30
          fi
          echo "  # Redis estourando memoria comeca a evictar chaves em silencio"
          emit_pair "if memory > 70% for 10 cycles" "$WARN_PRIO" 3 mem 120
          emit_pair "if cpu > 80% for 10 cycles" "$WARN_PRIO" 3 cpu 120
          echo
        } >> "$out"
        ;;
      *) warn "sem template para '$s' - pulado" ;;
    esac
  done

  write_file "$CONF_D/10-services.conf" 0600 < "$out"
  rm -f "$out"
}

#------------------------------------------------------------------------------
# checks de porta TCP (containers, servicos internos, qualquer coisa que escute)
#------------------------------------------------------------------------------
# Teste de conexao pura, equivalente a um telnet: prova que ALGO aceita conexao
# naquela porta. Um container pode estar "Up" no docker ps com a aplicacao
# travada por dentro - a porta responde ou nao, sem meio-termo.
# Protocolo sugerido a partir da porta: o teste de protocolo vale muito mais que
# o TCP puro (um container travado ainda aceita conexao, mas nao fala o protocolo).
guess_proto() {
  case "$1" in
    80|8080|8000|3000|5000|8081) echo http ;;
    443|8443)                    echo https ;;
    3306)                        echo mysql ;;
    5432)                        echo pgsql ;;
    6379)                        echo redis ;;
    27017)                       echo mongodb ;;
    25|587)                      echo smtp ;;
    22)                          echo ssh ;;
    53)                          echo dns ;;
    5672)                        echo amqp ;;
    11211)                       echo memcache ;;
    *)                           echo "" ;;
  esac
}

gen_port_checks() {
  head1 "10b. Portas TCP"
  local -a entries=() cand=()
  local e name port host proto reply

  if [ -n "$PORTS_ARG" ]; then
    IFS=',' read -r -a entries <<< "$PORTS_ARG"
  else
    # --- containers Docker: portas publicadas ---
    if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
      mapfile -t cand < <(
        docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | \
        awk -F'|' '{n=$1; gsub(/[^a-zA-Z0-9_]/,"_",n); s=$2
                    while (match(s, /:[0-9]+->/)) {
                      print n ":" substr(s, RSTART+1, RLENGTH-3)
                      s = substr(s, RSTART+RLENGTH) }}' | sort -u || true
      )
    fi
    if [ ${#cand[@]} -gt 0 ]; then
      echo "  Containers com portas publicadas:"
      printf '    %s\n' "${cand[@]}"
      echo
      if [ "$ASSUME_YES" -eq 1 ]; then
        entries=("${cand[@]}")
      else
        echo "  [t] todas  [n] nenhuma  [s] escolher uma a uma"
        reply="$(ask '  Opcao' t)"
        case "$reply" in
          t|T) entries=("${cand[@]}") ;;
          s|S)
            for e in "${cand[@]}"; do
              name="${e%%:*}"; port="${e##*:}"
              if confirm "    Monitorar ${name} (127.0.0.1:${port})?" y; then
                name="$(ask "      Nome nos alertas" "$name")"
                proto="$(ask "      Protocolo (vazio = TCP puro)" "$(guess_proto "$port")")"
                entries+=("${name}:127.0.0.1:${port}${proto:+:$proto}")
              fi
            done ;;
          *) entries=() ;;
        esac
      fi
    fi
    # --- servicos fora deste host ---
    if [ "$ASSUME_YES" -eq 0 ]; then
      while confirm "  Adicionar um servico externo (outro host/IP)?" n; do
        name="$(ask '    Nome nos alertas' '')"
        host="$(ask '    Host ou IP' '127.0.0.1')"
        port="$(ask '    Porta' '')"
        [[ "$port" =~ ^[0-9]+$ ]] || { warn "porta invalida - ignorado"; continue; }
        [ -n "$name" ] || name="${host}_${port}"
        proto="$(ask '    Protocolo (vazio = TCP puro)' "$(guess_proto "$port")")"
        entries+=("${name}:${host}:${port}${proto:+:$proto}")
      done
    fi
  fi

  if [ ${#entries[@]} -eq 0 ]; then
    warn "nenhuma porta TCP configurada (use --ports nome:host:porta:protocolo)"
    return
  fi

  local -a used=()
  {
    echo "# 15-ports.conf - gerado em $(date -Iseconds)"
    echo "# Teste TCP puro ou com validacao de protocolo. O nome de cada check e"
    echo "# o que aparece no summary do alerta - mantenha legivel."
    echo
    local fields cname
    for e in "${entries[@]}"; do
      IFS=':' read -r -a fields <<< "$e"
      name="${fields[0]}"; host="127.0.0.1"; port=""; proto=""
      case "${#fields[@]}" in
        2) port="${fields[1]}" ;;
        3) if [[ "${fields[1]}" =~ ^[0-9]+$ ]]; then
             port="${fields[1]}"; proto="${fields[2]}"
           else host="${fields[1]}"; port="${fields[2]}"; fi ;;
        4) host="${fields[1]}"; port="${fields[2]}"; proto="${fields[3]}" ;;
        *) warn "entrada invalida: $e"; continue ;;
      esac
      name="$(printf '%s' "$name" | tr -c 'a-zA-Z0-9_' '_')"
      [[ "$port" =~ ^[0-9]+$ ]] || { warn "porta invalida em: $e"; continue; }
      # nome do check = nome amigavel; so desambigua se repetir
      cname="$(uniq_name "$name")"; register_name "$cname"
      case " ${used[*]-} " in *" $cname "*) cname="${name}_${port}" ;; esac
      used+=("$cname")
      printf '  %-24s %s:%s%s\n' "$cname" "$host" "$port" "${proto:+ ($proto)}" >&2
      echo "check host $cname with address $host"
      emit_pair "if failed port $port type tcp${proto:+ protocol $proto} with timeout 5 seconds for 3 cycles" \
        HIGH 2 "port${port}" 30
      echo
    done
  } > /tmp/15-ports.conf
  write_file "$CONF_D/15-ports.conf" 0600 < /tmp/15-ports.conf
  rm -f /tmp/15-ports.conf
}

#------------------------------------------------------------------------------
# validacao e ativacao
#------------------------------------------------------------------------------
validate_and_start() {
  head1 "11. Validacao"
  [ "$DRY_RUN" -eq 1 ] && { warn "dry-run: pulando validacao"; return; }

  if ! monit -t; then
    warn "monit -t falhou - revertendo para os arquivos anteriores"
    rollback
    die "configuracao revertida. Rode com --dry-run e inspecione a saida."
  fi
  ok "sintaxe validada"

  run systemctl enable monit >/dev/null 2>&1 || true

  # 'reload' nao aplica mudanca de unit do systemd: ReadWritePaths so passa a
  # valer com um restart de verdade. Por isso o restart e obrigatorio quando
  # criamos o drop-in nesta execucao.
  if [ "$SANDBOX_DROPIN" -eq 1 ]; then
    run systemctl restart monit
  elif systemctl is-active --quiet monit; then
    run systemctl reload monit || run systemctl restart monit
  else
    run systemctl start monit
  fi
  if ! wait_monit_ready; then
    if [ "$SANDBOX_DROPIN" -eq 1 ]; then
      warn "monit nao subiu - suspeitando do drop-in do systemd, removendo"
      rm -f /etc/systemd/system/monit.service.d/ilert.conf
      systemctl daemon-reload || true
      systemctl start monit || true
      if wait_monit_ready; then
        warn "monit voltou SEM o drop-in - sockets unix podem falhar"
        warn "veja 'systemctl status monit' e ajuste ReadWritePaths a mao"
        ok "monit ativo"
        return
      fi
    fi
    rollback
    die "monit nao subiu e a configuracao foi revertida: journalctl -u monit -n 50"
  fi
  ok "monit ativo"
}

send_test_event() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  head1 "12. Teste ponta a ponta"
  if confirm "  Enviar evento de teste ao ilert (abre e fecha um alerta)?" y; then
    local env_common=(
      "MONIT_HOST=$(hostname)"
      "MONIT_SERVICE=instalacao"
      "MONIT_EVENT=Test"
    )
    if env "${env_common[@]}" MONIT_DESCRIPTION="teste do instalador v$SCRIPT_VERSION" \
         MONIT_DATE="$(date -Iseconds)" "$BIN_DIR/ilert.sh" ALERT HIGH 3 selftest; then
      ok "ALERT enviado - confira no app do ilert"
      sleep 5
      # ILERT_RESOLVE_DELAY=0 e obrigatorio aqui: sem isso o RESOLVE viraria
      # marcador pendente e o alerta de teste ficaria aberto ate o flush rodar
      # (5 min por padrao), passando a impressao de que a instalacao falhou.
      if env "${env_common[@]}" ILERT_RESOLVE_DELAY=0 \
           MONIT_DESCRIPTION="teste concluido" \
           MONIT_DATE="$(date -Iseconds)" \
           "$BIN_DIR/ilert.sh" RESOLVE HIGH 3 selftest; then
        ok "RESOLVE enviado - o alerta de teste ja deve estar fechado"
      else
        warn "RESOLVE falhou - feche o alerta de teste a mao no ilert"
      fi
    else
      warn "falha no envio. Verifique a integration key: journalctl -t ilert -n 20"
    fi
  fi
  if [ "$WANT_HEARTBEAT" -eq 1 ]; then
    if "$BIN_DIR/ilert-beat.sh"; then
      ok "heartbeat pingado (o timer do ilert comeca agora)"
    else
      warn "heartbeat falhou - confira a heartbeat key"
    fi
  fi
}

# Um erro de ambiente (sandbox do systemd, socket em caminho errado, porta que
# nao escuta) so apareceria como enxurrada de alertas minutos depois. Aqui o
# Monit e forcado a avaliar tudo agora e o resultado vai para a tela.
post_install_check() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  head1 "13. Verificacao dos checks"
  monit validate >/dev/null 2>&1 || true
  sleep 8
  local out failed
  out="$(monit summary 2>/dev/null || true)"
  if [ -z "$out" ]; then
    warn "nao consegui ler 'monit summary' - rode a mao daqui a um minuto"
    return 0
  fi
  # Colunas: Service Name | Status | Type. Qualquer coisa fora de OK/Initializing
  failed="$(printf '%s\n' "$out" | awk 'NR>2 && $0 !~ /(OK|Initializing|Waiting)/ && NF>1')"
  if [ -z "$failed" ]; then
    ok "todos os checks passaram"
    return 0
  fi
  warn "checks com problema logo apos a instalacao:"
  printf '%s\n' "$failed" | sed 's/^/    /'
  # Diagnostico do caso mais comum e mais dificil de adivinhar
  if printf '%s\n' "$failed" | grep -qi 'connection failed'; then
    local prot
    prot="$(systemctl show monit -p ProtectSystem --value 2>/dev/null || true)"
    case "$prot" in
      strict|full|yes)
        warn "ProtectSystem=$prot ativo: /run fica somente-leitura para o monit"
        warn "e conectar em socket unix exige escrita no arquivo do socket."
        warn "Confira 'systemctl show monit -p ReadWritePaths' e reinstale se vazio."
        ;;
      *)
        warn "'Connection failed' em socket/porta: confira se o servico escuta"
        warn "no caminho configurado (ss -lx | grep <socket>)."
        ;;
    esac
  fi
  warn "corrija antes que virem alerta: cada check falhando abre um alerta"
}

summary() {
  head1 "Resumo"
  cat <<EOF
  Arquivos:
    $BIN_DIR/ilert.sh          (700)
    $( [ "$WANT_HEARTBEAT" -eq 1 ] && echo "$BIN_DIR/ilert-beat.sh     (700)")
    $ENV_FILE               (600)  <- unico arquivo com segredo
    $MONITRC
    $CONF_D/00-system.conf
    $CONF_D/01-filesystem.conf
    $( [ -n "$GATEWAY" ] && echo "$CONF_D/02-network.conf")
    $( [ "$WANT_HEARTBEAT" -eq 1 ] && echo "$CONF_D/03-heartbeat.conf")
    $( [ ${#CHOSEN[@]} -gt 0 ] && echo "$CONF_D/10-services.conf")
    $( [ -f "$CONF_D/15-ports.conf" ] && echo "$CONF_D/15-ports.conf")

  Customizacoes suas: crie $CONF_D/20-custom.conf
  O instalador NUNCA toca em arquivos fora dos nomes acima.

  Comandos uteis:
    monit status              estado de todos os checks
    monit summary             visao compacta
    monit -t                  valida sintaxe apos editar
    systemctl reload monit    aplica mudancas
    tail -f /var/log/monit.log
    journalctl -t ilert       falhas de envio ao ilert

  Proximos passos no ilert:
    1. Defina auto_resolution_timeout no alert source (rede de seguranca para
       alertas orfaos se o host morrer sem enviar RESOLVE).
    2. Confira se o alert source respeita o 'priority' do evento; se ignorar,
       derive a prioridade via event filter em ICL.
    3. Ajuste os limiares apos 1-2 semanas de sar: warning = p95 + 20%.

  Teste real recomendado:
    systemctl stop nginx   # aguarde 2 ciclos, confira o alerta e os labels
    systemctl start nginx  # deve fechar sozinho
EOF
}

uninstall() {
  head1 "Desinstalando"
  confirm "  Remover scripts, configs e parar o monit?" n || die "abortado"
  run systemctl stop monit || true
  run rm -f "$BIN_DIR/ilert.sh" "$BIN_DIR/ilert-beat.sh"
  # Nomes explicitos: um glob '0*.conf' apagaria configs de terceiros.
  local f
  for f in 00-system 01-filesystem 02-network 03-heartbeat 04-flush 10-services 15-ports; do
    run rm -f "$CONF_D/${f}.conf"
  done
  run rm -rf /var/lib/ilert
  warn "mantidos: $ENV_FILE, $MONITRC e os backups em $BACKUP_DIR"
  ok "desinstalado"
  exit 0
}

#------------------------------------------------------------------------------
main() {
  printf '%sinstall-monit-ilert.sh v%s%s\n' "$c_bold" "$SCRIPT_VERSION" "$c_reset"
  detect_distro
  [ "$DO_UNINSTALL" -eq 1 ] && uninstall
  install_deps
  collect_keys
  install_scripts
  compute_thresholds
  write_monitrc
  collect_existing_names
  gen_system_checks
  gen_filesystem_checks
  gen_network_checks
  gen_heartbeat_check
  gen_flush_check
  detect_services
  gen_service_checks
  gen_port_checks
  ensure_monit_sandbox
  validate_and_start
  send_test_event
  post_install_check
  summary
}

main "$@"
