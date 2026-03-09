# O que este script faz e como ele funciona?

Este script transforma o Raspberry Pi em um quiosque digital. Ele exibe um site específico em tela cheia, funciona sozinho e consegue se recuperar de problemas de conexão.

> Testado no Linux Mint 22.3

- Prepara o sistema: Instala ferramentas essenciais (como as que escondem o mouse e simulam teclas) e configura o Chromium pra iniciar sempre em modo quiosque (tela cheia), sem barras ou avisos. Ele também desativa o protetor de tela do sistema.

- Pede o site: No início, ele te pergunta qual endereço da web (URL) você quer que o quiosque mostre.

- kiosk.service:

    - Cria um serviço que faz o navegador e o monitoramento começarem automaticamente toda vez que o PC liga.

    - Fica verificando a URL a cada minuto. Se o site sair do ar, ele reinicia o navegador a cada 1 minuto até o site voltar.

    - Assim que o site volta a funcionar, ele reinicia o navegador de novo pra ter certeza que a página está totalmente atualizada.

    - Reinicia pra ativar: Por último, ele reinicia pra que todas as configurações e o modo quiosque comecem a funcionar corretamente.

# Como ele funciona:

Você executa [este script](https://raw.githubusercontent.com/ctic-tub-ifsc/mint-kiosk/refs/heads/main/install_kiosk.sh) apenas uma vez pra configurar seu quiosque. Depois disso, ele cuida de tudo sozinho. Garante que seu Raspberry Pi esteja sempre mostrando o site que você escolheu, mesmo que a internet caia ou o servidor do site tenha problemas. 

# Execução em comando único
> Será solicitado o endereço do site (Ex. https://ddg.com)
```shell
bash -c "$(wget -qO- https://raw.githubusercontent.com/ctic-tub-ifsc/mint-kiosk/refs/heads/main/install_kiosk.sh)"
```

