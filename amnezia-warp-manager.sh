#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="amnezia-warp-manager"
WGCF_VERSION="2.2.30"
WGCF_BIN="/root/wgcf"
WGCF_ACCOUNT="/root/wgcf-account.toml"
WGCF_PROFILE="/root/wgcf-profile.conf"

CONTAINER=""
VPN_CONF=""
VPN_IF=""
VPN_QUICK_CMD=""
CLIENTS_TABLE=""
START_SH=""
WARP_DIR="/opt/warp"
WARP_CONF="/opt/warp/warp.conf"
WARP_CLIENTS="/opt/warp/clients.list"
SUBNET=""
WARP_ENDPOINT_IP=""
SELECTED_IPS=()

MARKER_BEGIN="# --- WARP-MANAGER BEGIN ---"
MARKER_END="# --- WARP-MANAGER END ---"

C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

log()  { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Запусти скрипт от root"
    exit 1
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Не найдена команда: $1"
    exit 1
  }
}

check_base() {
  require_root
  require_cmd docker
  require_cmd curl
  require_cmd wget
  require_cmd awk
  require_cmd sed
  require_cmd grep
  require_cmd getent
}

pick_container() {
  local containers=()
  mapfile -t containers < <(docker ps --format '{{.Names}}' | grep -E '^amnezia-awg2$|^amnezia-awg$' || true)

  if [ "${#containers[@]}" -eq 0 ]; then
    err "Контейнеры amnezia-awg / amnezia-awg2 не найдены"
    exit 1
  fi

  if [ "${#containers[@]}" -eq 1 ]; then
    CONTAINER="${containers[0]}"
    ok "Найден контейнер: $CONTAINER"
    return
  fi

  echo
  echo -e "${C_BOLD}Доступные контейнеры:${C_RESET}"
  local i=1
  for c in "${containers[@]}"; do
    echo "  $i) $c"
    i=$((i+1))
  done

  echo
  read -rp "Выбери контейнер по номеру: " choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#containers[@]}" ]; then
    err "Неверный выбор"
    exit 1
  fi

  CONTAINER="${containers[$((choice-1))]}"
  ok "Выбран контейнер: $CONTAINER"
}

load_container_data() {
  if [ "$CONTAINER" = "amnezia-awg2" ]; then
    VPN_CONF="/opt/amnezia/awg/awg0.conf"
    VPN_IF="awg0"
    VPN_QUICK_CMD="awg-quick"
  else
    VPN_CONF="/opt/amnezia/awg/wg0.conf"
    VPN_IF="wg0"
    VPN_QUICK_CMD="wg-quick"
  fi

  CLIENTS_TABLE="/opt/amnezia/awg/clientsTable"
  START_SH="/opt/amnezia/start.sh"

  docker exec "$CONTAINER" sh -c "[ -f '$VPN_CONF' ]" >/dev/null 2>&1 || {
    err "Не найден конфиг VPN в контейнере: $VPN_CONF"
    exit 1
  }

  SUBNET="$(docker exec "$CONTAINER" sh -c "sed -n 's/^Address = \\(.*\\)$/\\1/p' '$VPN_CONF' | head -n1 | cut -d',' -f1" | tr -d '\r')"
  [ -n "$SUBNET" ] || {
    err "Не удалось определить подсеть из $VPN_CONF"
    exit 1
  }

  ok "Интерфейс: $VPN_IF  |  Команда: $VPN_QUICK_CMD  |  Подсеть: $SUBNET"
}

backup_container_files() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  docker exec "$CONTAINER" sh -c "
    cp '$VPN_CONF' '${VPN_CONF}.bak-${ts}' &&
    cp '$CLIENTS_TABLE' '${CLIENTS_TABLE}.bak-${ts}' &&
    cp '$START_SH' '${START_SH}.bak-${ts}'
  " >/dev/null

  docker exec "$CONTAINER" sh -c "[ -f /opt/amnezia/start.sh.final-backup ] || cp '$START_SH' /opt/amnezia/start.sh.final-backup" >/dev/null 2>&1 || true

  ok "Бэкап сделан — $ts"
}

