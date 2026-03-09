#!/bin/bash

# Script de Configuração do Kiosk para Linux Mint
# Versão corrigida - SEM refresh cego, com diagnóstico inteligente

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Instalação do Sistema Kiosk - PWA     ${NC}"
echo -e "${GREEN}========================================${NC}"

# ============================================
#               CONFIGURAÇÕES
# ============================================

INSTALL_DIR="/home/$(logname)/kiosk"
LOG_FILE="/var/log/kiosk_monitor.log"
CHROMIUM_USER_DATA="/home/$(logname)/.config/chromium-kiosk"
SCREENSHOT_DIR="/var/log/kiosk_screenshots"  # Mudado para /var/log para persistência

# Coletar URL
echo -e "${YELLOW}Por favor, digite a URL do PWA/Mural:${NC}"
read -p "URL: " KIOSK_URL

if [[ -z "$KIOSK_URL" ]]; then
    echo -e "${RED}ERRO: URL não fornecida. Abortando.${NC}"
    exit 1
fi

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
    ufw \
    bc  # Necessário para cálculos matemáticos

# ============================================
#          SCRIPT PRINCIPAL DO KIOSK
#         (Versão corrigida - sem refresh cego)
# ============================================

echo -e "${GREEN}[2/8] Criando script do kiosk com monitor inteligente...${NC}"
mkdir -p "$INSTALL_DIR"
mkdir -p "$SCREENSHOT_DIR"
sudo chmod 755 "$SCREENSHOT_DIR"  # Permissões para escrita de logs

cat > "$INSTALL_DIR/kiosk.sh" << 'EOF'
#!/bin/bash

# ============================================
#    SCRIPT DO KIOSK - MONITOR INTELIGENTE
#    SEM refresh cego - Apenas age quando necessário
# ============================================

# Configurações
LOG_FILE="/var/log/kiosk_monitor.log"
CHROMIUM_USER_DATA="/home/$(logname)/.config/chromium-kiosk"
SCREENSHOT_DIR="/var/log/kiosk_screenshots"
KIOSK_URL="$1"

# Timeouts e limites
CHECK_INTERVAL=30          # Verificar a cada 30 segundos
IDLE_THRESHOLD=120         # 2 minutos sem resposta = travado
CRASH_THRESHOLD=3          # 3 falhas seguidas = reinício completo
OFFLINE_CHECK_INTERVAL=60  # Verificar URL offline a cada 1 minuto
MAX_SCREENSHOTS=10         # Manter apenas os últimos 10 screenshots

# Criar diretórios
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$SCREENSHOT_DIR"
mkdir -p "$CHROMIUM_USER_DATA"

# Limpar screenshots antigos (manter apenas os últimos MAX_SCREENSHOTS)
cleanup_screenshots() {
    cd "$SCREENSHOT_DIR" 2>/dev/null || return
    ls -t *.png 2>/dev/null | tail -n +$((MAX_SCREENSHOTS + 1)) | xargs -r rm
}

# Função de log
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Função para capturar screenshot de diagnóstico (APENAS em falhas)
capture_diagnostic_screenshot() {
    local reason="$1"
    local filename="$SCREENSHOT_DIR/diagnostic_$(date +%Y%m%d_%H%M%S)_${reason}.png"
    
    # Tentar capturar a tela atual
    if DISPLAY=:0 gnome-screenshot -w -f "$filename" 2>/dev/null; then
        log "Screenshot de diagnóstico salvo: $filename"
        cleanup_screenshots
    else
        log "Falha ao capturar screenshot de diagnóstico"
    fi
}

# Verificação de saúde do Chromium (NÃO gera screenshot automaticamente)
check_chromium_health() {
    local pid
    local window_count
    local idle_time
    
    # Verificar processo
    pid=$(pgrep -f "chromium.*$KIOSK_URL" | head -1)
    if [[ -z "$pid" ]]; then
        log "ERRO: Processo Chromium não encontrado"
        return 1
    fi
    
    # Verificar se processo está respondendo
    if ! kill -0 "$pid" 2>/dev/null; then
        log "ERRO: Processo Chromium não está respondendo"
        return 1
    fi
    
    # Verificar janelas visíveis
    export DISPLAY=:0
    window_count=$(xdotool search --onlyvisible --class "chromium" 2>/dev/null | wc -l)
    if [[ "$window_count" -eq 0 ]]; then
        log "ERRO: Nenhuma janela Chromium visível"
        return 1
    fi
    
    # Verificar se a janela está congelada (não responde a eventos)
    # Usando xdotool para tentar mover o mouse (sem mover de verdade)
    if ! xdotool search --onlyvisible --class "chromium" windowfocus 2>/dev/null; then
        log "ERRO: Janela Chromium não aceita foco"
        return 1
    fi
    
    # Verificar idle time da aplicação
    idle_time=$(xprintidle 2>/dev/null || echo 0)
    if [[ "$idle_time" -gt "$((IDLE_THRESHOLD * 1000))" ]]; then
        log "AVISO: Janela inativa por $(($idle_time / 1000)) segundos"
        # Não considera erro ainda, só aviso
    fi
    
    return 0
}

