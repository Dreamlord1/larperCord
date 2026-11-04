# Estado e roadmap

O larperCord é um projeto jovem: versão 0.4.0, com o primeiro commit em 2 de novembro de 2026. Dá para usar, mas não está completo.

## O que funciona hoje

| Área | Estado | Detalhe |
|---|---|---|
| Mensagens, DMs, reações, respostas | **funciona** | Enviar, editar, excluir, histórico, menções |
| Imagens | **funciona** | Avatares e anexos, com cache de tamanho fixo |
| Vídeo na conversa | **funciona** | Anexos e links diretos. Precisa do FFmpeg do sistema |
| Caixa de entrada, mensagens salvas, busca offline | **funciona** | Tudo local, dá para desligar e apagar |
| Várias contas, proxy, plugins em Lua | **funciona** | |
| Temas | **funciona** | 10 embutidos, cada um em claro e escuro, recarregam ao salvar |
| Voz | parcial | E2EE (DAVE), mixer e mudo funcionam. Só o dispositivo padrão, sem push-to-talk, sem supressão de ruído e sem teste automático de call |
| Permissões | parcial | Canais sem acesso ganham cadeado e voz sem permissão é bloqueada. Esses canais ainda aparecem, e a caixa de texto, as reações e a lista de membros não consultam a permissão |
| Notificações | parcial | Pelo `notify-send`. Clicar não abre o canal, e não há bandeja do sistema |
| Acessibilidade | parcial | Escala da fonte, reduzir movimento, paleta e navegação estilo vim. Sem foco visível e sem alto contraste |
| Primeiro uso | parcial | Tela de login e modo demonstração, sem apresentação do app |
| Plataformas | parcial | Só Linux (usa inotify e `/proc`). Testado no Arch com Hyprland |
| Emojis personalizados | falta | `<:nome:id>` aparece como texto |
| Entrar em servidor por convite | falta | |
| Threads e fóruns | falta | O aviso "criou um tópico" aparece, mas não dá para abrir |
| Compartilhar tela e câmera | falta | |

## Roadmap

**Feito**

- [x] Gateway real (WebSocket, heartbeat, reconexão) e REST respeitando o rate limit
- [x] RESUME de sessão e zlib-stream
- [x] Presenças, membros e eventos de servidor e canal
- [x] Imagens: avatares e anexos com cache de tamanho fixo
- [x] Voz: gateway de voz, UDP, Opus e DAVE/MLS

**Para o app ficar completo**

- [ ] Permissões de verdade: esconder o que você não pode ver, desabilitar a caixa de texto e as reações, filtrar os membros
- [ ] Entrar em servidor por convite
- [ ] Emojis personalizados nas mensagens
- [ ] Notificações nativas via D-Bus com "abrir conversa", e bandeja do sistema
- [ ] Threads e fóruns
- [ ] Voz: seletor de dispositivo, push-to-talk, supressão de ruído e teste automático de call
- [ ] Acessibilidade e primeiro uso: foco visível, alto contraste, uma tela de boas-vindas

**Temas**

- [ ] Motor com assets: gradientes, grão, tracking, formas e linhas, efeitos, sobreposição e ordem z, fontes e imagens por tema
- [ ] Galeria e editor: miniaturas reais, importar e exportar `.kdl`, um inspetor de componentes
- [ ] Componentes de tema escritos em Lua (sandbox)

**Mais para frente**

- [ ] Um backend por software (`wl_shm`, sem GPU), para chegar a cerca de 15–20 MB