install_wgcf_host() {
  if [ -x "$WGCF_BIN" ]; then
    ok "wgcf уже есть на хосте"
    return
  fi

  local arch
  arch="$(uname -m)"
  local wgcf_arch=""
  case "$arch" in
    x86_64)  wgcf_arch="amd64" ;;
    aarch64) wgcf_arch="arm64" ;;
    armv7l)  wgcf_arch="armv7" ;;
    *) err "Неподдерживаемая архитектура: $arch"; exit 1 ;;
  esac

  log "Скачиваю wgcf ($wgcf_arch) на хост"
  wget -O "$WGCF_BIN" "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${wgcf_arch}"
  chmod +x "$WGCF_BIN"
  ok "wgcf скачан"
}

ensure_wgcf_account() {
  if [ ! -f "$WGCF_ACCOUNT" ]; then
    echo
    warn "Сейчас будет регистрация WARP через wgcf"
    warn "Если спросит подтверждение условий — введи y"
    (cd /root && ./wgcf register)
  else
    ok "wgcf-account.toml уже существует"
  fi

  [ -f "$WGCF_ACCOUNT" ] || {
    err "Не создан $WGCF_ACCOUNT"
    exit 1
  }
}

generate_warp_profile() {
  log "Генерирую WARP-профиль"
  (cd /root && ./wgcf generate)
  [ -f "$WGCF_PROFILE" ] || {
    err "Не создан $WGCF_PROFILE"
    exit 1
  }
  ok "WARP-профиль создан"
}

resolve_warp_endpoint() {
  WARP_ENDPOINT_IP="$(getent ahostsv4 engage.cloudflareclient.com | awk 'NR==1{print $1}')"
  [ -n "${WARP_ENDPOINT_IP:-}" ] || {
    err "Не удалось определить IP engage.cloudflareclient.com"
    exit 1
  }
  ok "Endpoint WARP: $WARP_ENDPOINT_IP"
}

copy_profile_into_container() {
  docker exec "$CONTAINER" sh -c "mkdir -p '$WARP_DIR'"
  docker cp "$WGCF_PROFILE" "${CONTAINER}:${WARP_DIR}/wgcf-profile.conf"
  ok "Профиль скопирован в контейнер"
}

build_warp_conf_in_container() {
  local private_key public_key address
  private_key="$(awk -F' = ' '/^PrivateKey = /{print $2}' "$WGCF_PROFILE")"
  public_key="$(awk -F' = ' '/^PublicKey = /{print $2}' "$WGCF_PROFILE")"
  address="$(awk -F' = ' '/^Address = /{print $2}' "$WGCF_PROFILE" | cut -d',' -f1)"

  docker exec "$CONTAINER" sh -c "cat > '$WARP_CONF' <<'WARPEOF'
[Interface]
PrivateKey = ${private_key}
Address = ${address}
MTU = 1280
Table = off

[Peer]
PublicKey = ${public_key}
AllowedIPs = 0.0.0.0/0
Endpoint = ${WARP_ENDPOINT_IP}:2408
PersistentKeepalive = 25
WARPEOF
chmod 600 '$WARP_CONF'
"
  ok "Создан $WARP_CONF"
}

ensure_warp_up_now() {
  docker exec "$CONTAINER" sh -c "wg-quick down '$WARP_CONF' >/dev/null 2>&1 || true"
  docker exec "$CONTAINER" sh -c "wg-quick up '$WARP_CONF'"
  docker exec "$CONTAINER" sh -c "ip addr show warp >/dev/null 2>&1" || {
    err "Интерфейс warp не поднялся"
    exit 1
  }
  ok "Интерфейс warp поднят"
}

# --- Persistent client list management ---

load_warp_clients() {
  SELECTED_IPS=()
  local raw
  raw="$(docker exec "$CONTAINER" sh -c "cat '$WARP_CLIENTS' 2>/dev/null || true" | tr -d '\r')"
  if [ -n "$raw" ]; then
    while IFS= read -r line; do
      line="$(echo "$line" | xargs)"
      [ -n "$line" ] && SELECTED_IPS+=("$line")
    done <<< "$raw"
  fi
}

