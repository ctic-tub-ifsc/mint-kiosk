#!/bin/bash

# Script de Configuração do Kiosk para Linux Mint
# Versão unificada com suporte a PWA e detecção inteligente de travamentos
# Autor: Baseado em scripts validados para Raspberry Pi e Linux Mint

set -e  # Sai imediatamente se algum comando falhar

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Instalação do Sistema Kiosk - PWA     ${NC}"
echo -e "${GREEN}========================================${NC}"

# ============================================
#               CONFIGURAÇÕES
# ============================================

# Diretórios e arquivos
INSTALL_DIR="/home/$(logname)/kiosk"
LOG_FILE="/var/log/kiosk_monitor.log"
CHROMIUM_USER_DATA="/home/$(logname)/.config/chromium-kiosk"

# URLs e configurações
echo -e "${YELLOW}Por favor, digite a URL do PWA/Mural:${NC}"
read -p "URL: " KIOSK_URL

if [[ -z "$KIOSK_URL" ]]; then
    echo -e "${RED}ERRO: URL não fornecida. Abortando.${NC}"
    exit 1
fi

echo -e "${YELLOW}Deseja configurar acesso VNC? (s/N):${NC}"
read -p "> " CONFIG_VNC
CONFIG_VNC=${CONFIG_VNC:-N}

if [[ "$CONFIG_VNC" =~ ^[Ss]$ ]]; then
    echo -e "${YELLOW}Digite a senha para acesso VNC:${NC}"
    read -s -p "> " VNC_PASSWORD
    echo
    if [[ -z "$VNC_PASSWORD" ]]; then
        echo -e "${RED}ERRO: Senha VNC não fornecida. Continuando sem VNC.${NC}"
        CONFIG_VNC="N"
    fi
fi

# ============================================
#          INSTALAÇÃO DE DEPENDÊNCIAS
# ============================================

echo -e "${GREEN}[1/8] Instalando dependências do sistema...${NC}"
sudo apt-get update
sudo apt-get install -y \
    unclutter \
    xdotool \
    curl \
    wget \
    openssh-server \
    x11-utils \
    xprintidle \
    imagemagick \
    gnome-screenshot \
    ufw

# Instalação do Chromium mais recente
echo -e "${GREEN}[2/8] Instalando Chromium...${NC}"
if ! command -v chromium &> /dev/null; then
    # Tenta instalar via apt primeiro
    sudo apt-get install -y chromium-browser || {
        # Se falhar, baixa do repositório Mint
        wget -O /tmp/chromium.deb http://packages.linuxmint.com/pool/upstream/c/chromium/chromium_126.0.6478.126~linuxmint1+una_amd64.deb
        sudo dpkg -i /tmp/chromium.deb
        sudo apt-get install -f -y
        rm /tmp/chromium.deb
    }
fi

# ============================================
#          CONFIGURAÇÃO DO SISTEMA
# ============================================

echo -e "${GREEN}[3/8] Configurações de energia e tela...${NC}"
# Desabilitar proteção de tela e suspensão
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
gsettings set org.gnome.desktop.interface enable-animations false

# Desabilitar notificações
gsettings set org.gnome.desktop.notifications show-banners false
gsettings set org.gnome.desktop.notifications show-in-lock-screen false

# Remover mensagens de "sistema encerrado" etc
sudo sed -i 's/#WaylandEnable=false/WaylandEnable=false/' /etc/gdm3/custom.conf

# ============================================
#          SCRIPT PRINCIPAL DO KIOSK
# ============================================

echo -e "${GREEN}[4/8] Criando script do kiosk com detecção inteligente...${NC}"
mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/kiosk.sh" << 'EOF'
#!/bin/bash

# ============================================
#          SCRIPT PRINCIPAL DO KIOSK
#         Com detecção inteligente de falhas
# ============================================

# Configurações
LOG_FILE="/var/log/kiosk_monitor.log"
CHROMIUM_USER_DATA="/home/$(logname)/.config/chromium-kiosk"
KIOSK_URL="$1"
MAX_LOG_LINES=1000
SCREENSHOT_DIR="/tmp/kiosk_screenshots"
CHECK_INTERVAL=30
IDLE_THRESHOLD=60  # Segundos sem interação para considerar travado
CRASH_THRESHOLD=3   # Número de falhas antes de reiniciar completamente

# Criar diretórios necessários
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$SCREENSHOT_DIR"
mkdir -p "$CHROMIUM_USER_DATA"

