#!/bin/bash

# Script de Configuração do Kiosk para Linux Mint
# Versão unificada com suporte a PWA e detecção inteligente de travamentos
# Otimizado para Linux Mint 22 Cinnamon
# CORREÇÕES FINAIS:
#   - SSH instalado primeiro
#   - VNC sem systemd user (só autostart)
#   - Chromium via Flatpak com ambiente X11 forçado
#   - TODAS as configurações do usuário movidas para pós-reboot
#   - Diretórios systemd criados explicitamente
#   - Login automático configurado
#   - Bloqueio de tela desabilitado (pós-reboot)
#   - Suspensão/hibernação desabilitada
#   - Duplicação automática para TV HDMI (PERSISTENTE)
#   - Serviço systemd dedicado para displays
#   - Relatório detalhado ao final
# Autor: Baseado em scripts validados para Raspberry Pi e Linux Mint

set -e  # Sai imediatamente se algum comando falhar

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================
#          FUNÇÃO DE VALIDAÇÃO DE URL
# ============================================

validate_url() {
    local input_url="$1"
    
    # Remove espaços
    input_url=$(echo "$input_url" | xargs)
    
    # Se vazio, erro
    [[ -z "$input_url" ]] && return 1
    
    # Converte para minúsculas
    input_url=$(echo "$input_url" | tr '[:upper:]' '[:lower:]')
    
    # Corrige protocolos mal digitados
    input_url=$(echo "$input_url" | sed \
        -e 's/^htp:\/\//https:\/\//' \
        -e 's/^htt:\/\//https:\/\//' \
        -e 's/^htps:\/\//https:\/\//')
    
    # Extrai parte do domínio
    local domain_part="$input_url"
    if [[ "$input_url" =~ ^[a-zA-Z]+:/* ]]; then
        domain_part=$(echo "$input_url" | sed -E 's#^[a-zA-Z]+:/*##')
    fi
    
    # Remove barras extras
    domain_part=$(echo "$domain_part" | sed 's#^/*##' | sed 's#/*$##')
    
    # Preserva caminho
    local path=""
    if [[ "$domain_part" =~ ^([^/]+)(/.*)?$ ]]; then
        domain_part="${BASH_REMATCH[1]}"
        path="${BASH_REMATCH[2]}"
    fi
    
    # Verifica se é IP ou domínio
    if [[ ! "$input_url" =~ ^https?:// ]]; then
        if [[ "$domain_part" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]]; then
            final_url="http://$domain_part"
        else
            final_url="https://$domain_part"
        fi
    else
        final_url="$input_url"
    fi
    
    # Adiciona caminho
    if [[ -n "$path" ]]; then
        path=$(echo "$path" | sed 's#//*#/#g')
        final_url="${final_url}${path}"
    fi
    
    echo "$final_url"
}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Instalação do Sistema Kiosk - PWA     ${NC}"
echo -e "${GREEN}  Linux Mint 22 Cinnamon                ${NC}"
echo -e "${GREEN}========================================${NC}"

# ============================================
#               CONFIGURAÇÕES
# ============================================

USERNAME=$(logname)
USER_HOME="/home/$USERNAME"
INSTALL_DIR="$USER_HOME/kiosk"
LOG_FILE="/var/log/kiosk_monitor.log"
CHROMIUM_USER_DATA="$USER_HOME/.config/chromium-kiosk"
SCREENSHOT_DIR="/var/log/kiosk_screenshots"

# Coletar URL com validação
while true; do
    echo -e "${YELLOW}Por favor, digite a URL do Mural:${NC}"
    echo -e "${YELLOW}Exemplos:${NC}"
    echo -e "  • https://mural.exemplo.com.br"
    echo -e "  • 192.168.1.100:8080"
    read -p "URL: " RAW_URL
    
    KIOSK_URL=$(validate_url "$RAW_URL")
    
    if [[ -z "$KIOSK_URL" ]]; then
        echo -e "${RED}ERRO: URL não pode estar vazia. Tente novamente.${NC}"
        continue
    fi
    
    echo -e "${GREEN}✓ URL processada: $KIOSK_URL${NC}"
    
    echo -e "${YELLOW}Testando conexão...${NC}"
    if curl --output /dev/null --silent --head --fail --max-time 5 "$KIOSK_URL"; then
        echo -e "${GREEN}✓ URL acessível!${NC}"
    else
        echo -e "${YELLOW}⚠ ATENÇÃO: URL parece inacessível no momento${NC}"
    fi
    
    echo -e "${YELLOW}Confirmar URL? (s/N):${NC}"
    read -p "> " CONFIRM
    
    if [[ "$CONFIRM" =~ ^[Ss]$ ]]; then
        break
    fi
done

# Configuração VNC (opcional)
echo -e "${YELLOW}Deseja configurar acesso VNC? (s/N):${NC}"
read -p "> " CONFIG_VNC
CONFIG_VNC=${CONFIG_VNC:-N}

if [[ "$CONFIG_VNC" =~ ^[Ss]$ ]]; then
    echo -e "${YELLOW}Digite a senha para acesso VNC:${NC}"
    read -s -p "> " VNC_PASSWORD
    echo
fi

# ============================================
#          PASSO 1: SSH (ACESSO REMOTO)
# ============================================

echo -e "${GREEN}[1/8] Instalando e configurando SSH...${NC}"
sudo apt-get update
sudo apt-get install -y openssh-server

sudo systemctl enable ssh
sudo systemctl start ssh

sudo ufw allow 22/tcp
sudo ufw --force enable

IP_ADDR=$(hostname -I | awk '{print $1}')
echo -e "${GREEN}✓ SSH configurado: ssh $USERNAME@$IP_ADDR${NC}"
sleep 2

# ============================================
#          INSTALAÇÃO DE DEPENDÊNCIAS
# ============================================

echo -e "${GREEN}[2/8] Instalando dependências do sistema...${NC}"
sudo apt-get install -y \
    unclutter \
    xdotool \
    curl \
    wget \
    x11-utils \
    xprintidle \
    imagemagick \
    gnome-screenshot \
    bc \
    net-tools \
    flatpak \
    mesa-utils \
    dbus-x11 \
    lightdm \
    lightdm-settings \
    x11-xserver-utils

# Adicionar Flathub
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# ============================================
#          CONFIGURAÇÃO DE LOGIN AUTOMÁTICO
# ============================================

echo -e "${GREEN}[3/8] Configurando login automático...${NC}"

# Criar diretório de configuração do LightDM se não existir
sudo mkdir -p /etc/lightdm/lightdm.conf.d

# Configurar LightDM para login automático
sudo tee /etc/lightdm/lightdm.conf.d/50-kiosk.conf > /dev/null << EOF
[Seat:*]
autologin-user=$USERNAME
autologin-user-timeout=0
user-session=cinnamon
EOF

# Garantir permissões corretas
sudo chmod 644 /etc/lightdm/lightdm.conf.d/50-kiosk.conf

echo -e "${GREEN}✓ Login automático configurado para usuário $USERNAME${NC}"

# ============================================
#          DESABILITAR SUSPENSÃO (SISTEMA)
# ============================================

echo -e "${GREEN}[4/8] Desabilitando suspensão do sistema...${NC}"

# Criar diretório para configurações do systemd
sudo mkdir -p /etc/systemd/logind.conf.d

# Configurações do sistema para energia
sudo tee /etc/systemd/logind.conf.d/50-kiosk.conf > /dev/null << EOF
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF

# Desabilitar suspensão automática
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo -e "${GREEN}✓ Suspensão do sistema desabilitada${NC}"

# ============================================
#          SCRIPT DE CONFIGURAÇÃO PÓS-REBOOT
# ============================================

echo -e "${GREEN}[5/8] Criando script de configuração pós-reboot...${NC}"

mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/pos_reboot.sh" << 'EOF'
#!/bin/bash

# Script executado após o primeiro reboot
# Configura todas as preferências do usuário que dependem do ambiente gráfico

LOG_FILE="/home/$(whoami)/kiosk/pos_reboot.log"
USERNAME="$(whoami)"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "$(date) - Iniciando configurações pós-reboot"

# Aguardar o ambiente gráfico ficar pronto
sleep 15

# Configurar ambiente
export DISPLAY=:0
export XAUTHORITY="/home/$USERNAME/.Xauthority"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

echo "$(date) - DISPLAY=$DISPLAY"
echo "$(date) - XAUTHORITY=$XAUTHORITY"

# Verificar se o X11 está acessível
if ! xdpyinfo &>/dev/null; then
    echo "$(date) - ERRO: X11 não acessível"
    exit 1
fi

echo "$(date) - X11 acessível, aplicando configurações..."

# ============================================
#          CONFIGURAÇÕES DO USUÁRIO
# ============================================

# Desabilitar protetor de tela e bloqueio
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null
gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null
gsettings set org.gnome.desktop.screensaver lock-delay 0 2>/dev/null
gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null
gsettings set org.cinnamon.desktop.lockdown disable-lock-screen true 2>/dev/null
gsettings set org.cinnamon.desktop.screensaver lock-enabled false 2>/dev/null

# Desabilitar suspensão
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false 2>/dev/null

# Desabilitar animações
gsettings set org.gnome.desktop.interface enable-animations false 2>/dev/null

# Desabilitar notificações
gsettings set org.gnome.desktop.notifications show-banners false 2>/dev/null

echo "$(date) - Configurações do usuário aplicadas com sucesso"

# Criar arquivo de flag para indicar que já foi executado
touch "/home/$USERNAME/.kiosk_configured"

# Remover este script do autostart após execução
rm -f "/home/$USERNAME/.config/autostart/kiosk-pos-reboot.desktop"

echo "$(date) - Script concluído, removido do autostart"
exit 0
EOF

chmod +x "$INSTALL_DIR/pos_reboot.sh"
chown $USERNAME:$USERNAME "$INSTALL_DIR/pos_reboot.sh"

# ============================================
#          CRIAR ENTRADA DE AUTOSTART
# ============================================

echo -e "${GREEN}[6/8] Criando entrada de autostart para configuração pós-reboot...${NC}"

mkdir -p "$USER_HOME/.config/autostart"

cat > "$USER_HOME/.config/autostart/kiosk-pos-reboot.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Kiosk Pós-Reboot
Exec=$INSTALL_DIR/pos_reboot.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Phase=Applications
EOF

chown $USERNAME:$USERNAME "$USER_HOME/.config/autostart/kiosk-pos-reboot.desktop"
chmod +x "$USER_HOME/.config/autostart/kiosk-pos-reboot.desktop"

echo -e "${GREEN}✓ Configurações pós-reboot agendadas${NC}"

# ============================================
#          SERVIÇO DE CONFIGURAÇÃO DE DISPLAY (PERSISTENTE)
# ============================================

echo -e "${GREEN}[7/8] Criando serviço persistente para configuração de displays...${NC}"

sudo tee /etc/systemd/system/display-config.service > /dev/null << EOF
[Unit]
Description=Configuração persistente de monitores para Kiosk
After=graphical.target
Requires=graphical.target
Before=kiosk.service

[Service]
Type=oneshot
User=$USERNAME
Group=$USERNAME
Environment=DISPLAY=:0
Environment=XAUTHORITY=$USER_HOME/.Xauthority
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u $USERNAME)
ExecStart=/bin/bash $INSTALL_DIR/configure_display.sh
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF

# Criar script de configuração de displays (versão persistente)
cat > "$INSTALL_DIR/configure_display.sh" << 'EOF'
#!/bin/bash

# Script de configuração persistente de monitores
# Executado em todo boot para garantir duplicação HDMI

LOG_FILE="/var/log/kiosk_display.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "$(date) - Iniciando configuração persistente de displays"

# Aguardar sistema estabilizar e detectar monitores
sleep 10

export DISPLAY=:0
export XAUTHORITY="/home/$(whoami)/.Xauthority"

# Verificar se xrandr está acessível
if ! command -v xrandr &> /dev/null; then
    echo "ERRO: xrandr não encontrado"
    exit 1
fi

echo "Monitores disponíveis:"
xrandr --current | grep " connected"

# Verificar se há TV HDMI conectada
if xrandr | grep -q "HDMI.* connected"; then
    HDMI_MONITOR=$(xrandr | grep "HDMI.* connected" | awk '{print $1}')
    PRIMARY_MONITOR=$(xrandr | grep " connected" | grep -v "HDMI" | head -1 | awk '{print $1}')
    
    echo "TV HDMI detectada: $HDMI_MONITOR"
    echo "Monitor primário: $PRIMARY_MONITOR"
    
    # Obter resolução do monitor primário
    PRIMARY_RES=$(xrandr | grep -A1 "^$PRIMARY_MONITOR connected" | tail -1 | awk '{print $1}')
    
    echo "Configurando duplicação: $PRIMARY_MONITOR ($PRIMARY_RES) -> $HDMI_MONITOR"
    
    # Tentar configurar duplicação
    if xrandr --output "$HDMI_MONITOR" --mode "$PRIMARY_RES" --same-as "$PRIMARY_MONITOR" 2>/dev/null; then
        echo "✅ Duplicação configurada com sucesso"
    else
        echo "⚠️ Resolução não suportada, tentando modo automático..."
        xrandr --output "$HDMI_MONITOR" --auto --same-as "$PRIMARY_MONITOR"
    fi
    
    echo "Configuração final:"
    xrandr --current | grep " connected"
    
    # Salvar configuração para referência
    xrandr --current > "$HOME/.kiosk_last_display_config"
else
    echo "Nenhum monitor HDMI detectado"
fi

echo "$(date) - Configuração de displays concluída"
exit 0
EOF

chmod +x "$INSTALL_DIR/configure_display.sh"
chown $USERNAME:$USERNAME "$INSTALL_DIR/configure_display.sh"

# Habilitar o serviço para iniciar no boot
sudo systemctl enable display-config.service
echo -e "${GREEN}✓ Serviço de configuração de displays criado e habilitado${NC}"

# ============================================
#          SCRIPT DE RECONFIGURAÇÃO MANUAL
# ============================================

echo -e "${GREEN}[8/8] Criando script para reconfigurar displays manualmente...${NC}"

cat > "$INSTALL_DIR/reconfigurar_display.sh" << 'EOF'
#!/bin/bash

# Script para reconfigurar displays manualmente
# Útil quando conectar uma TV após o sistema já estar rodando

echo "Reconfigurando displays..."
/home/$(whoami)/kiosk/configure_display.sh
echo "Pronto! Verifique se a TV está espelhada."
EOF

chmod +x "$INSTALL_DIR/reconfigurar_display.sh"
chown $USERNAME:$USERNAME "$INSTALL_DIR/reconfigurar_display.sh"

# Adicionar atalho no desktop para facilitar
mkdir -p "$USER_HOME/Desktop"
cat > "$USER_HOME/Desktop/reconfigurar_tv.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Reconfigurar TV
Comment=Aplica duplicação de tela na TV HDMI
Exec=$INSTALL_DIR/reconfigurar_display.sh
Icon=video-display
Terminal=true
Categories=System;
EOF

chown $USERNAME:$USERNAME "$USER_HOME/Desktop/reconfigurar_tv.desktop"
chmod +x "$USER_HOME/Desktop/reconfigurar_tv.desktop"

echo -e "${GREEN}✓ Scripts de reconfiguração manual criados${NC}"

# ============================================
#          SCRIPT DE EXECUÇÃO DO CHROMIUM
# ============================================

echo -e "${GREEN}[+] Criando script de execução do Chromium...${NC}"
mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/run_chromium.sh" << 'EOF'
#!/bin/bash

# Script FINAL para Chromium no Kiosk
# Com ambiente X11 explicitamente configurado

# Configurações fixas
USERNAME="$(whoami)"
LOG_FILE="/var/log/kiosk_monitor.log"
CHROMIUM_USER_DATA="/home/$USERNAME/.config/chromium-kiosk"
KIOSK_URL="$1"

# Função de log
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [Chromium] $1" >> "$LOG_FILE"
}

log "=== INICIANDO CHROMIUM (FINAL) ==="
log "URL: $KIOSK_URL"

# FORÇAR variáveis de ambiente corretas
export DISPLAY=:0
export XAUTHORITY="/home/$USERNAME/.Xauthority"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

log "DISPLAY=$DISPLAY"
log "XAUTHORITY=$XAUTHORITY"
log "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"

# Verificar se o display está acessível
if ! xdpyinfo &>/dev/null; then
    log "ERRO: Display $DISPLAY não acessível"
    log "Tentando alternativas..."
    
    # Tentar outros displays
    for disp in :0 :1 :2; do
        if DISPLAY=$disp xdpyinfo &>/dev/null; then
            export DISPLAY=$disp
            log "Display alternativo encontrado: $disp"
            break
        fi
    done
fi

# Verificar novamente
if ! xdpyinfo &>/dev/null; then
    log "ERRO CRÍTICO: Nenhum display X11 encontrado"
    exit 1
fi

log "Display $DISPLAY acessível - $(xdpyinfo | grep dimensions | awk '{print $2}')"

# Criar diretório de perfil
mkdir -p "$CHROMIUM_USER_DATA/Default"
chown -R "$USERNAME:$USERNAME" "$CHROMIUM_USER_DATA"

# Limpar preferências corrompidas
if [ -f "$CHROMIUM_USER_DATA/Default/Preferences" ]; then
    sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$CHROMIUM_USER_DATA/Default/Preferences"
    sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$CHROMIUM_USER_DATA/Default/Preferences"
fi

# Pré-configurar preferências para evitar login
cat > "$CHROMIUM_USER_DATA/Default/Preferences" << PREF
{
   "browser": {"check_default_browser": false},
   "profile": {"content_settings": {"exceptions": {}}},
   "sync": {"suppress_start": true},
   "credentials_enable_service": false,
   "profile.password_manager_enabled": false
}
PREF

log "Executando Chromium..."

# Executar Chromium com todas as variáveis
flatpak run org.chromium.Chromium \
    --user-data-dir="$CHROMIUM_USER_DATA" \
    --kiosk \
    --password-store=basic \
    --no-first-run \
    --no-default-browser-check \
    --disable-sync \
    --disable-signin \
    --disable-signin-promo \
    --disable-password-generation \
    --disable-password-leak-detection \
    --disable-component-update \
    --disable-background-networking \
    --noerrdialogs \
    --disable-infobars \
    --autoplay-policy=no-user-gesture-required \
    --disable-gpu \
    --disable-accelerated-2d-canvas \
    --disable-dev-shm-usage \
    --no-sandbox \
    --disable-setuid-sandbox \
    --use-gl=swiftshader \
    --app="$KIOSK_URL" >> "$LOG_FILE" 2>&1 &

PID=$!
log "Chromium iniciado com PID: $PID"

# Monitoramento avançado
sleep 5
if kill -0 $PID 2>/dev/null; then
    log "Chromium estável após 5 segundos"
    
    # Verificar janelas
    sleep 2
    WINDOW_COUNT=$(DISPLAY=:0 xdotool search --onlyvisible --class "chromium" 2>/dev/null | wc -l)
    log "Janelas Chromium visíveis: $WINDOW_COUNT"
    
    exit 0
else
    log "ERRO: Chromium morreu rapidamente"
    
    # Diagnóstico
    log "Processos: $(ps aux | grep -i chromium | grep -v grep | wc -l)"
    log "Memória livre: $(free -h | grep Mem | awk '{print $4}')"
    
    exit 1
fi
EOF

chmod +x "$INSTALL_DIR/run_chromium.sh"
chown $USERNAME:$USERNAME "$INSTALL_DIR/run_chromium.sh"

# ============================================
#          SCRIPT DO KIOSK (MONITOR)
# ============================================

echo -e "${GREEN}[+] Criando script do monitor...${NC}"

cat > "$INSTALL_DIR/kiosk.sh" << 'EOF'
#!/bin/bash

# Script do Kiosk - Monitor Inteligente
LOG_FILE="/var/log/kiosk_monitor.log"
SCREENSHOT_DIR="/var/log/kiosk_screenshots"
KIOSK_URL="$1"

CHECK_INTERVAL=30
IDLE_THRESHOLD=120
CRASH_THRESHOLD=3
OFFLINE_CHECK_INTERVAL=60
MAX_SCREENSHOTS=10

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$SCREENSHOT_DIR"

cleanup_screenshots() {
    cd "$SCREENSHOT_DIR" 2>/dev/null || return
    ls -t *.png 2>/dev/null | tail -n +$((MAX_SCREENSHOTS + 1)) | xargs -r rm
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

capture_diagnostic_screenshot() {
    local reason="$1"
    local filename="$SCREENSHOT_DIR/diagnostic_$(date +%Y%m%d_%H%M%S)_${reason}.png"
    
    export DISPLAY=:0
    if gnome-screenshot -w -f "$filename" 2>/dev/null; then
        log "Screenshot salvo: $filename"
        cleanup_screenshots
    fi
}

check_chromium_health() {
    local pid
    
    pid=$(pgrep -f "flatpak run.*chromium" | head -1)
    if [[ -z "$pid" ]]; then
        log "ERRO: Chromium não encontrado"
        return 1
    fi
    
    if ! kill -0 "$pid" 2>/dev/null; then
        log "ERRO: Chromium não responde"
        return 1
    fi
    
    export DISPLAY=:0
    local window_count
    window_count=$(xdotool search --onlyvisible --class "chromium" 2>/dev/null | wc -l)
    if [[ "$window_count" -eq 0 ]]; then
        log "ERRO: Nenhuma janela visível"
        return 1
    fi
    
    return 0
}

restart_chromium() {
    log "REINICIANDO Chromium..."
    
    capture_diagnostic_screenshot "pre_restart"
    
    pkill -f chromium
    pkill -f "flatpak run.*chromium"
    sleep 3
    
    log "Executando script externo..."
    /home/$(whoami)/kiosk/run_chromium.sh "$KIOSK_URL" &
    
    CHROMIUM_PID=$!
    log "Chromium reiniciado (PID: $CHROMIUM_PID)"
    
    sleep 5
    if kill -0 $CHROMIUM_PID 2>/dev/null; then
        log "Chromium estável"
    else
        log "ERRO: Chromium morreu"
    fi
}

soft_refresh() {
    local reason="$1"
    
    log "Refresh suave (motivo: $reason)"
    export DISPLAY=:0
    
    capture_diagnostic_screenshot "pre_refresh_${reason}"
    
    if xdotool search --onlyvisible --class "chromium" windowactivate --sync key F5 2>/dev/null; then
        log "F5 executado"
        return 0
    fi
    
    return 1
}

# ============================================
#          INICIALIZAÇÃO
# ============================================

log "=== INICIANDO SISTEMA KIOSK ==="
log "URL: $KIOSK_URL"

export DISPLAY=:0
xset s off
xset -dpms
unclutter -idle 0.5 -root &

restart_chromium

# ============================================
#          LOOP PRINCIPAL
# ============================================

consecutive_failures=0

while true; do
    if ! check_chromium_health; then
        ((consecutive_failures++))
        log "Falha #$consecutive_failures"
        
        if [[ $consecutive_failures -ge $CRASH_THRESHOLD ]]; then
            log "Reiniciando completamente"
            restart_chromium
            consecutive_failures=0
        else
            if ! soft_refresh "chromium_unhealthy"; then
                log "Refresh falhou"
            else
                consecutive_failures=0
            fi
        fi
    else
        consecutive_failures=0
    fi
    
    sleep $CHECK_INTERVAL
done
EOF

chmod +x "$INSTALL_DIR/kiosk.sh"
chown $USERNAME:$USERNAME "$INSTALL_DIR/kiosk.sh"

# ============================================
#          SCRIPT DE EMERGÊNCIA
# ============================================

echo -e "${GREEN}[+] Criando script de emergência...${NC}"

cat > "$INSTALL_DIR/emergency.sh" << 'EOF'
#!/bin/bash

echo "========================================="
echo "🆘 EMERGÊNCIA - RECUPERAÇÃO MANUAL"
echo "========================================="

case "$1" in
    restart)
        echo "Reiniciando Chromium..."
        pkill -f chromium
        sleep 2
        export DISPLAY=:0
        /home/$(whoami)/kiosk/run_chromium.sh "$KIOSK_URL"
        ;;
    refresh)
        echo "Forçando refresh F5..."
        export DISPLAY=:0
        xdotool search --onlyvisible --class "chromium" key F5
        ;;
    status)
        echo "Processos Chromium:"
        ps aux | grep -i chromium | grep -v grep
        echo ""
        echo "Janelas Chromium:"
        export DISPLAY=:0
        xdotool search --onlyvisible --class "chromium"
        ;;
    logs)
        tail -50 /var/log/kiosk_monitor.log
        ;;
    tv)
        echo "Reconfigurando TV HDMI..."
        /home/$(whoami)/kiosk/reconfigurar_display.sh
        ;;
    *)
        echo "Uso: $0 {restart|refresh|status|logs|tv}"
        ;;
esac
EOF

chmod +x "$INSTALL_DIR/emergency.sh"
chown $USERNAME:$USERNAME "$INSTALL_DIR/emergency.sh"

# ============================================
#          SCRIPT DE DIAGNÓSTICO
# ============================================

echo -e "${GREEN}[+] Criando script de diagnóstico...${NC}"

cat > "$INSTALL_DIR/diagnostico.sh" << 'EOF'
#!/bin/bash

echo "========================================="
echo "🔍 DIAGNÓSTICO DO SISTEMA"
echo "========================================="

# 1. Sistema
echo -e "\n1. SISTEMA:"
echo "   Usuário: $(whoami)"
echo "   Hostname: $(hostname)"
echo "   Data: $(date)"

# 2. X11
echo -e "\n2. X11:"
export DISPLAY=:0
if xdpyinfo &>/dev/null; then
    echo "   ✅ Display :0 acessível"
    echo "   Resolução: $(xdpyinfo | grep dimensions | awk '{print $2}')"
else
    echo "   ❌ Display :0 não acessível"
fi

ls -la /tmp/.X11-unix/ 2>/dev/null | sed 's/^/   /'

# 3. Monitores
echo -e "\n3. MONITORES:"
xrandr --current | grep " connected" | sed 's/^/   /'

# 4. Chromium
echo -e "\n4. CHROMIUM:"
if pgrep -f "flatpak run.*chromium" > /dev/null; then
    PID=$(pgrep -f "flatpak run.*chromium" | head -1)
    echo "   ✅ Rodando (PID: $PID)"
    ps -p $PID -o %cpu,%mem,etime | sed 's/^/   /'
    
    WINDOWS=$(DISPLAY=:0 xdotool search --onlyvisible --class "chromium" 2>/dev/null)
    echo "   Janelas visíveis: $(echo "$WINDOWS" | wc -l)"
else
    echo "   ❌ Chromium não está rodando"
fi

# 5. Flatpak
echo -e "\n5. FLATPAK:"
flatpak list | grep chromium | sed 's/^/   /' || echo "   Chromium não encontrado"

# 6. Configurações de energia
echo -e "\n6. ENERGIA:"
echo "   Suspensão: $(systemctl is-enabled sleep.target 2>/dev/null || echo 'desabilitado')"

# 7. Login automático
echo -e "\n7. LOGIN:"
if [ -f /etc/lightdm/lightdm.conf.d/50-kiosk.conf ]; then
    echo "   ✅ Login automático configurado"
else
    echo "   ❌ Login automático não configurado"
fi

# 8. Configurações pós-reboot
echo -e "\n8. PÓS-REBOOT:"
if [ -f "$HOME/.kiosk_configured" ]; then
    echo "   ✅ Configurações pós-reboot já aplicadas"
else
    echo "   ⚠️  Configurações pós-reboot pendentes"
fi

# 9. Serviço de display
echo -e "\n9. SERVIÇO DE DISPLAY:"
if systemctl is-enabled display-config.service &>/dev/null; then
    echo "   ✅ Serviço de display habilitado (persistente)"
    echo "   Última configuração: $(tail -1 /var/log/kiosk_display.log 2>/dev/null || echo 'n/a')"
else
    echo "   ❌ Serviço de display não configurado"
fi

# 10. Logs recentes
echo -e "\n10. ÚLTIMOS LOGS:"
tail -10 /var/log/kiosk_monitor.log 2>/dev/null | sed 's/^/   /' || echo "   Log não encontrado"

echo -e "\n========================================="
EOF

chmod +x "$INSTALL_DIR/diagnostico.sh"
chown $USERNAME:$USERNAME "$INSTALL_DIR/diagnostico.sh"

# ============================================
#          SERVIÇO SYSTEMD (KIOSK)
# ============================================

echo -e "${GREEN}[+] Criando serviço systemd para o kiosk...${NC}"

sudo tee /etc/systemd/system/kiosk.service > /dev/null << EOF
[Unit]
Description=Kiosk Mode - Monitor Inteligente
After=network.target graphical.target display-config.service
Requires=graphical.target
Wants=display-config.service

[Service]
Type=simple
User=$USERNAME
Group=$USERNAME
WorkingDirectory=$USER_HOME

# Ambiente completo e forçado
Environment=DISPLAY=:0
Environment=XAUTHORITY=$USER_HOME/.Xauthority
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u $USERNAME)
Environment=HOME=$USER_HOME
Environment=USER=$USERNAME
Environment=LOGNAME=$USERNAME

# Garantir que o X11 esteja pronto
ExecStartPre=/bin/sleep 5
ExecStartPre=/bin/bash -c 'while ! xdpyinfo -display :0 >/dev/null 2>&1; do sleep 1; done'

# Executar o monitor
ExecStart=/bin/bash $INSTALL_DIR/kiosk.sh "$KIOSK_URL"

# Políticas de restart
Restart=always
RestartSec=10

# Limites
LimitNOFILE=65536
LimitNPROC=65536

# Logs
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
EOF

# ============================================
#          CONFIGURAÇÃO VNC (OPCIONAL)
# ============================================

if [[ "$CONFIG_VNC" =~ ^[Ss]$ ]] && [[ -n "$VNC_PASSWORD" ]]; then
    echo -e "${GREEN}[+] Configurando VNC...${NC}"
    sudo apt-get install -y vino
    
    # Configurações serão aplicadas no pós-reboot
    mkdir -p "$INSTALL_DIR/vnc-config"
    
    ENCODED_PASSWORD=$(echo -n "$VNC_PASSWORD" | base64)
    
    cat > "$INSTALL_DIR/vnc-config/setup.sh" << EOF
#!/bin/bash
export DISPLAY=:0
export XAUTHORITY=/home/$USERNAME/.Xauthority
sleep 20
gsettings set org.gnome.Vino prompt-enabled false
gsettings set org.gnome.Vino require-encryption false
gsettings set org.gnome.Vino authentication-methods "['vnc']"
gsettings set org.gnome.Vino vnc-password "$ENCODED_PASSWORD"
gsettings set org.gnome.Vino notify-on-connect false
gsettings set org.gnome.Vino icon-visibility 'never'

# Iniciar VNC
/usr/lib/vino/vino-server &
EOF
    
    chmod +x "$INSTALL_DIR/vnc-config/setup.sh"
    chown $USERNAME:$USERNAME "$INSTALL_DIR/vnc-config/setup.sh"
    
    # Adicionar ao autostart
    cat > "$USER_HOME/.config/autostart/vino-config.desktop" << EOF
[Desktop Entry]
Type=Application
Name=VNC Config
Exec=$INSTALL_DIR/vnc-config/setup.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
    
    chown $USERNAME:$USERNAME "$USER_HOME/.config/autostart/vino-config.desktop"
    chmod +x "$USER_HOME/.config/autostart/vino-config.desktop"
    
    sudo ufw allow 5900/tcp
    
    echo -e "${GREEN}✓ VNC será configurado no primeiro login${NC}"
fi

# ============================================
#          INSTALAÇÃO DO CHROMIUM
# ============================================

echo -e "${GREEN}[+] Instalando Chromium via Flatpak...${NC}"
flatpak install -y flathub org.chromium.Chromium

# Conceder permissões
flatpak override --user --socket=x11 --share=network --device=dri org.chromium.Chromium

# Verificar instalação
CHROMIUM_VERSION=""
if flatpak list | grep -q org.chromium.Chromium; then
    CHROMIUM_VERSION=$(flatpak info org.chromium.Chromium | grep Version | awk '{print $2}')
    echo -e "${GREEN}✓ Chromium $CHROMIUM_VERSION instalado com sucesso${NC}"
    
    # Pré-criar diretório de perfil
    mkdir -p "$CHROMIUM_USER_DATA"
    chown -R $USERNAME:$USERNAME "$CHROMIUM_USER_DATA"
else
    echo -e "${RED}ERRO: Falha na instalação do Chromium${NC}"
fi

# ============================================
#          CORREÇÃO DE PERMISSÕES
# ============================================

echo -e "${GREEN}[+] Ajustando permissões de log...${NC}"

sudo touch /var/log/kiosk_monitor.log
sudo touch /var/log/kiosk_emergency.log
sudo touch /var/log/kiosk_display.log
sudo chown $USERNAME:$USERNAME /var/log/kiosk_monitor.log
sudo chown $USERNAME:$USERNAME /var/log/kiosk_emergency.log
sudo chown $USERNAME:$USERNAME /var/log/kiosk_display.log
sudo chmod 644 /var/log/kiosk_monitor.log
sudo chmod 644 /var/log/kiosk_emergency.log
sudo chmod 644 /var/log/kiosk_display.log

sudo mkdir -p /var/log/kiosk_screenshots
sudo chown -R $USERNAME:$USERNAME /var/log/kiosk_screenshots
sudo chmod 755 /var/log/kiosk_screenshots

# ============================================
#          INICIAR SERVIÇOS
# ============================================

echo -e "${GREEN}[+] Iniciando serviços...${NC}"
sudo systemctl daemon-reload
sudo systemctl enable kiosk.service

# ============================================
#          RELATÓRIO FINAL DETALHADO
# ============================================

clear
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         INSTALAÇÃO CONCLUÍDA - RELATÓRIO DO SISTEMA          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Informações do Sistema Operacional
echo -e "${BLUE}📌 SISTEMA OPERACIONAL${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Distribuição: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
echo -e "Kernel: $(uname -r)"
echo -e "Arquitetura: $(uname -m)"
echo -e "Hostname: $(hostname)"
echo -e "Usuário: $USERNAME"
echo ""

# Ambiente Gráfico
echo -e "${BLUE}🖥️  AMBIENTE GRÁFICO${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Display Manager: LightDM"
echo -e "Sessão: Cinnamon"
echo -e "Login Automático: ${GREEN}Configurado para $USERNAME${NC}"
echo ""

# Monitores
echo -e "${BLUE}🖥️  CONFIGURAÇÃO DE MONITORES${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Duplicação HDMI: ${GREEN}Persistente (ativa em todo boot)${NC}"
echo -e "Serviço: display-config.service"
echo -e "Log: /var/log/kiosk_display.log"
echo -e "Reconfigurar manual: ./reconfigurar_display.sh"
echo ""

# Chromium
echo -e "${BLUE}🌐 CHROMIUM${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Versão: $CHROMIUM_VERSION"
echo -e "Modo: Kiosk / PWA"
echo -e "URL: $KIOSK_URL"
echo -e "Perfil: $CHROMIUM_USER_DATA"
echo ""

# Configurações de Energia
echo -e "${BLUE}⚡ CONFIGURAÇÕES DE ENERGIA${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Bloqueio de tela: ${GREEN}Será desabilitado no primeiro login${NC}"
echo -e "Suspensão: ${GREEN}Desabilitada (sistema)${NC}"
echo -e "Hibernação: ${GREEN}Desabilitada${NC}"
echo ""

# Acesso Remoto
echo -e "${BLUE}🔌 ACESSO REMOTO${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "SSH: ${GREEN}✅ Ativo${NC} - ssh $USERNAME@$IP_ADDR"
if [[ "$CONFIG_VNC" =~ ^[Ss]$ ]]; then
    echo -e "VNC: ${YELLOW}⚠️  Será configurado no primeiro login${NC}"
else
    echo -e "VNC: ${YELLOW}⚠️  Não configurado${NC}"
fi
echo ""

# Logs e Diagnóstico
echo -e "${BLUE}📊 FERRAMENTAS DE DIAGNÓSTICO${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Scripts disponíveis em: $INSTALL_DIR"
echo -e "  • Diagnóstico: ./diagnostico.sh"
echo -e "  • Emergência: ./emergency.sh {restart|refresh|status|logs|tv}"
echo -e "  • Reconfigurar TV: ./reconfigurar_display.sh"
echo -e "  • Log principal: tail -f /var/log/kiosk_monitor.log"
echo -e "  • Log do display: tail -f /var/log/kiosk_display.log"
echo ""

# Próximos passos
echo -e "${YELLOW}📌 PRÓXIMOS PASSOS APÓS O REBOOT:${NC}"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "1. O sistema reiniciará automaticamente"
echo -e "2. O login automático será ativado"
echo -e "3. O serviço de display configurará a TV HDMI (se conectada)"
echo -e "4. Configurações de tela serão aplicadas"
echo -e "5. O Chromium iniciará em modo kiosk"
echo -e "6. O VNC será configurado (se selecionado)"
echo ""

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      O SISTEMA SERÁ REINICIADO EM 15 SEGUNDOS               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"

echo -e "${YELLOW}(pressione Ctrl+C para cancelar o reboot)${NC}"
sleep 15
sudo reboot