save_warp_clients() {
  local content=""
  for ip in "${SELECTED_IPS[@]}"; do
    content="${content}${ip}"$'\n'
  done
  docker exec "$CONTAINER" sh -c "mkdir -p '$WARP_DIR' && cat > '$WARP_CLIENTS' <<'CLEOF'
${content}CLEOF
"
}

# --- Client display with names ---

get_clients_table_map() {
  declare -gA CLIENT_NAMES=()
  local raw
  raw="$(docker exec "$CONTAINER" sh -c "cat '$CLIENTS_TABLE' 2>/dev/null || true" | tr -d '\r')"
  [ -z "$raw" ] && return

  local current_name=""
  while IFS= read -r line; do
    if echo "$line" | grep -qE '"clientName"'; then
      current_name="$(echo "$line" | sed 's/.*"clientName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
    elif echo "$line" | grep -qE '"clientIP"'; then
      local ip
      ip="$(echo "$line" | sed 's/.*"clientIP"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
      if [ -n "$current_name" ] && [ -n "$ip" ]; then
        CLIENT_NAMES["$ip"]="$current_name"
      fi
    fi
  done <<< "$raw"
}

get_client_name() {
  local ip="${1%/32}"
  if [ -n "${CLIENT_NAMES[$ip]+x}" ]; then
    echo "${CLIENT_NAMES[$ip]}"
  else
    echo ""
  fi
}

get_client_ips_from_conf() {
  mapfile -t CLIENT_IPS < <(docker exec "$CONTAINER" sh -c "sed -n 's/^AllowedIPs = \\(.*\\/32\\)$/\\1/p' '$VPN_CONF'" | tr -d '\r')
  if [ "${#CLIENT_IPS[@]}" -eq 0 ]; then
    err "Не удалось получить список IP клиентов"
    exit 1
  fi
}

show_client_ips_numbered() {
  echo
  echo -e "${C_BOLD}Клиенты VPN:${C_RESET}"

  load_warp_clients
  local warp_set=" ${SELECTED_IPS[*]} "

  local i=1
  for ip in "${CLIENT_IPS[@]}"; do
    local name
    name="$(get_client_name "$ip")"
    local label="$ip"
    [ -n "$name" ] && label="$ip  ($name)"

    if [[ "$warp_set" == *" $ip "* ]]; then
      echo -e "  ${C_GREEN}$i) $label  [WARP]${C_RESET}"
    else
      echo "  $i) $label"
    fi
    i=$((i+1))
  done
  echo "  all) все клиенты"
  echo
}

choose_ips_to_add() {
  get_client_ips_from_conf
  get_clients_table_map
  show_client_ips_numbered

  read -rp "Введи номер, несколько номеров через запятую, или all: " answer
  [ -z "$answer" ] && return

  local new_ips=()

  if [ "$answer" = "all" ]; then
    new_ips=("${CLIENT_IPS[@]}")
  else
    IFS=',' read -ra parts <<< "$answer"
    for p in "${parts[@]}"; do
      p="$(echo "$p" | xargs)"
      if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt "${#CLIENT_IPS[@]}" ]; then
        err "Неверный выбор: $p"
        return
      fi
      new_ips+=("${CLIENT_IPS[$((p-1))]}")
    done
  fi

  load_warp_clients
  for nip in "${new_ips[@]}"; do
    local found=0
    for eip in "${SELECTED_IPS[@]}"; do
      [ "$nip" = "$eip" ] && found=1 && break
    done
    if [ "$found" -eq 0 ]; then
      SELECTED_IPS+=("$nip")
      ok "Добавлен: $nip"
    else
      log "Уже в WARP: $nip"
    fi
  done

  save_warp_clients
}