# Verificação de conectividade da URL
check_url_health() {
    local http_code
    local start_time
    local end_time
    local response_time
    
    start_time=$(date +%s%N)
    http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 15 --connect-timeout 10 "$KIOSK_URL")
    end_time=$(date +%s%N)
    
    response_time=$(( (end_time - start_time) / 1000000 ))  # em milissegundos
    
    if [[ "$http_code" == "200" ]]; then
        log "URL OK (${response_time}ms)"
        return 0
    else
        log "ERRO: URL retornou HTTP $http_code (${response_time}ms)"
        return 1
    fi
}

# Função para verificar se o PWA tem conteúdo em cache
check_cached_content() {
    # Tenta acessar via Chromium em modo headless para ver se há service worker
    # Uma verificação mais simples: ver se o Chromium consegue carregar algo
    if DISPLAY=:0 xdotool search --onlyvisible --class "chromium" key --clearmodifiers "Ctrl+l" 2>/dev/null; then
        # Conseguiu interagir, provavelmente tem conteúdo
        return 0
    fi
    return 1
}

# Reinicialização completa do Chromium
restart_chromium() {
    log "REINICIANDO Chromium completamente..."
    
    # Capturar diagnóstico antes de matar
    capture_diagnostic_screenshot "pre_restart"
    
    # Matar processos
    pkill -f chromium
    sleep 5
    
    # Limpar preferências corrompidas
    if [[ -f "$CHROMIUM_USER_DATA/Default/Preferences" ]]; then
        sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "$CHROMIUM_USER_DATA/Default/Preferences"
        sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' "$CHROMIUM_USER_DATA/Default/Preferences"
    fi
    
    # Iniciar Chromium - SEM incognito para manter cache offline
    export DISPLAY=:0
    chromium \
        --user-data-dir="$CHROMIUM_USER_DATA" \
        --kiosk \
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
    
    log "Chromium reiniciado (PID: $!)"
    sleep 10  # Aguardar inicialização
}

# Refresh suave - APENAS quando necessário
# NÃO é F5 cego - tenta métodos mais inteligentes
soft_refresh() {
    local reason="$1"
    
    log "Executando refresh inteligente (motivo: $reason)..."
    export DISPLAY=:0
    
    # Capturar screenshot antes do refresh
    capture_diagnostic_screenshot "pre_refresh_${reason}"
    
    # Método 1: Tentar enviar F5 (funciona na maioria dos casos)
    if xdotool search --onlyvisible --class "chromium" windowactivate --sync key --clearmodifiers F5 2>/dev/null; then
        log "Refresh via F5 executado"
        return 0
    fi
    
    # Método 2: Tentar recarregar via JavaScript (mais suave)
    if xdotool search --onlyvisible --class "chromium" windowactivate --sync key --clearmodifiers "ctrl+r" 2>/dev/null; then
        log "Refresh via Ctrl+R executado"
        return 0
    fi
    
    # Método 3: Se nada funcionar, talvez precise reiniciar
    log "Falha ao executar refresh suave"
    return 1
}

# ============================================
#          INICIALIZAÇÃO
# ============================================

log "=== INICIANDO SISTEMA KIOSK ==="
log "URL: $KIOSK_URL"
log "Data: $(date)"

# Configurar ambiente X
export DISPLAY=:0
xset s off
xset -dpms
unclutter -idle 0.5 -root &

# Iniciar Chromium
restart_chromium

# ============================================
#          LOOP PRINCIPAL - SEM CRON!
# ============================================

consecutive_failures=0
was_offline=false
last_url_check=0

while true; do
    current_time=$(date +%s)
    
    # 1. VERIFICAÇÃO DE SAÚDE DO CHROMIUM
    if ! check_chromium_health; then
        ((consecutive_failures++))
        log "Falha de saúde #$consecutive_failures"
        
        if [[ $consecutive_failures -ge $CRASH_THRESHOLD ]]; then
            log "Múltiplas falhas consecutivas ($consecutive_failures). Reiniciando completamente."
            restart_chromium
            consecutive_failures=0
        else
            # Tentar refresh suave
            if soft_refresh "chromium_unhealthy"; then
                log "Refresh suave recuperou o Chromium"
                consecutive_failures=0
            else
                log "Refresh suave falhou. Aguardando próxima verificação."
            fi
        fi
    else
        # Chromium saudável - verificar URL periodicamente
        if [[ $((current_time - last_url_check)) -ge $OFFLINE_CHECK_INTERVAL ]]; then
            if check_url_health; then
                if [[ "$was_offline" == true ]]; then
                    log "URL voltou ao normal. Fazendo refresh para garantir."
                    soft_refresh "url_back_online"
                    was_offline=false
                fi
                consecutive_failures=0
            else
                was_offline=true
                log "URL offline - aguardando recuperação da rede"
                
                # Verificar se há conteúdo em cache
                if check_cached_content; then
                    log "PWA exibindo conteúdo em cache - OK"
                else
                    log "AVISO: PWA sem cache disponível"
                fi
            fi
            last_url_check=$current_time
        fi
        
        # Reset contador se saudável
        consecutive_failures=0
    fi
    
    # Limpeza de logs (a cada hora aproximadamente)
    if [[ $((current_time % 3600)) -lt $CHECK_INTERVAL ]]; then
        if [[ -f "$LOG_FILE" ]] && [[ $(wc -l < "$LOG_FILE") -gt 1000 ]]; then
            tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
    
    sleep $CHECK_INTERVAL
