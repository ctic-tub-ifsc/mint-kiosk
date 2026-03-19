# Mint Kiosk - Sistema de Quiosque Digital para Linux Mint

Este script transforma o Linux Mint em um quiosque digital inteligente, ideal para murais de avisos, painéis informativos e aplicações PWA. O sistema é auto-gerenciável, com detecção inteligente de falhas, recuperação automática e suporte otimizado para notebooks.

Testado no Linux Mint 22.3 Cinnamon.

---

## Instalação em Comando Único

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/ctic-tub-ifsc/mint-kiosk/refs/heads/main/install_kiosk.sh)"
```

Durante a instalação será solicitado:
- URL do site/mural a ser exibido
- Configuração de acesso VNC (opcional)

---

## Funcionalidades Principais

### 1. Exibição em Modo Quiosque
- Chromium em tela cheia (kiosk mode)
- Sem barras de ferramentas ou infobars
- Cursor do mouse oculto quando inativo
- Login automático configurado

### 2. Monitoramento Inteligente
- Verificação do processo Chromium a cada 30 segundos
- Detecção de janelas congeladas ou não responsivas
- Refresh suave (F5) automático ao primeiro sinal de problema
- Reinicialização completa após falhas consecutivas
- Screenshots de diagnóstico capturados silenciosamente (sem piscar a tela)

### 3. Configurações de Energia
- Bloqueio de tela desabilitado permanentemente
- Suspensão e hibernação desabilitadas
- Ação em bateria crítica configurada para desligamento limpo (em 2%)
- Fechamento da tampa ignorado (não suspende)

### 4. Suporte a Notebooks
- Desligamento limpo quando bateria atinge nível crítico
- Serviço de monitoramento de energia AC
- Script de diagnóstico de hardware (bateria, AC, wake-up)
- Instruções para configuração de "Power on AC Restore" na BIOS

### 5. Duplicação Automática para TV HDMI
- Detecta automaticamente quando uma TV é conectada via HDMI
- Configura duplicação de tela (mirror) com resolução adequada
- Serviço systemd dedicado executado em todo boot
- Script para reconfiguração manual quando necessário

### 6. Acesso Remoto
- SSH ativado automaticamente (porta 22)
- VNC opcional com configuração no primeiro login
- Firewall configurado para as portas necessárias

---

## Dependências Instaladas

O script instala automaticamente os seguintes pacotes:
- unclutter, xdotool (controle de mouse e teclado)
- curl, wget (transferência de dados)
- x11-utils, xprintidle, x11-xserver-utils, x11-apps (utilitários X11)
- imagemagick, gnome-screenshot, ffmpeg (captura de tela)
- flatpak, mesa-utils (gerenciamento de pacotes e gráficos)
- lightdm, lightdm-settings (gerenciador de login)
- upower, acpi (gerenciamento de energia)
- openssh-server, vino (acesso remoto)

---

## Comandos de Verificação

### Status do Serviço
```bash
sudo systemctl status kiosk.service
sudo journalctl -u kiosk.service -f
tail -f /var/log/kiosk_monitor.log
```

### Scripts Disponíveis (em /home/usuario/kiosk/)
```bash
# Diagnóstico geral do sistema
~/kiosk/diagnostico.sh

# Diagnóstico específico para hardware (bateria, AC)
~/kiosk/diagnostico_hardware.sh

# Emergência - recuperação manual
~/kiosk/emergency.sh restart   # reinicia o Chromium
~/kiosk/emergency.sh refresh   # envia F5
~/kiosk/emergency.sh status    # mostra processos e janelas
~/kiosk/emergency.sh logs      # exibe logs recentes
~/kiosk/emergency.sh tv        # reconfigura TV HDMI
~/kiosk/emergency.sh battery   # mostra status da bateria

# Reconfigurar TV HDMI manualmente
~/kiosk/reconfigurar_display.sh

# Desligamento limpo (usado em bateria crítica)
sudo ~/kiosk/graceful_shutdown.sh
```

---

## Configurações Automáticas

| Item | Configuração Aplicada |
|------|----------------------|
| Login | Automático, sem solicitação de senha |
| Bloqueio de tela | Desabilitado permanentemente |
| Suspensão | Desabilitada (AC e bateria) |
| Hibernação | Desabilitada |
| Fechar tampa | Ignorado (não suspende) |
| Bateria crítica | Desligamento limpo em 2% |
| Monitoramento AC | Serviço ativo (monitor-ac.service) |
| Duplicação HDMI | Serviço persistente (display-config.service) |
| Chromium | Instalado via Flatpak, sem keyring |
| Screenshots | Captura silenciosa (import/xwd/ffmpeg) |

---

## Estrutura de Arquivos

```
/var/log/
├── kiosk_monitor.log           # Log principal do monitor
├── kiosk_screenshots/          # Screenshots de diagnóstico
├── kiosk_display.log           # Log da configuração de displays
├── kiosk_graceful_shutdown.log # Log de desligamento por bateria
├── monitor_ac.log              # Log do monitor de energia AC
└── kiosk_ac_wake.log           # Log da configuração wake-on-AC

/home/usuario/kiosk/
├── kiosk.sh                     # Script principal do monitor
├── run_chromium.sh              # Executa o Chromium
├── pos_reboot.sh                 # Configurações pós-reboot
├── configure_display.sh          # Configura displays
├── reconfigurar_display.sh       # Reconfiguração manual
├── configure_ac_wake.sh          # Configura wake-on-AC
├── graceful_shutdown.sh          # Desligamento limpo
├── diagnostico.sh                # Diagnóstico geral
├── diagnostico_hardware.sh       # Diagnóstico de hardware
├── emergency.sh                  # Recuperação manual
└── vnc-config/                   # Configuração do VNC

/etc/systemd/system/
├── kiosk.service                 # Serviço do kiosk
├── display-config.service        # Configuração de displays
└── monitor-ac.service            # Monitor de energia AC

/etc/lightdm/lightdm.conf.d/50-kiosk.conf  # Login automático
/etc/systemd/logind.conf.d/50-kiosk.conf    # Configurações de energia
/etc/UPower/UPower.conf                     # Ação em bateria crítica
```

---

## Problemas Comuns e Soluções

### Chromium não inicia ou fecha sozinho
```bash
sudo systemctl restart kiosk.service
```

### Tela preta mas sistema parece ativo
```bash
~/kiosk/emergency.sh restart
```

### TV HDMI conectada mas não duplica
```bash
sudo systemctl restart display-config.service
# ou
~/kiosk/reconfigurar_display.sh
```

### Notebook não liga ao conectar o carregador
```bash
# Verificar instruções da BIOS
cat ~/Desktop/configurar_bios.txt
```

### Verificar status da bateria
```bash
~/kiosk/emergency.sh battery
# ou
~/kiosk/diagnostico_hardware.sh
```

---

## Relatório de Instalação

Ao final da instalação, o script exibe um relatório com:
- Versão do sistema operacional e kernel
- Configurações de login automático
- Status da duplicação HDMI
- Versão do Chromium e URL configurada
- Ações configuradas para bateria crítica
- Endereço IP para acesso SSH
- Lista de scripts disponíveis

---

## Documentação Adicional

Para informações detalhadas sobre solução de problemas, consulte:
[Guia de Resolução de Problemas](resolucao_de_problemas.md)

---

**CTIC - Campus Tubarão**  
Instituto Federal de Santa Catarina
```