choose_ips_to_remove() {
  load_warp_clients

  if [ "${#SELECTED_IPS[@]}" -eq 0 ]; then
    warn "Нет клиентов в WARP"
    return
  fi

  get_clients_table_map

  echo
  echo -e "${C_BOLD}Клиенты в WARP:${C_RESET}"
  local i=1
  for ip in "${SELECTED_IPS[@]}"; do
    local name
    name="$(get_client_name "$ip")"
    local label="$ip"
    [ -n "$name" ] && label="$ip  ($name)"
    echo "  $i) $label"
    i=$((i+1))
  done
  echo "  all) убрать всех из WARP"
  echo

  read -rp "Введи номер, несколько номеров через запятую, или all: " answer
  [ -z "$answer" ] && return

  local remove_ips=()

  if [ "$answer" = "all" ]; then
    remove_ips=("${SELECTED_IPS[@]}")
  else
    IFS=',' read -ra parts <<< "$answer"
    for p in "${parts[@]}"; do
      p="$(echo "$p" | xargs)"
      if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt "${#SELECTED_IPS[@]}" ]; then
        err "Неверный выбор: $p"
        return
      fi
      remove_ips+=("${SELECTED_IPS[$((p-1))]}")
    done
  fi

  local new_list=()
  for eip in "${SELECTED_IPS[@]}"; do
    local removing=0
    for rip in "${remove_ips[@]}"; do
      [ "$eip" = "$rip" ] && removing=1 && break
    done
    if [ "$removing" -eq 0 ]; then
      new_list+=("$eip")
    else
      ok "Убран из WARP: $eip"
    fi
  done

  SELECTED_IPS=("${new_list[@]+"${new_list[@]}"}")
  save_warp_clients
}

# --- Runtime rules ---

cleanup_runtime_rules() {
  docker exec "$CONTAINER" sh -c '
    ip rule | awk "/lookup 100/ {print \$1}" | sed "s/://g" | sort -rn | while read -r pr; do
      ip rule del priority "$pr" 2>/dev/null || true
    done

    iptables -t nat -S POSTROUTING | grep "\-o warp -j MASQUERADE" | while read -r line; do
      rule=$(echo "$line" | sed "s/^-A /-D /")
      iptables -t nat $rule || true
    done

    ip route flush table 100 2>/dev/null || true
  ' >/dev/null 2>&1 || true
}

apply_runtime_rules() {
  cleanup_runtime_rules

  if [ "${#SELECTED_IPS[@]}" -eq 0 ]; then
    log "Нет клиентов для WARP — правила не применяются"
    return
  fi

  docker exec "$CONTAINER" sh -c "ip route add default dev warp table 100 2>/dev/null || ip route replace default dev warp table 100"

  local prio=100
  for ip in "${SELECTED_IPS[@]}"; do
    docker exec "$CONTAINER" sh -c "
      ip rule add from ${ip} table 100 priority ${prio} 2>/dev/null || true
      iptables -t nat -C POSTROUTING -s ${ip} -o warp -j MASQUERADE 2>/dev/null || \
      iptables -t nat -I POSTROUTING 1 -s ${ip} -o warp -j MASQUERADE
    "
    prio=$((prio+1))
  done
  ok "Runtime-правила применены для ${#SELECTED_IPS[@]} клиентов"
}

# --- start.sh patching (marker-based) ---

