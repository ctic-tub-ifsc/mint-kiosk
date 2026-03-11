#!/bin/bash

# Script de Configuração do Kiosk para Linux Mint
# Versão unificada com suporte a PWA e detecção inteligente de travamentos
# Otimizado para Linux Mint 22 Cinnamon
# CORREÇÕES: 
#   - SSH instalado primeiro
#   - VNC sem systemd user (só autostart)
#   - Chromium via Flatpak (evita dependência do snapd)
#   - Configurações Cinnamon corrigidas (sem erros de chave)
#   - Permissões de log ajustadas
#   - Chromium com opções extras de estabilidade e prevenção de login
#   - Script externo para execução controlada do Chromium
# Autor: Baseado em scripts validados para Raspberry Pi e Linux Mint

set -e  # Sai imediatamente se algum comando falhar

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
    
    # Converte para minúsculas (URLs são case-insensitive para domínio)
    input_url=$(echo "$input_url" | tr '[:upper:]' '[:lower:]')
    
    # Corrige protocolos mal digitados
    input_url=$(echo "$input_url" | sed \
        -e 's/^htp:\/\//https:\/\//' \
        -e 's/^htt:\/\//https:\/\//' \
        -e 's/^htps:\/\//https:\/\//' \
        -e 's/^http:\/\/https:\/\//https:\/\//' \
        -e 's/^https:\/\/http:\/\//https:\/\//')
    
    # Extrai parte do domínio (sem protocolo)
    local domain_part="$input_url"
    if [[ "$input_url" =~ ^[a-zA-Z]+:/* ]]; then
        domain_part=$(echo "$input_url" | sed -E 's#^[a-zA-Z]+:/*##')
    fi
    
    # Remove barras extras no início e fim
    domain_part=$(echo "$domain_part" | sed 's#^/*##' | sed 's#/*$##')
    
    # Se tiver caminho, preserva
    local path=""
    if [[ "$domain_part" =~ ^([^/]+)(/.*)?$ ]]; then
        domain_part="${BASH_REMATCH[1]}"
        path="${BASH_REMATCH[2]}"
    fi
    
    # Verifica se é IP ou domínio
    if [[ ! "$input_url" =~ ^https?:// ]]; then
        if [[ "$domain_part" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]]; then
            # É IP, usa http://
            final_url="http://$domain_part"
        else
            # É domínio, usa https://
            final_url="https://$domain_part"
        fi
    else
        final_url="$input_url"
    fi
    
    # Adiciona caminho se existir
    if [[ -n "$path" ]]; then
        # Remove barras duplicadas
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

INSTALL_DIR="/home/$(logname)/kiosk"
LOG_FILE="/var/log/kiosk_monitor.log"
CHROMIUM_USER_DATA="/home/$(logname)/.config/chromium-kiosk"
SCREENSHOT_DIR="/var/log/kiosk_screenshots"

# Coletar URL com validação
while true; do
    echo -e "${YELLOW}Por favor, digite a URL do Mural:${NC}"
    echo -e "${YELLOW}Exemplos:${NC}"
    echo -e "  • https://mural.exemplo.com.br"
    echo -e "  • 192.168.1.100:8080"
    echo -e "  • mural.intranet.local"
    read -p "URL: " RAW_URL
    
    # Valida e corrige a URL
    KIOSK_URL=$(validate_url "$RAW_URL")
    
    # Se validação falhou
    if [[ -z "$KIOSK_URL" ]]; then
        echo -e "${RED}ERRO: URL não pode estar vazia. Tente novamente.${NC}"
        continue
    fi
    
    # Mostra o resultado
    echo -e "${GREEN}✓ URL processada: $KIOSK_URL${NC}"
    
    # Teste rápido de conectividade
    echo -e "${YELLOW}Testando conexão...${NC}"
    if curl --output /dev/null --silent --head --fail --max-time 5 "$KIOSK_URL"; then
        echo -e "${GREEN}✓ URL acessível!${NC}"
    else
        echo -e "${YELLOW}⚠ ATENÇÃO: URL parece inacessível no momento${NC}"
        echo -e "${YELLOW}  O sistema continuará a instalação, mas o mural pode não carregar até que a rede esteja disponível.${NC}"
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
#          PASSO 1: SSH PRIMEIRO!
# ============================================

echo -e "${GREEN}[1/8] Instalando e configurando SSH para acesso remoto...${NC}"
sudo apt-get update
sudo apt-get install -y openssh-server

# Garantir que SSH está rodando
sudo systemctl enable ssh
sudo systemctl start ssh

# Configurar firewall para SSH
sudo ufw allow 22/tcp
sudo ufw --force enable

echo -e "${GREEN}✓ SSH configurado e rodando na porta 22${NC}"
echo -e "${YELLOW}  Agora você pode acessar remotamente via: ssh $(logname)@$(hostname -I | awk '{print $1}')${NC}"
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
    mesa-utils

# Adicionar repositório Flathub
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# ============================================
#          SCRIPT DE EXECUÇÃO DO CHROMIUM
# ============================================

echo -e "${GREEN}[3/8] Criando script de execução do Chromium...${NC}"
cat > "$INSTALL_DIR/run_chromium.sh" << 'EOF'
#!/bin/bash

# Script para iniciar Chromium com opções de estabilidade
# Este script será chamado pelo kiosk.sh
# CORREÇÃO: Execução sem sudo e com prevenção de login

LOG_FILE="/var/log/kiosk_monitor.log"
CHROMIUM_USER_DATA="/home/$(logname)/.config/chromium-kiosk"
KIOSK_URL="$1"

# Configurar ambiente (NUNCA usar sudo aqui!)
export DISPLAY=:0
export XAUTHORITY="$HOME/.Xauthority"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# Função de log local
log_chromium() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [Chromium] $1" >> "$LOG_FILE"
}

log_chromium "Iniciando Chromium via script externo"

# Verificar se o diretório de perfil existe e tem permissões corretas
if [ ! -d "$CHROMIUM_USER_DATA" ]; then
    mkdir -p "$CHROMIUM_USER_DATA"
    log_chromium "Diretório de perfil criado: $CHROMIUM_USER_DATA"
fi

# Pré-configurar preferências para evitar solicitações de login
mkdir -p "$CHROMIUM_USER_DATA/Default"
cat > "$CHROMIUM_USER_DATA/Default/Preferences" << 'PREF'
{
   "profile": {
      "content_settings": {
         "exceptions": {
            "password_provider": {}
         }
      },
      "password_manager_enabled": false,
      "prefs": {
         "credentials_enable_service": false
      }
   },
   "sync": {
      "suppress_start": true
   },
   "browser": {
      "check_default_browser": false
   },
   "download": {
      "prompt_for_download": false
   }
}
PREF

log_chromium "Preferências configuradas para evitar login"

# Opções para estabilidade máxima e prevenção de login
flatpak run org.chromium.Chromium \
    --user-data-dir="$CHROMIUM_USER_DATA" \
    --kiosk \
    --no-first-run \
    --no-default-browser-check \
    --disable-sync \
    --disable-signin \
    --disable-signin-promo \
    --disable-password-generation \
    --disable-password-leak-detection \
    --disable-single-click-autofill \
    --disable-autofill-keyboard-accessory-view \
    --disable-account-consistency \
    --disable-gaia-services \
    --disable-web-resources \
    --disable-client-side-phishing-detection \
    --disable-component-update \
    --disable-background-networking \
    --disable-default-apps \
    --disable-sync-preferences \
    --disable-bundled-integrations \
    --disable-background-timer-throttling \
    --disable-backgrounding-occluded-windows \
    --disable-renderer-backgrounding \
    --disable-back-forward-cache \
    --disable-breakpad \
    --disable-crash-reporter \
    --disable-crashpad \
    --disable-metrics \
    --disable-metrics-reporting \
    --disable-speech-api \
    --disable-translate \
    --disable-notifications \
    --disable-geolocation \
    --disable-webusb \
    --disable-session-crashed-bubble \
    --noerrdialogs \
    --disable-infobars \
    --disable-pinch \
    --overscroll-history-navigation=0 \
    --disable-features=TranslateUI,ChromeWhatsNewUI,InterestFeedContentSuggestions,MediaRemoting,PasswordImport,PasswordExport,PasswordEditing,PasswordCheck,PasswordManager,PasswordManagerOnboarding,PasswordLeakDetection,PasswordGeneration,PasswordSave,PasswordManualFallback,PasswordScriptsInjector,PasswordStrengthIndicator,PasswordImportExport \
    --autoplay-policy=no-user-gesture-required \
    --disable-gpu \
    --disable-gpu-compositing \
    --disable-accelerated-2d-canvas \
    --disable-accelerated-video-decode \
    --disable-accelerated-mjpeg-decode \
    --disable-webgl \
    --disable-software-rasterizer \
    --disable-dev-shm-usage \
    --no-sandbox \
    --disable-setuid-sandbox \
    --use-gl=swiftshader \
    --enable-features=OverlayScrollbar,OverlayScrollbarFlashAfterAnyScrollUpdate,OverlayScrollbarFlashWhenMouseEnter \
    --app="$KIOSK_URL" >> "$LOG_FILE" 2>&1 &

CHROMIUM_PID=$!
log_chromium "Chromium iniciado com PID: $CHROMIUM_PID"

# Aguardar um pouco e verificar
sleep 3
if kill -0 $CHROMIUM_PID 2>/dev/null; then
    log_chromium "Chromium está rodando estável"
    exit 0
else
    log_chromium "ERRO: Chromium morreu rapidamente"
    exit 1
fi
EOF

chmod +x "$INSTALL_DIR/run_chromium.sh"

# ============================================
#          SCRIPT PRINCIPAL DO KIOSK
# ============================================

echo -e "${GREEN}[4/8] Criando script do kiosk com monitor inteligente...${NC}"
mkdir -p "$INSTALL_DIR"
mkdir -p "$SCREENSHOT_DIR"
sudo chmod 755 "$SCREENSHOT_DIR"

cat > "$INSTALL_DIR/kiosk.sh" << 'EOF'
#!/bin/bash

# ============================================
#    SCRIPT DO KIOSK - MONITOR INTELIGENTE
#    SEM refresh cego - Apenas age quando necessário
#    VERSÃO COM CHROMIUM ESTABILIZADO
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

# Verificação de saúde do Chromium
check_chromium_health() {
    local pid
    local window_count
    local idle_time
    
    # Verificar processo - procurando por flatpak run chromium
    pid=$(pgrep -f "flatpak run.*chromium" | head -1)
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
    
    # Verificar se a janela está congelada
    if ! xdotool search --onlyvisible --class "chromium" windowfocus 2>/dev/null; then
        log "ERRO: Janela Chromium não aceita foco"
        return 1
    fi
    
    # Verificar idle time da aplicação
    idle_time=$(xprintidle 2>/dev/null || echo 0)
    if [[ "$idle_time" -gt "$((IDLE_THRESHOLD * 1000))" ]]; then
        log "AVISO: Janela inativa por $(($idle_time / 1000)) segundos"
    fi
    
    return 0
}

# Verificação de conectividade da URL
check_url_health() {
    local http_code
    local response_time
    
    http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 15 --connect-timeout 10 "$KIOSK_URL")
    
    if [[ "$http_code" == "200" ]]; then
        log "URL OK (HTTP $http_code)"
        return 0
    else
        log "ERRO: URL retornou HTTP $http_code"
        return 1
    fi
}

# Reinicialização completa do Chromium usando script externo
restart_chromium() {
    log "REINICIANDO Chromium completamente..."
    
    capture_diagnostic_screenshot "pre_restart"
    
    # Mata todos os processos relacionados ao Chromium
    pkill -f chromium
    pkill -f "flatpak run.*chromium"
    sleep 3
    
    log "Iniciando Chromium via script externo..."
    
    # Usar o script externo (NUNCA usar sudo aqui!)
    /home/$(logname)/kiosk/run_chromium.sh "$KIOSK_URL" &
    
    CHROMIUM_PID=$!
    log "Chromium reiniciado via script externo (PID: $CHROMIUM_PID)"
    
    # Aguardar e verificar
    sleep 5
    if kill -0 $CHROMIUM_PID 2>/dev/null; then
        log "Chromium permanece vivo após 5 segundos"
    else
        log "ERRO: Chromium morreu logo após iniciar"
    fi
}

# Refresh suave
soft_refresh() {
    local reason="$1"
    
    log "Executando refresh inteligente (motivo: $reason)..."
    export DISPLAY=:0
    
    capture_diagnostic_screenshot "pre_refresh_${reason}"
    
    if xdotool search --onlyvisible --class "chromium" windowactivate --sync key --clearmodifiers F5 2>/dev/null; then
        log "Refresh via F5 executado"
        return 0
    fi
    
    log "Falha ao executar refresh suave"
    return 1
}

# ============================================
#          INICIALIZAÇÃO
# ============================================

log "=== INICIANDO SISTEMA KIOSK ==="
log "URL: $KIOSK_URL"
log "Data: $(date)"

export DISPLAY=:0
xset s off
xset -dpms
unclutter -idle 0.5 -root &

restart_chromium

# ============================================
#          LOOP PRINCIPAL
# ============================================

consecutive_failures=0
was_offline=false
last_url_check=0

while true; do
    current_time=$(date +%s)
    
    if ! check_chromium_health; then
        ((consecutive_failures++))
        log "Falha de saúde #$consecutive_failures"
        
        if [[ $consecutive_failures -ge $CRASH_THRESHOLD ]]; then
            log "Múltiplas falhas consecutivas ($consecutive_failures). Reiniciando completamente."
            restart_chromium
            consecutive_failures=0
        else
            if soft_refresh "chromium_unhealthy"; then
                log "Refresh suave recuperou o Chromium"
                consecutive_failures=0
            else
                log "Refresh suave falhou. Aguardando próxima verificação."
            fi
        fi
    else
        if [[ $((current_time - last_url_check)) -ge $OFFLINE_CHECK_INTERVAL ]]; then
            if check_url_health; then
                if [[ "$was_offline" == true ]]; then
                    log "URL voltou ao normal."
                    soft_refresh "url_back_online"
                    was_offline=false
                fi
                consecutive_failures=0
            else
                was_offline=true
                log "URL offline - aguardando recuperação"
            fi
            last_url_check=$current_time
        fi
        
        consecutive_failures=0
    fi
    
    sleep $CHECK_INTERVAL
done
EOF

chmod +x "$INSTALL_DIR/kiosk.sh"

# ============================================
#          SCRIPT DE EMERGÊNCIA 
# ============================================

echo -e "${GREEN}[5/8] Criando script de emergência...${NC}"
cat > "$INSTALL_DIR/emergency_refresh.sh" << 'EOF'
#!/bin/bash
# Script de EMERGÊNCIA - executado manualmente

LOG_FILE="/var/log/kiosk_emergency.log"

log_emergency() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_emergency "Script de emergência iniciado"

if [[ "$1" == "--force" ]]; then
    log_emergency "Executando refresh forçado"
    
    export DISPLAY=:0
    export XAUTHORITY="$HOME/.Xauthority"
    
    /usr/bin/xdotool search --onlyvisible --class "chromium" | while read window; do
        log_emergency "Enviando F5 para janela: $window"
        /usr/bin/xdotool windowactivate --sync "$window" key --clearmodifiers F5
        sleep 0.5
    done
    
    log_emergency "Refresh de emergência concluído"
else
    echo "Uso: $0 --force"
    exit 1
fi
EOF

chmod +x "$INSTALL_DIR/emergency_refresh.sh"

# ============================================
#          SCRIPT DE DIAGNÓSTICO
# ============================================

echo -e "${GREEN}[6/8] Criando script de diagnóstico...${NC}"
cat > "$INSTALL_DIR/diagnostico.sh" << 'EOF'
#!/bin/bash

echo "========================================="
echo "🔍 DIAGNÓSTICO DO SISTEMA KIOSK"
echo "========================================="

# 1. Ambiente
echo -e "\n1. AMBIENTE:"
echo "   DISPLAY: $DISPLAY"
echo "   XAUTHORITY: $XAUTHORITY"
echo "   XDG_RUNTIME_DIR: $XDG_RUNTIME_DIR"

# 2. Serviço
echo -e "\n2. SERVIÇO:"
systemctl status kiosk.service --no-pager | grep "Active:" | sed 's/^/   /'

# 3. Chromium
echo -e "\n3. CHROMIUM:"
if pgrep -f "flatpak run.*chromium" > /dev/null; then
    PID=$(pgrep -f "flatpak run.*chromium" | head -1)
    echo "   ✅ Rodando (PID: $PID)"
    ps -p $PID -o %cpu,%mem,etime | sed 's/^/   /'
else
    echo "   ❌ Não está rodando"
fi

# 4. Flatpak
echo -e "\n4. FLATPAK:"
flatpak list | grep chromium || echo "   Chromium não encontrado"

# 5. Logs recentes
echo -e "\n5. ÚLTIMOS LOGS:"
tail -10 /var/log/kiosk_monitor.log 2>/dev/null | sed 's/^/   /' || echo "   Log não encontrado"

echo -e "\n========================================="
EOF

chmod +x "$INSTALL_DIR/diagnostico.sh"

# ============================================
#          SERVIÇO SYSTEMD
# ============================================

echo -e "${GREEN}[7/8] Criando serviço systemd...${NC}"
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
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u $(logname))
ExecStart=/bin/bash $INSTALL_DIR/kiosk.sh "$KIOSK_URL"
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
EOF

# ============================================
#          CONFIGURAÇÕES DO SISTEMA
# ============================================

echo -e "${GREEN}[8/8] Configurações de energia e tela...${NC}"
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
    echo -e "${GREEN}[+] Configurando VNC...${NC}"
    sudo apt-get install -y vino
    
    gsettings set org.gnome.Vino prompt-enabled false
    gsettings set org.gnome.Vino require-encryption false
    gsettings set org.gnome.Vino authentication-methods "['vnc']"
    gsettings set org.gnome.Vino vnc-password "$(echo -n "$VNC_PASSWORD" | base64)"
    gsettings set org.gnome.Vino notify-on-connect false
    gsettings set org.gnome.Vino icon-visibility 'never'
    
    sudo ufw allow 5900/tcp
    sudo ufw --force enable
    
    mkdir -p /home/$(logname)/.config/autostart
    cat > /home/$(logname)/.config/autostart/vino-server.desktop << EOF
[Desktop Entry]
Type=Application
Name=Vino VNC Server
Exec=/usr/lib/vino/vino-server
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-Cinnamon-Autostart-Phase=Applications
EOF
    
    chmod +x /home/$(logname)/.config/autostart/vino-server.desktop
    
    export DISPLAY=:0
    /usr/lib/vino/vino-server &
    echo -e "${GREEN}✓ VNC configurado na porta 5900${NC}"
fi

# ============================================
#          INSTALAÇÃO DO CHROMIUM
# ============================================

echo -e "${GREEN}[+] Instalando Chromium via Flatpak...${NC}"
flatpak install -y flathub org.chromium.Chromium

# Conceder permissões
flatpak override --user --socket=x11 --share=network --share=ipc --device=dri org.chromium.Chromium

# Verificar instalação
if flatpak list | grep -q org.chromium.Chromium; then
    echo -e "${GREEN}✓ Chromium instalado com sucesso${NC}"
    mkdir -p "$CHROMIUM_USER_DATA"
    chown -R $(logname):$(logname) "$CHROMIUM_USER_DATA"
else
    echo -e "${RED}ERRO: Falha na instalação do Chromium${NC}"
fi

# ============================================
#          CORREÇÃO DE PERMISSÕES
# ============================================

echo -e "${GREEN}[+] Ajustando permissões...${NC}"
sudo touch /var/log/kiosk_monitor.log
sudo touch /var/log/kiosk_emergency.log
sudo chown $(logname):$(logname) /var/log/kiosk_monitor.log
sudo chown $(logname):$(logname) /var/log/kiosk_emergency.log
sudo chmod 644 /var/log/kiosk_monitor.log
sudo chmod 644 /var/log/kiosk_emergency.log

sudo mkdir -p /var/log/kiosk_screenshots
sudo chown -R $(logname):$(logname) /var/log/kiosk_screenshots
sudo chmod 755 /var/log/kiosk_screenshots

# ============================================
#          INICIAR SERVIÇO
# ============================================

echo -e "${GREEN}[+] Iniciando serviço do kiosk...${NC}"
sudo systemctl daemon-reload
sudo systemctl enable kiosk.service
sudo systemctl start kiosk.service

# ============================================
#          FINALIZAÇÃO
# ============================================

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  INSTALAÇÃO COMPLETA!                  ${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "URL: $KIOSK_URL"
echo ""
echo -e "${YELLOW}ACESSO REMOTO:${NC}"
echo -e "  • SSH: ssh $(logname)@$(hostname -I | awk '{print $1}')"
echo ""

if [[ "$CONFIG_VNC" =~ ^[Ss]$ ]]; then
    echo -e "${YELLOW}VNC:${NC}"
    echo -e "  • Porta: 5900"
    echo -e "  • Status: $(pgrep -f vino-server > /dev/null && echo 'RODANDO' || echo 'AGUARDANDO REBOOT')"
    echo ""
fi

echo -e "${YELLOW}SCRIPTS:${NC}"
echo -e "  • Diagnóstico: $INSTALL_DIR/diagnostico.sh"
echo -e "  • Refresh manual: $INSTALL_DIR/emergency_refresh.sh --force"
echo ""

echo -e "${YELLOW}REINICIANDO EM 10 SEGUNDOS...${NC}"
sleep 10
sudo reboot