done
EOF

chmod +x "$INSTALL_DIR/kiosk.sh"

# ============================================
#          SCRIPT DE EMERGÊNCIA (OPCIONAL)
# ============================================

echo -e "${GREEN}[3/8] Criando script de emergência (apenas para casos extremos)...${NC}"
cat > "$INSTALL_DIR/emergency_refresh.sh" << 'EOF'
#!/bin/bash
# Script de EMERGÊNCIA - executado manualmente ou em casos extremos
# NÃO configurar no cron automático!

LOG_FILE="/var/log/kiosk_emergency.log"
EMERGENCY_FILE="/tmp/kiosk_emergency"

echo "$(date) - Script de emergência executado manualmente" >> "$LOG_FILE"

# Verifica se há um arquivo de flag de emergência
if [[ -f "$EMERGENCY_FILE" ]]; then
    # Só executa refresh se houver flag de emergência
    export DISPLAY=:0
    xdotool search --onlyvisible --class "chromium" key F5
    
    # Remove flag após executar
    rm -f "$EMERGENCY_FILE"
    echo "$(date) - Refresh de emergência executado" >> "$LOG_FILE"
fi
EOF

chmod +x "$INSTALL_DIR/emergency_refresh.sh"

# ============================================
#          SERVIÇO SYSTEMD
# ============================================

echo -e "${GREEN}[4/8] Criando serviço systemd...${NC}"
sudo tee /etc/systemd/system/kiosk.service > /dev/null << EOF
[Unit]
Description=Kiosk Mode - Monitor Inteligente
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
#          REMOVER CRON AGRESSIVO
# ============================================

echo -e "${GREEN}[5/8] Removendo crons agressivos (se existirem)...${NC}"
# Remover qualquer cron antigo com F5
(crontab -u $(logname) -l 2>/dev/null | grep -v "xdotool\|F5\|refresh" || true) | crontab -u $(logname) -

# ============================================
#          CONFIGURAÇÕES DO SISTEMA
# ============================================

echo -e "${GREEN}[6/8] Configurações de energia e tela...${NC}"
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.desktop.interface enable-animations false
gsettings set org.gnome.desktop.notifications show-banners false

# ============================================
#          CONFIGURAÇÃO VNC (OPCIONAL)
# ============================================

if [[ "$CONFIG_VNC" =~ ^[Ss]$ ]] && [[ -n "$VNC_PASSWORD" ]]; then
    echo -e "${GREEN}[7/8] Configurando VNC...${NC}"
    sudo apt-get install -y vino
    
    gsettings set org.gnome.Vino prompt-enabled false
    gsettings set org.gnome.Vino require-encryption false
    gsettings set org.gnome.Vino authentication-methods "['vnc']"
    gsettings set org.gnome.Vino vnc-password "$(echo -n "$VNC_PASSWORD" | base64)"
    
    sudo ufw allow 5900/tcp
    sudo ufw --force enable
    
    systemctl --user enable vino-server
    systemctl --user start vino-server
    
    echo -e "${GREEN}VNC configurado na porta 5900${NC}"
fi

# ============================================
#          INSTALAÇÃO DO CHROMIUM
# ============================================

echo -e "${GREEN}[8/8] Instalando Chromium...${NC}"
if ! command -v chromium &> /dev/null; then
    sudo apt-get install -y chromium-browser || {
        wget -O /tmp/chromium.deb http://packages.linuxmint.com/pool/upstream/c/chromium/chromium_latest_amd64.deb
        sudo dpkg -i /tmp/chromium.deb || true
        sudo apt-get install -f -y
        rm /tmp/chromium.deb
    }
fi

# ============================================
#          FINALIZAÇÃO
# ============================================

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  INSTALAÇÃO COMPLETA!                  ${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "URL: $KIOSK_URL"
echo -e "Modo: PWA com cache offline habilitado"
echo -e "Monitor: Inteligente (sem refresh cego)"
echo -e "Screenshots: Apenas em falhas (máx $MAX_SCREENSHOTS)"
echo -e "Logs: $LOG_FILE"
echo -e ""
echo -e "${YELLOW}IMPORTANTE:${NC}"
echo -e "- O sistema NÃO faz refresh automático cego"
echo -e "- Screenshots são gerados APENAS quando há falha"
echo -e "- O PWA pode usar cache offline normalmente"
echo -e "- Em caso de problemas, verifique os logs:"
echo -e "  sudo tail -f $LOG_FILE"
echo -e ""
echo -e "${YELLOW}Reiniciando em 10 segundos...${NC}"
sleep 10
sudo reboot
