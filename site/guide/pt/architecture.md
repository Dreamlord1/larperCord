# Arquitetura

Cerca de 34.000 linhas de Zig sobre uma camada fina de C. A regra que molda tudo: **a interface nunca muda dados diretamente**.

## Fluxo de dados

```text
UI → Action → app → Command → gateway → Event → Store → UI
```

A interface só lê o Store e pede ações. O app transforma essas ações em comandos para o gateway, que roda na própria thread, e os eventos voltam por uma fila até o Store. Por isso trocar o gateway de demonstração pelo real não mexe na interface.

## Árvore do código

```text
src/
  core/       dados puros, sem janela: tipos (snowflakes), Store, markdown, eventos,
              caixa de entrada, mensagens salvas, filtros, consultas de busca, formato do cache
  net/        o gateway real (Discord) e o de demonstração, filas, voz,
              protobuf das configurações, cache de mensagens, proxy, URLs de mídia
  theme/      parser KDL, cores, carregador de tema, motor de layout, gerenciador + inotify
  ui/         componentes, texto rico, paleta, configurações, animações, imagens, vídeo
  plugins/    o motor Lua e o seu host
  platform/   janela, renderizador, acordar o laço, carregamento do FFmpeg. O único
              lugar que conhece o sistema de janelas do SDL
themes/       os temas embutidos (também compilados dentro do binário)
third_party/  código de terceiros copiado: Dear ImGui, dear_bindings, Lua, stb_image, libdave,
              MLSpp, nlohmann/json
tools/        QA, benchmark de memória, capturas de tela, geradores de logo e do site
```

## Threads

| Thread | Quando existe | O que faz |
|---|---|---|
| Interface | Sempre | O laço principal, dormindo em `SDL_WaitEvent` quando nada acontece. Os plugins Lua também rodam aqui |
| Gateway | Com token | WebSocket com heartbeat, RESUME, zlib-stream e reconexão, mais o REST, uma requisição por vez |
| Gateway de demonstração | Sem token | Servidores, pessoas e mensagens falsos |
| Mídia | Sempre, quase sempre dormindo | Baixa e decodifica imagens com baixa prioridade, no máximo 2 decodificações por vez |
| Vigia de temas | A menos que desligada | Espera o inotify avisar de mudanças nos arquivos de tema e nas cores do pywal |
| Vídeo | Enquanto toca | Uma thread baixa, outra decodifica num anel de 3 quadros |
| Voz | Durante uma call | Gateway de voz, UDP, Opus e DAVE |

## Conversando com o Discord

O gateway usa WebSocket (`v=10`, JSON, `zlib-stream`) com heartbeat, RESUME de sessão e reconexão. O comportamento foi portado para Zig a partir do que também conecta como cliente de usuário. O REST cuida de histórico, envio, edição, exclusão, reações e "digitando", uma requisição por vez e respeitando o rate limit.

## A renderização

Tudo é desenhado com o `ImDrawList` do Dear ImGui sobre o SDL_Renderer, e o FreeType renderiza o texto. O ImGui é uma biblioteca de modo imediato, então o custo normal dela é redesenhar o tempo todo. Aqui, o laço só desenha quando algo muda:

- **Entrada, rede, inotify e o relógio** acordam o laço por eventos.
- **Animações** pedem quadros só enquanto estão rodando.
- **Listas** usam busca binária para achar o primeiro item visível e desenham só o que está na tela.
- **Markdown** é interpretado uma vez, quando a mensagem chega, com cache de altura por largura.

## Temas como dados

Um tema é lido como cores, estilos e uma árvore de nós. O motor de layout calcula os retângulos a partir de `row`, `column`, `stack`, `flex` e tamanhos, e depois uma tabela em `src/ui/root.zig` liga os nomes dos componentes às funções de desenho. Um componente que ele não conhece aparece com uma borda vermelha e o número da linha do arquivo.

[Escrevendo temas](page:themes) documenta a linguagem, e o [playground da página inicial](home:playground) deixa você testar no navegador.

## Como ele fica leve

Veja [Desempenho](page:performance).