patch_start_sh() {
  docker exec "$CONTAINER" sh -c "[ -f /opt/amnezia/start.sh.final-backup ] || cp '$START_SH' /opt/amnezia/start.sh.final-backup"

  local warp_block=""
  warp_block+="${MARKER_BEGIN}"$'\n'
  warp_block+="# Auto-generated by ${SCRIPT_NAME}. Do not edit manually."$'\n'
  warp_block+=""$'\n'

  warp_block+="if [ -f '${WARP_CONF}' ]; then"$'\n'
  warp_block+="  wg-quick up '${WARP_CONF}' || true"$'\n'
  warp_block+="fi"$'\n'
  warp_block+=""$'\n'

  if [ "${#SELECTED_IPS[@]}" -gt 0 ]; then
    warp_block+="ip route add default dev warp table 100 2>/dev/null || ip route replace default dev warp table 100 2>/dev/null || true"$'\n'
    warp_block+=""$'\n'

    local prio=100
    for ip in "${SELECTED_IPS[@]}"; do
      warp_block+="ip rule add from ${ip} table 100 priority ${prio} 2>/dev/null || true"$'\n'
      warp_block+="iptables -t nat -C POSTROUTING -s ${ip} -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s ${ip} -o warp -j MASQUERADE"$'\n'
      prio=$((prio+1))
    done
  fi

  warp_block+=""$'\n'
  warp_block+="${MARKER_END}"

  local escaped_block
  escaped_block="$(echo "$warp_block" | sed 's/[&/\]/\\&/g')"

  docker exec "$CONTAINER" sh -c "
    if grep -qF '${MARKER_BEGIN}' '$START_SH'; then
      sed -i '/${MARKER_BEGIN//\//\\/}/,/${MARKER_END//\//\\/}/d' '$START_SH'
    fi

    if grep -qF 'tail -f /dev/null' '$START_SH'; then
      sed -i '/tail -f \\/dev\\/null/i\\
' '$START_SH'
    fi
  "

  docker exec "$CONTAINER" sh -c "
    if grep -qF 'tail -f /dev/null' '$START_SH'; then
      # Insert before 'tail -f /dev/null'
      tmpfile=\$(mktemp)
      while IFS= read -r line; do
        if echo \"\$line\" | grep -qF 'tail -f /dev/null'; then
          cat <<'WARPBLOCK'
${warp_block}
WARPBLOCK
        fi
        echo \"\$line\"
      done < '$START_SH' > \"\$tmpfile\"
      mv \"\$tmpfile\" '$START_SH'
      chmod +x '$START_SH'
    else
      # Append to end
      cat >> '$START_SH' <<'WARPBLOCK'

${warp_block}
WARPBLOCK
      chmod +x '$START_SH'
    fi
  "

  ok "start.sh обновлён (блок WARP-MANAGER)"
}

remove_warp_from_start_sh() {
  docker exec "$CONTAINER" sh -c "
    if grep -qF '${MARKER_BEGIN}' '$START_SH'; then
      sed -i '/${MARKER_BEGIN//\//\\/}/,/${MARKER_END//\//\\/}/d' '$START_SH'
    fi
  " 2>/dev/null || true
}

# --- High-level flows ---

ensure_warp_installed() {
  local warp_exists=0
  docker exec "$CONTAINER" sh -c "[ -f '$WARP_CONF' ]" 2>/dev/null && warp_exists=1

  if [ "$warp_exists" -eq 0 ]; then
    log "WARP не установлен — запускаю установку"
    backup_container_files
    install_wgcf_host
    ensure_wgcf_account
    generate_warp_profile
    resolve_warp_endpoint
    copy_profile_into_container
    build_warp_conf_in_container
    ensure_warp_up_now
  else
    ok "WARP уже установлен в контейнере"
    docker exec "$CONTAINER" sh -c "ip addr show warp >/dev/null 2>&1" || {
      log "Поднимаю интерфейс warp"
      ensure_warp_up_now
    }
  fi
}

action_add_clients() {
  ensure_warp_installed
  choose_ips_to_add
  apply_runtime_rules
  patch_start_sh
  ok "Готово. Изменения сохранены и переживут рестарт."
}

action_remove_clients() {
  choose_ips_to_remove
  apply_runtime_rules
  patch_start_sh
  ok "Готово. Изменения сохранены и переживут рестарт."
}

action_show_warp_clients() {
  load_warp_clients
  get_clients_table_map

  echo
  if [ "${#SELECTED_IPS[@]}" -eq 0 ]; then
    warn "Нет клиентов в WARP"
  else
    echo -e "${C_BOLD}Клиенты в WARP (${#SELECTED_IPS[@]}):${C_RESET}"
    for ip in "${SELECTED_IPS[@]}"; do
      local name
      name="$(get_client_name "$ip")"
      local label="$ip"
      [ -n "$name" ] && label="$ip  ($name)"
      echo -e "  ${C_GREEN}●${C_RESET} $label"
    done
  fi
  echo
}