# Função de log
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Função para verificar se o Chromium está respondendo
check_chromium_health() {
    local window_count
    local chrome_pid
    local screenshot_diff
    
    # Verificar se o processo existe
    chrome_pid=$(pgrep -f "chromium.*$KIOSK_URL" | head -1)
    if [[ -z "$chrome_pid" ]]; then
        log "ERRO: Processo Chromium não encontrado"
        return 1
    fi
    
    # Verificar se há janelas visíveis
    window_count=$(xdotool search --onlyvisible --class "chromium" 2>/dev/null | wc -l)
    if [[ "$window_count" -eq 0 ]]; then
        log "ERRO: Nenhuma janela Chromium visível"
        return 1
    fi
    
    # Verificar se a janela está respondendo (não congelada)
    local idle_time=$(xprintidle)
    if [[ "$idle_time" -gt "$((IDLE_THRESHOLD * 1000))" ]]; then
        log "AVISO: Janela parece inativa por $(($idle_time / 1000))s"
        # Tenta enviar um evento de foco para testar
        if ! xdotool search --onlyvisible --class "chromium" windowfocus 2>/dev/null; then
            log "ERRO: Não foi possível focar janela Chromium"
            return 1
        fi
    fi
    
    # Verificar se a página está branca (tira screenshot e verifica)
    local screenshot="$SCREENSHOT_DIR/check_$(date +%s).png"
    gnome-screenshot -w -f "$screenshot" 2>/dev/null
    
    # Se a imagem for muito homogênea (provável tela branca)
    if [[ -f "$screenshot" ]]; then
        local stddev=$(identify -format "%[standard-deviation]" "$screenshot" 2>/dev/null)
        if (( $(echo "$stddev < 0.1" | bc -l) )); then
            log "ERRO: Possível tela branca detectada (desvio padrão: $stddev)"
            rm -f "$screenshot"
            return 1
        fi
        rm -f "$screenshot"
    fi
    
    return 0
}

# Função para verificar conectividade da URL
check_url_health() {
    local http_code
    http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "$KIOSK_URL")
    
    if [[ "$http_code" == "200" ]]; then
        log "URL acessível (HTTP $http_code)"
        return 0
    else
        log "ERRO: URL inacessível (HTTP $http_code)"
        return 1
    fi
}

# Função para reiniciar o Chromium
restart_chromium() {
    log "Reiniciando Chromium..."
    
    # Mata todos os processos Chromium
    pkill -f chromium
    sleep 3
    
    # Limpa preferências corrompidas se necessário
    if [[ -f "$CHROMIUM_USER_DATA/Default/Preferences" ]]; then
        sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$CHROMIUM_USER_DATA/Default/Preferences"
        sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$CHROMIUM_USER_DATA/Default/Preferences"
    fi
    
    # Inicia novo Chromium
    export DISPLAY=:0
    chromium \
        --user-data-dir="$CHROMIUM_USER_DATA" \
        --kiosk \
        --incognito \
        --noerrdialogs \
        --disable-infobars \
        --disable-pinch \
        --overscroll-history-navigation=0 \
        --disable-features=TranslateUI \
        --disable-session-crashed-bubble \
        --disable-component-update \
        --disable-background-networking \
        --autoplay-policy=no-user-gesture-required \
        --enable-features=OverlayScrollbar,OverlayScrollbarFlashAfterAnyScrollUpdate,OverlayScrollbarFlashWhenMouseEnter \
        --app="$KIOSK_URL" &
    
    log "Chromium reiniciado"
    sleep 5
}

# Função para forçar atualização da página (F5 suave)
soft_refresh() {
    log "Executando refresh suave (F5)..."
    export DISPLAY=:0
    
    # Tenta enviar F5 para todas as janelas Chromium
    xdotool search --onlyvisible --class "chromium" windowactivate --sync key --clearmodifiers F5 2>/dev/null
    
    # Se falhar, tenta via JavaScript (mais confiável)
    xdotool search --onlyvisible --class "chromium" windowactivate --sync key --clearmodifiers "ctrl+r" 2>/dev/null
    
    log "Refresh executado"
}

# ============================================
#          LOOP PRINCIPAL DE MONITORAMENTO
# ============================================

log "=== INICIANDO SISTEMA KIOSK ==="
log "URL: $KIOSK_URL"
log "Intervalo de verificação: $CHECK_INTERVAL segundos"
log "Threshold de travamento: $IDLE_THRESHOLD segundos"

# Configurar ambiente
xset s off
xset -dpms
unclutter -idle 0.5 -root &

# Inicializar Chromium
restart_chromium

# Variáveis de controle
crash_count=0
was_offline=false
last_health_check=$(date +%s)