full_uninstall_warp() {
  log "Полное удаление WARP из контейнера $CONTAINER"

  cleanup_runtime_rules

  docker exec "$CONTAINER" sh -c "
    wg-quick down '$WARP_CONF' 2>/dev/null || true
    ip link del warp 2>/dev/null || true
    rm -rf '$WARP_DIR'
  " >/dev/null 2>&1 || true

  remove_warp_from_start_sh

  if docker exec "$CONTAINER" sh -c '[ -f /opt/amnezia/start.sh.final-backup ]'; then
    docker exec "$CONTAINER" sh -c "
      cp /opt/amnezia/start.sh.final-backup '$START_SH'
      chmod +x '$START_SH'
    "
    ok "start.sh восстановлен из final-backup"
  else
    warn "Бэкап /opt/amnezia/start.sh.final-backup не найден"
  fi

  docker restart "$CONTAINER" >/dev/null
  sleep 2
  ok "WARP полностью удалён из контейнера $CONTAINER"

  read -rp "Удалить wgcf и профили WARP на хосте тоже? [y/N]: " ans
  if [[ "${ans,,}" = "y" ]]; then
    rm -f "$WGCF_BIN" "$WGCF_ACCOUNT" "$WGCF_PROFILE"
    ok "Файлы wgcf на хосте удалены"
  fi
}

restart_container() {
  docker restart "$CONTAINER" >/dev/null
  local attempts=0
  while [ "$attempts" -lt 10 ]; do
    if docker exec "$CONTAINER" sh -c "true" 2>/dev/null; then
      ok "Контейнер перезапущен"
      return
    fi
    sleep 1
    attempts=$((attempts+1))
  done
  err "Контейнер не поднялся за 10 секунд"
  exit 1
}

show_status() {
  echo
  echo -e "${C_BOLD}===== STATUS: $CONTAINER =====${C_RESET}"
  docker exec "$CONTAINER" sh -c '
echo "-- warp iface --"
ip addr show warp 2>/dev/null || echo "warp отсутствует"
echo "-----"
echo "-- wg show warp --"
wg show warp 2>/dev/null || echo "warp не поднят"
echo "-----"
echo "-- ip rule --"
ip rule
echo "-----"
echo "-- nat postrouting --"
iptables -t nat -S POSTROUTING
'
  echo

  action_show_warp_clients
}

# --- Menu ---

print_menu() {
  echo
  echo -e "${C_BOLD}╔══════════════════════════════════════╗${C_RESET}"
  echo -e "${C_BOLD}║       ${SCRIPT_NAME}       ║${C_RESET}"
  echo -e "${C_BOLD}╚══════════════════════════════════════╝${C_RESET}"
  echo -e "  Контейнер: ${C_CYAN}${CONTAINER}${C_RESET}"
  echo -e "  Подсеть:   ${C_CYAN}${SUBNET}${C_RESET}"
  echo
  echo -e "  ${C_GREEN}1)${C_RESET} Добавить клиентов в WARP"
  echo -e "  ${C_YELLOW}2)${C_RESET} Убрать клиентов из WARP"
  echo -e "  ${C_CYAN}3)${C_RESET} Показать клиентов в WARP"
  echo -e "  ${C_CYAN}4)${C_RESET} Показать статус"
  echo -e "  ${C_YELLOW}5)${C_RESET} Перезапустить контейнер"
  echo -e "  ${C_RED}6)${C_RESET} Полностью удалить WARP"
  echo -e "  0) Выход"
  echo
}

menu() {
  while true; do
    print_menu
    read -rp "Выбери пункт: " action

    case "$action" in
      1) action_add_clients ;;
      2) action_remove_clients ;;
      3) action_show_warp_clients ;;
      4) show_status ;;
      5) restart_container; show_status ;;
      6) full_uninstall_warp; show_status ;;
      0) ok "Выход"; exit 0 ;;
      *) err "Неверный пункт" ;;
    esac
  done
}

main() {
  check_base
  pick_container
  load_container_data
  menu
}

main "$@"