# Loop principal
while true; do
    current_time=$(date +%s)
    
    # Verificação periódica
    if [[ $((current_time - last_health_check)) -ge $CHECK_INTERVAL ]]; then
        log "Iniciando verificação de saúde..."
        
        # Verifica saúde do Chromium
        if ! check_chromium_health; then
            ((crash_count++))
            log "Falha na verificação de saúde (contador: $crash_count/$CRASH_THRESHOLD)"
            
            if [[ $crash_count -ge $CRASH_THRESHOLD ]]; then
                log "Múltiplas falhas detectadas. Reiniciando Chromium completamente."
                restart_chromium
                crash_count=0
            else
                log "Tentando refresh suave..."
                soft_refresh
                sleep 10
                
                # Se ainda falhar após refresh, conta como falha
                if ! check_chromium_health; then
                    log "Refresh não resolveu. Reiniciando Chromium."
                    restart_chromium
                else
                    log "Refresh resolveu o problema."
                    crash_count=0
                fi
            fi
        else
            # Se Chromium está saudável, verifica URL
            if check_url_health; then
                if [[ "$was_offline" == true ]]; then
                    log "URL voltou ao normal."
                    was_offline=false
                fi
                crash_count=0
            else
                was_offline=true
                log "URL offline. Forçando refresh..."
                soft_refresh
            fi
        fi
        
        last_health_check=$current_time
        
        # Limpa logs antigos
        if [[ -f "$LOG_FILE" ]] && [[ $(wc -l < "$LOG_FILE") -gt $MAX_LOG_LINES ]]; then
            tail -n $MAX_LOG_LINES "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
    
    sleep 5
done
EOF

chmod +x "$INSTALL_DIR/kiosk.sh"

# ============================================
#          SCRIPT DE ATUALIZAÇÃO CRON
# ============================================

echo -e "${GREEN}[5/8] Criando script de atualização periódica...${NC}"
cat > "$INSTALL_DIR/soft_refresh.sh" << 'EOF'
#!/bin/bash
# Script de refresh suave para execução via cron

export DISPLAY=:0
export XAUTHORITY=/home/$(logname)/.Xauthority

# Verifica se o Chromium está rodando
if pgrep -f "chromium.*kiosk" > /dev/null; then
    # Tenta refresh suave
    xdotool search --onlyvisible --class "chromium" windowactivate --sync key --clearmodifiers F5 2>/dev/null
    
    # Log para debug
    echo "$(date) - Refresh automático executado" >> /tmp/kiosk_refresh.log
fi
EOF

chmod +x "$INSTALL_DIR/soft_refresh.sh"

# ============================================
#          SERVIÇO SYSTEMD
# ============================================

echo -e "${GREEN}[6/8] Criando serviço systemd...${NC}"
sudo tee /etc/systemd/system/kiosk.service > /dev/null << EOF
[Unit]
Description=Kiosk Mode com Chromium
After=network.target graphical.target
Wants=network.target

[Service]
Type=simple
User=$(logname)
Group=$(logname)
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$(logname)/.Xauthority
ExecStart=/bin/bash $INSTALL_DIR/kiosk.sh "$KIOSK_URL"
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
EOF

# ============================================
#          CONFIGURAÇÃO VNC
# ============================================

if [[ "$CONFIG_VNC" =~ ^[Ss]$ ]]; then
    echo -e "${GREEN}[7/8] Configurando VNC...${NC}"
    
    # Instalar VNC
    sudo apt-get install -y vino
    
    # Configurar VNC
    gsettings set org.gnome.Vino prompt-enabled false
    gsettings set org.gnome.Vino require-encryption false
    gsettings set org.gnome.Vino authentication-methods "['vnc']"
    gsettings set org.gnome.Vino vnc-password "$(echo -n "$VNC_PASSWORD" | base64)"
    
    # Configurar firewall
    sudo ufw allow 5900/tcp
    sudo ufw --force enable
    
    # Iniciar VNC
    systemctl --user enable vino-server
    systemctl --user start vino-server
    
    echo -e "${GREEN}VNC configurado na porta 5900${NC}"
fi

# ============================================
#          CONFIGURAÇÃO CRON
# ============================================

echo -e "${GREEN}[8/8] Configurando cron para refresh periódico...${NC}"
# Adiciona ao crontab (executa a cada 3 minutos)
(crontab -u $(logname) -l 2>/dev/null | grep -v "soft_refresh.sh"; echo "*/3 * * * * /bin/bash $INSTALL_DIR/soft_refresh.sh >/dev/null 2>&1") | crontab -u $(logname) -

# ============================================
#          INICIAR SERVIÇOS
# ============================================

echo -e "${GREEN}Configuração concluída!${NC}"
echo -e "${YELLOW}Iniciando serviços...${NC}"

# Habilitar e iniciar serviço kiosk
sudo systemctl daemon-reload
sudo systemctl enable kiosk.service
sudo systemctl start kiosk.service

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  INSTALAÇÃO COMPLETA!                  ${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "URL configurada: $KIOSK_URL"
if [[ "$CONFIG_VNC" =~ ^[Ss]$ ]]; then
    echo -e "VNC ativo na porta 5900"
fi
echo -e "Logs: $LOG_FILE"
echo -e "Refresh automático a cada 3 minutos"
echo -e "${YELLOW}Reiniciando o sistema em 10 segundos...${NC}"
sleep 10
sudo reboot
